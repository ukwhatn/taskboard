import Foundation
import Logging
import TaskboardKit

/// taskboard が起こす Claude Code のアカウント（`claude setup-token` のトークン）。
/// - アカウントは `claude-accounts.json` に並べる。トークンは各アカウントの settings（`claude-accounts/<名前>.json`、0600）の `env` に書き、
///   Claude Code に `--settings` で渡す。セッションの記録（`launchArgs`）と会話の引数にその `--settings` が残るので、再開しても同じアカウントで起きる
/// - settings の `env` にはアカウントの名前（`ClaudeAccount.environmentName`）も入れる。hook と statusline の子にはこちらだけが渡り、枠をアカウントごとに分けて報告する
/// - 起こすアカウントは `choose`：頼まれたアカウント → 引数のアカウント（再開）→ 案件に割り当てたアカウント → 閾値（`MachineSettings.usagePause`）を
///   越えていないうち 1 週間の枠が早く戻るもの。引数のアカウントと割り当ては、閾値を越えたときだけ移す。既定のアカウント（`default`）があれば、頼まれない限りマシンのログインを使わない
/// - `claude-accounts.json` が無ければ、どのセッションもマシンのログインで起きる
actor ClaudeAccounts {
    struct Entry: Equatable, Sendable {
        var name: String
        var boards: [String]
    }

    private let configFile: URL
    private let directory: URL
    private let home: String
    private let state: DaemonState?
    private let logger = Logger(label: "uk.whatn.taskboardd.claude-accounts")
    private var entries: [Entry] = []
    private var fallback: String?

    init(supportDirectory: URL, state: DaemonState?, home: String = NSHomeDirectory()) {
        configFile = supportDirectory.appending(path: "claude-accounts.json")
        directory = supportDirectory.appending(path: ClaudeAccount.directoryName, directoryHint: .isDirectory)
        self.home = home
        self.state = state
    }

    /// 設定を読み直し、各アカウントの settings を書き出す（中身が同じなら書かない）。設定に無くなったアカウントの settings は消す。
    /// トークンを読めないアカウントは除く
    @discardableResult
    func reload() async -> [Entry] {
        var next: [Entry] = []
        var nextFallback: String?
        do {
            if let config = try ClaudeAccountsConfig.load(from: configFile) {
                nextFallback = config.default
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for account in config.accounts {
                    guard Self.acceptsName(account.name), !next.contains(where: { $0.name == account.name }) else {
                        logger.warning("claude account name is not usable", metadata: ["account": .string(account.name)])
                        continue
                    }
                    guard let token = SecretFile.read(account.tokenFile, variable: account.tokenVariable, home: home) else {
                        logger.warning("claude account token is unreadable or empty", metadata: ["account": .string(account.name)])
                        continue
                    }
                    let url = settingsURL(account.name)
                    let data = try Self.settings(token: token, name: account.name)
                    if (try? Data(contentsOf: url)) != data, !SecretFile.write(data, to: url) {
                        logger.warning("claude account settings could not be written", metadata: ["account": .string(account.name)])
                        continue
                    }
                    next.append(Entry(name: account.name, boards: account.boards ?? []))
                }
            }
        } catch {
            logger.warning("claude-accounts.json is unreadable", metadata: ["error": .string("\(type(of: error))")])
        }
        removeStale(keeping: Set(next.map(\.name)))
        if next != entries { logger.info("claude accounts", metadata: ["accounts": .string(next.map(\.name).joined(separator: ","))]) }
        entries = next
        fallback = nextFallback.flatMap { name in next.contains { $0.name == name } ? name : nil }
        if let nextFallback, fallback == nil {
            logger.warning("claude default account is not usable", metadata: ["account": .string(nextFallback)])
        }
        await state?.setClaudeAccounts(next.map { ClaudeAccount(name: $0.name, boards: $0.boards) })
        return next
    }

    /// 起こす Claude Code の引数を、決めたアカウントの `--settings` にする。`requested` は頼まれたアカウント（`ClaudeAccount.login` はログイン）、
    /// `boardKeys` はタスクの案件の id と名前。決めたアカウント（nil はログイン）も返す
    /// `resuming` は前の会話を戻すとき（引数にアカウントが無ければ、マシンのログインで起きていた会話）
    func apply(
        to args: [String], requested: String?, boardKeys: Set<String>, resuming: Bool, settings: MachineSettings.UsagePause, now: Date
    ) async throws(ClaudeAccountError) -> (args: [String], account: String?) {
        let entries = await reload()
        let usage = await state?.usageSnapshot() ?? UsageSnapshot()
        let account = try Self.choose(
            requested: requested, current: ClaudeAccount.name(inArguments: args), boardKeys: boardKeys, entries: entries, fallback: fallback,
            resuming: resuming, usage: usage, pause: settings, now: now)
        return (Self.replacing(args, with: account.map { settingsURL($0).path }), account)
    }

    /// 移し先になる全部のアカウントが閾値を越えているか。どれかが越えていなければ、起こすときに移せる
    func allExhausted(pause: MachineSettings.UsagePause, now: Date) async -> Bool {
        let usage = await state?.usageSnapshot() ?? UsageSnapshot()
        return Self.candidates(entries: entries, fallback: fallback).allSatisfy { Self.exhausted(usage.claudeUsage(account: $0), pause: pause, now: now) }
    }

    var hasAccounts: Bool { !entries.isEmpty }

    // MARK: 決め方

    static func choose(
        requested: String?, current: String?, boardKeys: Set<String>, entries: [Entry], fallback: String?, resuming: Bool, usage: UsageSnapshot,
        pause: MachineSettings.UsagePause, now: Date
    ) throws(ClaudeAccountError) -> String? {
        let names = entries.map(\.name)
        if let requested {
            if requested == ClaudeAccount.login { return nil }
            guard names.contains(requested) else { throw .unknown(requested, names) }
            return requested
        }
        // 決まっているアカウント（.some。nil はログイン）は閾値を越えるまで替えない。替えるとプロンプトのキャッシュが効かず、会話を読み直す分の枠を使う。
        // 設定から消えたアカウントで起きていたものは、割り当てから決め直す
        let pinned: String?? =
            if let current, names.contains(current) {
                .some(current)
            } else if let board = entries.first(where: { !boardKeys.isDisjoint(with: $0.boards) }) {
                .some(board.name)
            } else if resuming, fallback == nil {
                .some(nil)
            } else {
                .none
            }
        if let pinned, !exhausted(usage.claudeUsage(account: pinned), pause: pause, now: now) { return pinned }
        // 先に戻る枠の残りは、使わなければ捨てることになる
        func resetsAt(_ account: String?) -> Date { usage.claudeUsage(account: account)?.sevenDay?.resetsAt ?? .distantFuture }
        let open = candidates(entries: entries, fallback: fallback).enumerated()
            .filter { !exhausted(usage.claudeUsage(account: $0.element), pause: pause, now: now) }
            .min { (resetsAt($0.element), $0.offset) < (resetsAt($1.element), $1.offset) }
        if let open { return open.element }
        return pinned ?? fallback
    }

    /// 選ぶ候補（nil はマシンのログイン）。戻る時刻が並ぶときはこの順。既定のアカウントがあれば先頭に置き、ログインは入れない
    static func candidates(entries: [Entry], fallback: String?) -> [String?] {
        guard let fallback else { return [nil] + entries.map(\.name) }
        return [fallback] + entries.map(\.name).filter { $0 != fallback }
    }

    /// 枠が閾値を越えていて、戻る時刻がまだ来ていない。枠を知らなければ越えていないとみる
    static func exhausted(_ usage: ClaudeUsage?, pause: MachineSettings.UsagePause, now: Date) -> Bool {
        guard let usage else { return false }
        let windows = ["five_hour": usage.fiveHour, "seven_day": usage.sevenDay].compactMapValues { $0 }
        return UsagePauseRule.resetsAt(windows: windows, pause: pause, now: now) != nil
    }

    /// 引数からアカウントの `--settings` を外し、`settingsPath` があれば足す（ほかの `--settings` は残す）
    static func replacing(_ args: [String], with settingsPath: String?) -> [String] {
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--settings", index + 1 < args.count, ClaudeAccount.name(inArguments: [arg, args[index + 1]]) != nil {
                index += 2
                continue
            }
            if arg.hasPrefix("--settings="), ClaudeAccount.name(inArguments: [arg]) != nil {
                index += 1
                continue
            }
            result.append(arg)
            index += 1
        }
        return result + (settingsPath.map { ["--settings", $0] } ?? [])
    }

    /// アカウントの名前は settings のファイル名になる。英数字・`-`・`_` だけで、ログインの名前は使えない
    static func acceptsName(_ name: String) -> Bool {
        name != ClaudeAccount.login && !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func settings(token: String, name: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(["env": ["CLAUDE_CODE_OAUTH_TOKEN": token, ClaudeAccount.environmentName: name]])
    }

    private func settingsURL(_ name: String) -> URL { directory.appending(path: name + ".json") }

    private func removeStale(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".json") && !names.contains(String(file.dropLast(".json".count))) {
            try? FileManager.default.removeItem(at: directory.appending(path: file))
        }
    }
}

