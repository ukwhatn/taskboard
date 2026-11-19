import Foundation
import TaskboardKit

/// アカウントごとの、最後に分かった Claude の利用枠（support ディレクトリの `claude-usage.json`）。枠は statusline と会話の報告でしか
/// 分からず、daemon が起き直すと空になる。空の間は上限のアカウントも「越えていない」とみて選んでしまうので、起きたときに戻す
public struct ClaudeUsageFile: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        /// マシンのログインの枠
        public var login: ClaudeUsage?
        /// アカウントの名前ごとの枠
        public var accounts: [String: ClaudeUsage]

        public init(login: ClaudeUsage? = nil, accounts: [String: ClaudeUsage] = [:]) {
            self.login = login
            self.accounts = accounts
        }

        public init(_ usage: UsageSnapshot) {
            self.init(
                login: usage.claude,
                accounts: Dictionary((usage.claudeAccounts ?? []).compactMap { account in account.usage.map { (account.name, $0) } }) { $1 })
        }

        /// 戻る時刻を過ぎた窓を落とす（今の使用率ではない）。窓が 1 つも残らない枠は捨てる
        func live(now: Date) -> Contents {
            func live(_ usage: ClaudeUsage?) -> ClaudeUsage? {
                guard var usage else { return nil }
                func current(_ window: UsageWindow?) -> UsageWindow? {
                    guard let window, let resets = window.resetsAt, resets > now else { return nil }
                    return window
                }
                usage.fiveHour = current(usage.fiveHour)
                usage.sevenDay = current(usage.sevenDay)
                return usage.fiveHour == nil && usage.sevenDay == nil ? nil : usage
            }
            return Contents(login: live(login), accounts: accounts.compactMapValues { live($0) })
        }
    }

    let url: URL

    public init(supportDirectory: URL) {
        url = supportDirectory.appending(path: "claude-usage.json")
    }

    /// 読めなければ空
    public func load(now: Date) -> Contents {
        guard let data = try? Data(contentsOf: url), let contents = try? Self.decoder.decode(Contents.self, from: data) else { return Contents() }
        return contents.live(now: now)
    }

    func save(_ contents: Contents) throws {
        try Self.encoder.encode(contents).write(to: url, options: .atomic)
    }

    /// 枠が変わったら書く（`interval` ごとに見る）。取り消されるまで返らない
    public func run(state: DaemonState, interval: Duration = .seconds(30)) async {
        var saved = load(now: Date())
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            let current = Contents(await state.usageSnapshot())
            guard current != saved else { continue }
            do {
                try save(current)
                saved = current
            } catch {
                // 次の見回りで書き直す
            }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
