import Foundation

/// `gh` をどのアカウントで呼ぶかの対応表。鍵は `host/owner` か `host`、値は `gh auth` のアカウント名。
/// 同じ host に複数のアカウントがある（個人と勤務先）と `gh` の active account では片方の private repo が読めないため、
/// URL から引いたアカウントの token を `gh auth token --user` で取り、子プロセスの環境変数だけに渡す。
/// 対応表は `<support dir>/github-accounts.json`（`import taskherd` が config の `[github.accounts]` から書く。手で編集してよい）。
public struct GitHubAccounts: Sendable, Equatable {
    public var mapping: [String: String]

    public init(mapping: [String: String] = [:]) {
        self.mapping = mapping
    }

    public static let fileName = "github-accounts.json"

    /// 無い・読めないときは空（gh の既定アカウントで動く）。
    public static func load(from url: URL) -> GitHubAccounts {
        guard let data = try? Data(contentsOf: url), let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return GitHubAccounts()
        }
        return GitHubAccounts(mapping: mapping)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (try encoder.encode(mapping) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    public struct Match: Equatable, Sendable {
        public var host: String
        public var account: String
    }

    /// PR / Issue の URL（`https://host/owner/repo/pull/1`）から。`host/owner` が `host` より優先。
    public func match(url: String) -> Match? {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return nil }
        let owner = components.path.split(separator: "/").first.map(String.init)
        return match(host: host, owner: owner)
    }

    /// git の remote（`https://host/owner/repo.git` / `git@host:owner/repo.git` / `ssh://git@host/owner/repo`）から。
    public func match(remote: String) -> Match? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: trimmed), let host = components.host?.lowercased(), components.scheme != nil {
            return match(host: host, owner: components.path.split(separator: "/").first.map(String.init))
        }
        // scp 形式: [user@]host:owner/repo(.git)
        guard let colon = trimmed.firstIndex(of: ":"), !trimmed[..<colon].contains("/") else { return nil }
        var host = String(trimmed[..<colon])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        let owner = trimmed[trimmed.index(after: colon)...].split(separator: "/").first.map(String.init)
        return match(host: host.lowercased(), owner: owner)
    }

    public func match(host: String, owner: String?) -> Match? {
        if let owner, let account = mapping["\(host)/\(owner)"] ?? mapping["\(host)/\(owner.lowercased())"] {
            return Match(host: host, account: account)
        }
        if let account = mapping[host] { return Match(host: host, account: account) }
        return nil
    }

    /// taskherd の config.toml の `[github.accounts]` だけを読む最小の TOML 読み（`"key" = "value"` の行）。
    public static func parseTaskherdConfig(_ toml: String) -> GitHubAccounts {
        var mapping: [String: String] = [:]
        var inSection = false
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                inSection = line == "[github.accounts]"
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(line[..<eq])
            let value = unquote(line[line.index(after: eq)...])
            if !key.isEmpty, !value.isEmpty { mapping[key] = value }
        }
        return GitHubAccounts(mapping: mapping)
    }

    private static func unquote(_ raw: Substring) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") {
            // 引用符の中だけ。閉じ引用符の後ろ（コメント等）は捨てる
            let body = text.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { return String(body) }
            return String(body[..<close])
        }
        if let hash = text.firstIndex(of: "#") { return String(text[..<hash]).trimmingCharacters(in: .whitespaces) }
        return text
    }
}