/// `claude-accounts.json`: `{"default": "main", "accounts": [{"name": "sub", "tokenFile": "~/path/.env", "tokenVariable": "CLAUDE_TOKEN", "boards": ["DAS"]}]}`。
/// `tokenVariable` があれば、ファイルの `NAME=value` の行から読む（無ければファイル全体がトークン）。`boards` は、そのアカウントで起こす案件（id か名前）。
/// `default` は、割り当ての無い会話を起こすアカウント（省けばマシンのログイン）
struct ClaudeAccountsConfig: Decodable, Equatable {
    struct Account: Decodable, Equatable {
        var name: String
        var tokenFile: String
        var tokenVariable: String?
        var boards: [String]?
    }

    var `default`: String?
    var accounts: [Account]

    /// ファイルが無ければ nil
    static func load(from url: URL) throws -> ClaudeAccountsConfig? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ClaudeAccountsConfig.self, from: Data(contentsOf: url))
    }
}

enum ClaudeAccountError: Error, Equatable {
    case unknown(String, [String])

    var message: String {
        switch self {
        case .unknown(let name, let names):
            "Claude Code のアカウント \(name) がありません。使えるのは " + ([ClaudeAccount.login] + names).joined(separator: "・") + " です"
        }
    }
}

extension [Board] {
    /// 案件の id と名前（アカウントの割り当ての `boards` と比べる）。案件が無ければ id だけ
    func keys(of id: String) -> Set<String> {
        guard let board = first(where: { $0.id == id }) else { return [id] }
        return [board.id, board.name]
    }
}
