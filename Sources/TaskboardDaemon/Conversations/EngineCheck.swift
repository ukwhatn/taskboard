import Foundation
import TaskboardKit

/// `taskboard conversation check` の結果と記録（Claude Code は `ClaudeCheck`、codex は `CodexCheck` が通す）。通った版を `VerifiedCLI` に書き、
/// host の会話はその版でだけ起こす
public enum EngineCheck {
    public struct Step: Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public struct Report: Sendable {
        public var engine: AgentKind
        public var version: String
        public var executable: String
        public var capabilities: [String]
        public var steps: [Step]
        /// Claude Code の initialize の答えのモデルの一覧（記録すると `GET /v1/claude` に出る）
        public var models: [ClaudeMachineInfo.Model]? = nil

        public var passed: Bool { !steps.isEmpty && steps.allSatisfy(\.passed) }
    }

    public enum Failure: Error, CustomStringConvertible {
        case noExecutable(String, AgentKind)
        case version(String, AgentKind)

        public var description: String {
            switch self {
            case .noExecutable(let path, let engine): "\(engine.label) の実行ファイルが無い: \(path)"
            case .version(let output, let engine): "\(engine.label) の版を読めない: \(output.prefix(200))"
            }
        }
    }

    /// 確かめる CLI。省くと `~/.local/bin/claude`・`~/.local/bin/codex` の先（版ごとの実行ファイル。symlink のままだと更新で別の版を指す）
    public static func resolveExecutable(_ given: String?, engine: AgentKind) throws -> String {
        let path = given ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(engine.rawValue)").path
        let resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: resolved) else { throw Failure.noExecutable(path, engine) }
        return resolved
    }

    /// `--version` の出力の、数で始まる最初の語（`2.1.303 (Claude Code)`・`codex-cli 0.162.1`）
    public static func version(of executable: String, engine: AgentKind) async throws -> String {
        let output = try await Subprocess.run(URL(fileURLWithPath: executable), ["--version"], timeout: .seconds(30))
        guard let token = output.split(whereSeparator: \.isWhitespace).first(where: { $0.first?.isNumber == true }) else { throw Failure.version(output, engine) }
        return String(token)
    }

    /// 通った版を記録する（host の会話がその版で起きるようになる）。モデルの一覧も書く
    public static func record(_ report: Report, supportDirectory: URL) throws {
        try VerifiedCLI.record(
            .init(version: report.version, path: report.executable, capabilities: report.capabilities, verifiedAt: Date()), report.engine,
            supportDirectory: supportDirectory)
        if let models = report.models { try ClaudeModelRecord.record(models, version: report.version, supportDirectory: supportDirectory) }
    }
}
