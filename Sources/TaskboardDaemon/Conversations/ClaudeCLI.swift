import Foundation
import TaskboardKit

/// `taskboard conversation check` が通した CLI の版（engine ごとに support ディレクトリの `agent-host/verified-cli.json`・`verified-codex.json`、0600）。
/// host の会話は、ここにある版のうちまだ残っている最も新しいものでだけ起こす（確かめていない版の stream-json・app-server に回らない）
struct VerifiedCLI: Codable, Equatable, Sendable {
    /// 確かめる中身を足したら上げる（前の形式の記録は読まない。daemon を入れ替えたら `taskboard conversation check` を回し直す）。
    /// Claude Code の 2：送った発言と返答の uuid が transcript に同じ id で残る（会話の履歴と生成中の発言を id で重ねる）
    static func currentFormat(_ engine: AgentKind) -> Int {
        switch engine {
        case .claude: 2
        case .codex: 1
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var version: String
        var path: String
        var capabilities: [String]
        var verifiedAt: Date
    }

    var format = 0
    var entries: [Entry] = []

    static func file(_ engine: AgentKind, supportDirectory: URL) -> URL {
        let name =
            switch engine {
            case .claude: "verified-cli.json"
            case .codex: "verified-codex.json"
            }
        return AgentHostServer.directory(supportDirectory: supportDirectory).appending(path: name)
    }

    /// 読めない・書式の版が違うときは nil（確かめた版が無いのと同じに扱う）
    static func load(_ engine: AgentKind, supportDirectory: URL) -> VerifiedCLI? {
        guard let data = try? Data(contentsOf: file(engine, supportDirectory: supportDirectory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let verified = try? decoder.decode(VerifiedCLI.self, from: data), verified.format == currentFormat(engine) else { return nil }
        return verified
    }

    /// 同じ版の記録を置き換えて足し、別のファイルに書いてから rename する
    static func record(_ entry: Entry, _ engine: AgentKind, supportDirectory: URL) throws {
        var verified = load(engine, supportDirectory: supportDirectory) ?? VerifiedCLI(format: currentFormat(engine))
        verified.entries.removeAll { $0.version == entry.version }
        verified.entries.append(entry)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = file(engine, supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = target.deletingLastPathComponent().appending(path: ".verified-cli.\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(verified), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, target.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 確かめた版のうち、実行ファイルがまだあり、要る capabilities を持つ最も新しいもの
    func newest(requiring capabilities: [String], isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Entry? {
        entries
            .filter { entry in isExecutable(entry.path) && capabilities.allSatisfy(entry.capabilities.contains) }
            .max { Self.precedes($0.version, $1.version) }
    }

    /// 版の並び（`2.1.99` < `2.1.302`）。数でない部分は文字で比べる
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map(String.init)
        let right = rhs.split(separator: ".").map(String.init)
        for (a, b) in zip(left, right) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            return a < b
        }
        return left.count < right.count
    }

    /// 版ごとの実行ファイルを置く場所（`~/.local/bin/claude`・`~/.local/bin/codex` はその中への symlink）
    static func versionsDirectory(_ engine: AgentKind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return switch engine {
        case .claude: home.appending(path: ".local/share/claude/versions", directoryHint: .isDirectory)
        case .codex: home.appending(path: ".codex/packages/standalone/releases", directoryHint: .isDirectory)
        }
    }

    /// `directory` に入っている版と実行ファイル。Claude Code は `<版>` が実行ファイル、codex は `<版>-<target>/bin/codex`。実行できないものと版でない名前は外す
    static func installed(_ engine: AgentKind, in directory: URL) -> [(version: String, path: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.first?.isNumber == true else { return nil }
            let (version, path) =
                switch engine {
                case .claude: (name, directory.appending(path: name).path)
                case .codex: (String(name.prefix { $0 != "-" }), directory.appending(path: name).appending(path: "bin/codex").path)
                }
            return FileManager.default.isExecutableFile(atPath: path) ? (version, path) : nil
        }
    }
}

/// 会話の CLI に渡す環境を、ユーザーのログインシェルから取る。launchd の daemon の環境には、TUI で使えている PATH（mise・brew など）が無い。
/// zsh の非対話のログインシェルは `.zshrc` を読まないので `-i` を付け、`.zshrc` が出す文字と混ざらないよう印の行より後だけを読む
public enum LoginShellEnvironment {
    static let marker = "__TASKBOARD_LOGIN_ENV__"
    /// 引き継がない変数（daemon や pane の中の値が会話に漏れると、hook と MCP が別の会話のものと取り違える）
    static let excludedPrefixes = ["CLAUDE_CODE_", "CLAUDECODE", "TASKBOARD_", "HERDR_", "TERM_PROGRAM"]
    /// シェルの場所の値（会話は host が cwd を決めて起こす）
    static let excludedNames: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
    static let byteLimit = 1_048_576

    public static func capture(shell: String, timeout: Duration = .seconds(10)) async -> [String: String]? {
        let script = "printf '\\n\(marker)\\n'; /usr/bin/env -0"
        for flags in ["-lic", "-lc"] {
            guard let output = try? await Subprocess.run(URL(fileURLWithPath: shell), [flags, script], timeout: timeout, outputLimit: byteLimit) else { continue }
            if let environment = parse(output) { return environment }
        }
        return nil
    }

    /// 印の行より後の `env -0` の出力を読む。印が無い・大きすぎるときは nil
    static func parse(_ output: String) -> [String: String]? {
        guard output.utf8.count <= byteLimit, let range = output.range(of: "\n\(marker)\n", options: .backwards) else { return nil }
        var environment: [String: String] = [:]
        for entry in output[range.upperBound...].split(separator: "\0", omittingEmptySubsequences: true) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let name = String(entry[..<equals])
            guard !name.isEmpty, !excludedNames.contains(name), !excludedPrefixes.contains(where: name.hasPrefix) else { continue }
            environment[name] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }
}
