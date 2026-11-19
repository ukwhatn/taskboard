import Foundation
@testable import TaskboardDaemon
import TaskboardKit

/// 使い方（README.md）:
///   voice-eval apple <wav のディレクトリ> <context.json>
///   voice-eval whisper <wav のディレクトリ> <context.json> [--model 名前] [--no-vocabulary] [--no-normalize] [--models-dir パス]
///   voice-eval polish <認識の結果.tsv> <context.json> [--claude パス] [--model haiku|sonnet]
///   voice-eval endpoint <wav のディレクトリ>
/// 1 行に「番号<TAB>文<TAB>秒」を出す
struct EvalContext: Decodable {
    var taskTitle: String
    var taskNumber: Int
    var messages: [String]

    var chatMessages: [ChatMessage] {
        messages.enumerated().map { ChatMessage(id: "m\($0.offset)", role: .assistant, kind: .text, text: $0.element) }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func wavFiles(_ directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func emit(_ id: String, _ text: String, _ seconds: Double) {
    print("\(id)\t\(text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))\t\(String(format: "%.2f", seconds))")
    fflush(stdout)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("使い方: voice-eval apple|whisper|polish|endpoint ...") }
let mode = arguments[1]
let input = URL(filePath: arguments[2])
let context = arguments.count >= 4 && !arguments[3].hasPrefix("--")
    ? try JSONDecoder().decode(EvalContext.self, from: Data(contentsOf: URL(filePath: arguments[3]))) : nil

switch mode {
case "apple":
    guard let context else { fail("context.json が必要") }
    // 置き換える前の入力欄と同じ語彙（タスクの題と番号、発言の番号のような語）
    let vocabulary = [context.taskTitle, "#\(context.taskNumber)"]
    for file in try wavFiles(input) {
        let started = Date()
        let text = try await AppleDictation.transcribe(file, vocabulary: vocabulary)
        emit(file.deletingPathExtension().lastPathComponent, text, Date().timeIntervalSince(started))
    }
case "whisper":
    guard let context else { fail("context.json が必要") }
    let model = option("--model") ?? WhisperModelChoice.mac
    let directory = option("--models-dir").map { URL(filePath: $0) } ?? WhisperRecognizer.standardDirectory
    let recognizer = WhisperRecognizer(model: model, directory: directory)
    let prepareStarted = Date()
    try await recognizer.prepare { stage in FileHandle.standardError.write(Data("\(stage)\n".utf8)) }
    FileHandle.standardError.write(Data("準備: \(String(format: "%.1f", Date().timeIntervalSince(prepareStarted))) 秒\n".utf8))
    let vocabulary = arguments.contains("--no-vocabulary")
        ? [] : DictationVocabulary.phrases(taskTitle: context.taskTitle, taskNumber: context.taskNumber, messages: context.chatMessages)
    for file in try wavFiles(input) {
        var samples = try VoiceAudioConverter.read(file)
        if !arguments.contains("--no-normalize") { samples = DictationSignal.normalized(samples) }
        let started = Date()
        let text = try await recognizer.transcribe(samples, vocabulary: vocabulary)
        emit(file.deletingPathExtension().lastPathComponent, text, Date().timeIntervalSince(started))
    }
case "polish":
    guard let context else { fail("context.json が必要") }
    let claude = option("--claude") ?? "/Users/\(NSUserName())/.local/bin/claude"
    let launch = EngineLaunch(executable: claude, environment: ProcessInfo.processInfo.environment)
    let model = option("--model") ?? ClaudeDictationPolish.model
    for line in try String(contentsOf: input, encoding: .utf8).split(separator: "\n") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { continue }
        let request = DictationPolishRequest(text: parts[1], taskTitle: context.taskTitle, taskNumber: context.taskNumber, messages: context.chatMessages)
        let polisher = DictationPolisher { request in try await ClaudeDictationPolish.run(launch, request, model: model, timeout: .seconds(30)) }
        let started = Date()
        let text: String
        do {
            text = try await polisher.polish(request)
        } catch {
            FileHandle.standardError.write(Data("\(parts[0]): 校正に失敗（\(error)）。元の文を残す\n".utf8))
            text = parts[1]
        }
        emit(parts[0], text, Date().timeIntervalSince(started))
    }
case "endpoint":
    // ハンズフリーの終わりの判定を、音声の後ろに 3 秒の無音（雑音）を付けて流し、話し始めと終わりを見た時刻を出す
    for file in try wavFiles(input) {
        let samples = try VoiceAudioConverter.read(file)
        var endpoint = DictationEndpoint()
        let chunk = 1600
        var heardAt: Double?
        var endedAt: Double?
        var fed = 0
        let tail = [Float](repeating: 0, count: DictationSignal.sampleRate * 3)
        let noise = (samples + tail).map { $0 + Float.random(in: -0.0005...0.0005) }
        while fed < noise.count, endedAt == nil {
            let next = min(fed + chunk, noise.count)
            endpoint.feed(Array(noise[fed..<next]))
            fed = next
            let now = Double(fed) / Double(DictationSignal.sampleRate)
            if endpoint.heardSpeech, heardAt == nil { heardAt = now }
            if endpoint.ended { endedAt = now }
        }
        let speechEnd = Double(samples.count) / Double(DictationSignal.sampleRate)
        print("\(file.lastPathComponent)\theard=\(heardAt.map { String(format: "%.1f", $0) } ?? "-")\tspeechEnd=\(String(format: "%.1f", speechEnd))\tended=\(endedAt.map { String(format: "%.1f", $0) } ?? "-")")
    }
default:
    fail("知らない mode: \(mode)")
}
