import Foundation
import OSLog
import WhisperKit

/// 端末の中の Whisper（WhisperKit）で、16kHz・モノラルの音を日本語の文にする。音は端末の外に出さない。
/// モデルは初めて使うときに Hugging Face の `argmaxinc/whisperkit-coreml` から `directory` に取得し、取得し終えた印を置く（印の無いフォルダは取得の途中で止まったものとして取り直す）。
/// 読み込んだモデルはプロセスの中で持ち続ける
actor WhisperRecognizer {
    enum Stage: Sendable, Equatable {
        /// 取得している。割合が分からなければ nil
        case downloading(Double?)
        /// 読み込んでいる（初めての読み込みは Neural Engine 向けの準備で時間がかかる）
        case loading
    }

    static let shared = WhisperRecognizer(model: WhisperModelChoice.current, directory: WhisperRecognizer.standardDirectory)

    let model: String
    let directory: URL
    private var pipe: WhisperKit?
    private var preparing: Task<Void, any Error>?
    /// 準備の途中の段階と、それを受ける呼び出し元（後から加わった呼び出し元にも、今の段階から渡す）
    private var current: Stage?
    private var observers: [@Sendable (Stage) -> Void] = []
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "dictation")
    private static let completeMarker = ".taskboard-complete"

    init(model: String, directory: URL) {
        self.model = model
        self.directory = directory
    }

    /// macOS は daemon と同じ support ディレクトリの `whisper/`、iPhone・iPad はアプリの container の Application Support の中
    static var standardDirectory: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "taskboard/whisper", directoryHint: .isDirectory)
    }

    private var modelFolder: URL { directory.appending(path: "models/argmaxinc/whisperkit-coreml/\(model)", directoryHint: .isDirectory) }

    /// モデルを取得し終えていれば true（読み込み済みかは問わない）
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: modelFolder.appending(path: Self.completeMarker).path) }

    /// モデルを使える状態にする。取得と読み込みの段階を `stage` に渡す。同時に呼ばれたら同じ準備を待つ
    func prepare(stage: @escaping @Sendable (Stage) -> Void) async throws {
        if pipe != nil { return }
        observers.append(stage)
        if let current { stage(current) }
        if let preparing { return try await preparing.value }
        let task = Task { pipe = try await load(stage: { [weak self] stage in Task { await self?.report(stage) } }) }
        preparing = task
        defer {
            preparing = nil
            current = nil
            observers = []
        }
        try await task.value
    }

    private func report(_ stage: Stage) {
        current = stage
        for observer in observers { observer(stage) }
    }

    private func load(stage: @escaping @Sendable (Stage) -> Void) async throws -> WhisperKit {
        if !isDownloaded {
            stage(.downloading(nil))
            Self.logger.notice("Whisper のモデルを取得する: \(self.model, privacy: .public)")
            let started = Date()
            let folder = try await WhisperKit.download(variant: model, downloadBase: directory) { progress in
                stage(.downloading(progress.fractionCompleted > 0 ? progress.fractionCompleted : nil))
            }
            guard folder.resolvingSymlinksInPath().path == modelFolder.resolvingSymlinksInPath().path else {
                throw WhisperRecognizerError.unexpectedFolder(folder.path)
            }
            FileManager.default.createFile(atPath: modelFolder.appending(path: Self.completeMarker).path, contents: Data())
            Self.logger.notice("Whisper のモデルを取得した: \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) 秒")
        }
        stage(.loading)
        let started = Date()
        let config = WhisperKitConfig(
            model: model, downloadBase: directory, modelFolder: modelFolder.path, tokenizerFolder: directory, verbose: false, prewarm: false, load: true,
            download: false)
        let pipe = try await WhisperKit(config)
        Self.logger.notice("Whisper のモデルを読み込んだ: \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public) 秒")
        return pipe
    }

    /// 音を文にする。`vocabulary` は前の文脈（prompt）として渡し、綴りを寄せる。`prepare` の後に呼ぶ
    func transcribe(_ samples: [Float], vocabulary: [String]) async throws -> String {
        guard let pipe else { throw WhisperRecognizerError.notPrepared }
        var options = DecodingOptions(
            task: .transcribe, language: "ja", temperature: 0, usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
            withoutTimestamps: true, chunkingStrategy: .vad)
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + vocabulary.joined(separator: "、"))
        }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperRecognizerError: Error {
    case notPrepared
    case unexpectedFolder(String)
}

/// 端末に合うモデル。Mac は large-v3-turbo（`large-v3-v20240930`）をそのまま、iPhone・iPad は量子化した 626MB の版
/// （WhisperKit の対応表で A15 以降が使える）、それより古い端末は対応表の既定。シミュレータは CPU だけで回るので小さい版
enum WhisperModelChoice {
    static let mac = "openai_whisper-large-v3-v20240930"
    static let mobile = "openai_whisper-large-v3-v20240930_626MB"
    static let simulator = "openai_whisper-small"

    static var current: String {
        #if os(macOS)
        return mac
        #elseif targetEnvironment(simulator)
        return simulator
        #else
        let support = WhisperKit.recommendedModels()
        return support.supported.contains(mobile) ? mobile : support.default
        #endif
    }
}
