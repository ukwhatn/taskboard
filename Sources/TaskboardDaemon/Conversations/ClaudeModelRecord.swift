import Foundation
import TaskboardKit

/// Claude Code のモデルの一覧の記録（support ディレクトリの `agent-host/claude-models.json`、0600）。会話・`taskboard conversation check` の
/// initialize の答えから書き、`GET /v1/claude` と model の確かめが読む。確かめの CLI と daemon の両方が書くので、版の記録（`VerifiedCLI`）とは分けてある
enum ClaudeModelRecord {
    static func file(supportDirectory: URL) -> URL {
        AgentHostServer.directory(supportDirectory: supportDirectory).appending(path: "claude-models.json")
    }

    /// 無い・読めないときは一覧の無い値（引く側は `ClaudeModels` の控えを使う）
    static func load(supportDirectory: URL) -> ClaudeMachineInfo {
        guard let data = try? Data(contentsOf: file(supportDirectory: supportDirectory)) else { return ClaudeMachineInfo(models: nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ClaudeMachineInfo.self, from: data)) ?? ClaudeMachineInfo(models: nil)
    }

    static func models(supportDirectory: URL) -> ClaudeModels {
        ClaudeModels(load(supportDirectory: supportDirectory))
    }

    /// 一覧と版が今の記録と同じなら書かない（会話を起こすたびに呼ばれる）。別のファイルに書いてから rename する
    static func record(_ models: [ClaudeMachineInfo.Model], version: String?, supportDirectory: URL, now: Date = Date()) throws {
        guard !models.isEmpty else { return }
        let current = load(supportDirectory: supportDirectory)
        if current.models == models, current.version == version { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = file(supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = target.deletingLastPathComponent().appending(path: ".claude-models.\(UUID().uuidString).json")
        let data = try encoder.encode(ClaudeMachineInfo(models: models, version: version, readAt: now))
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

extension ClaudeModels {
    /// 一覧に無い名前を断る文（MCP と API の誤り。選べる名前を並べる）
    public func rejection(_ value: String, field: String = "model") -> String {
        "\(field) \(value) が無い。使える値: " + names.joined(separator: ", ")
    }
}
