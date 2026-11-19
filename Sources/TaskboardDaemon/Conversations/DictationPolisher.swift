import Foundation
import TaskboardKit

/// 音声入力で文字にした文を、会話の文脈を付けて Claude Code（`claude -p`、Sonnet）で 1 回校正する。同時に回すのは `concurrency` 本まで
/// （超えた分は断り、アプリは校正の前の文を残す）。校正した文が元の文から大きく離れていたら、指示に答えたとみなして断る
actor DictationPolisher {
    typealias Run = @Sendable (DictationPolishRequest) async throws -> String

    private let concurrency: Int
    private let run: Run
    private var running = 0

    init(concurrency: Int = 3, run: @escaping Run) {
        self.concurrency = concurrency
        self.run = run
    }

    func polish(_ request: DictationPolishRequest) async throws -> String {
        guard running < concurrency else { throw DictationPolishError.busy }
        running += 1
        defer { running -= 1 }
        let polished = try await run(request).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.plausible(polished, from: request.text) else { throw DictationPolishError.rejected }
        return polished
    }

    /// 校正は語を直すだけなので、字数は元の半分から 2 倍に収まる（空白を除いて数える）
    static func plausible(_ polished: String, from original: String) -> Bool {
        let count = { (text: String) in text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }
        let before = count(original)
        let after = count(polished)
        return after > 0 && after * 2 >= before && after <= before * 2
    }
}

enum DictationPolishError: Error, Equatable {
    case busy
    case rejected
}

/// `claude -p` で校正する。user の設定・hook・MCP を読ませず、ツールも持たせない。会話を保存しない
enum ClaudeDictationPolish {
    /// Haiku は同じ文でも回ごとの揺れが大きく、音の近い名前を文脈の語に寄せきれなかった（scripts/voice-eval で CER 8〜14%、Sonnet は 6〜7%。かかる時間は同じ）
    static let model = "sonnet"

    static let schema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#

    static func arguments(model: String) -> [String] {
        [
            "-p", "--model", model, "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--tools", "", "--output-format", "json",
            "--json-schema", schema, "--system-prompt", Copy.prompt("dictation-polish"),
        ]
    }

    /// 標準入力に渡す文
    static func input(_ request: DictationPolishRequest) -> String {
        var task = request.taskTitle ?? ""
        if let number = request.taskNumber { task += (task.isEmpty ? "" : " ") + "#\(number)" }
        return [
            "<task>", task, "</task>",
            "<recent>", request.recent.map { "- " + $0.split(whereSeparator: \.isNewline).joined(separator: " ") }.joined(separator: "\n"), "</recent>",
            "<vocabulary>", request.vocabulary.joined(separator: "\n"), "</vocabulary>",
            "<dictation>", request.text, "</dictation>",
        ].joined(separator: "\n")
    }

    struct Failed: Error, CustomStringConvertible {
        var description: String
    }

    /// `--output-format json` の結果の行
    private struct Result: Decodable {
        struct Output: Decodable { var text: String }
        var is_error: Bool?
        var subtype: String?
        var structured_output: Output?
    }

    static func run(_ launch: EngineLaunch, _ request: DictationPolishRequest, model: String = ClaudeDictationPolish.model, timeout: Duration) async throws -> String {
        let outcome = try await Subprocess.capture(
            URL(filePath: launch.executable), arguments(model: model), cwd: FileManager.default.temporaryDirectory, environment: launch.environment, timeout: timeout,
            outputLimit: 1 << 20, input: Data(input(request).utf8))
        guard !outcome.timedOut else { throw Failed(description: "時間切れ") }
        guard outcome.status == 0 else { throw Failed(description: "終了コード \(outcome.status)") }
        let result: Result
        do {
            result = try JSONDecoder().decode(Result.self, from: outcome.stdout)
        } catch {
            throw Failed(description: "結果を読めない（\(error)）")
        }
        guard result.is_error != true, let output = result.structured_output else { throw Failed(description: "結果が無い（\(result.subtype ?? "")）") }
        return output.text
    }
}
