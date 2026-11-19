import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Claude Code のアカウント")
struct ClaudeAccountsTests {
    let now = Date(timeIntervalSince1970: 1_791_100_000)
    let pause = MachineSettings.UsagePause(fiveHourPercent: 90, sevenDayPercent: 95)
    let entries = [ClaudeAccounts.Entry(name: "sub", boards: ["DAS"]), ClaudeAccounts.Entry(name: "spare", boards: [])]

    func usage(login: Double?, sub: Double? = nil, spare: Double? = nil) -> UsageSnapshot {
        func claude(_ percent: Double?) -> ClaudeUsage? {
            percent.map { ClaudeUsage(fiveHour: UsageWindow(usedPercent: $0, resetsAt: now.addingTimeInterval(3_600), windowSeconds: 18_000), sevenDay: nil, at: now) }
        }
        return UsageSnapshot(
            claude: claude(login),
            claudeAccounts: [ClaudeAccount(name: "sub", boards: ["DAS"], usage: claude(sub)), ClaudeAccount(name: "spare", boards: [], usage: claude(spare))])
    }

    /// 1 週間の枠。値は (使用率, 戻るまでの日数)。nil のアカウントは枠を知らない
    func weekly(login: (Double, Double)?, sub: (Double, Double)? = nil, spare: (Double, Double)? = nil) -> UsageSnapshot {
        func claude(_ value: (Double, Double)?) -> ClaudeUsage? {
            value.map {
                ClaudeUsage(fiveHour: nil, sevenDay: UsageWindow(usedPercent: $0.0, resetsAt: now.addingTimeInterval($0.1 * 86_400), windowSeconds: 604_800), at: now)
            }
        }
        return UsageSnapshot(
            claude: claude(login),
            claudeAccounts: [ClaudeAccount(name: "sub", boards: ["DAS"], usage: claude(sub)), ClaudeAccount(name: "spare", boards: [], usage: claude(spare))])
    }

    func choose(
        requested: String? = nil, current: String? = nil, boards: Set<String> = [], fallback: String? = nil, resuming: Bool = false,
        _ usage: UsageSnapshot
    ) throws -> String? {
        try ClaudeAccounts.choose(
            requested: requested, current: current, boardKeys: boards, entries: entries, fallback: fallback, resuming: resuming, usage: usage,
            pause: pause, now: now)
    }

    @Test("引数の --settings がアカウントの settings を指すときだけ名前を返す。複数あれば最後のもの")
    func nameInArguments() {
        let dir = "/Users/u/Library/Application Support/taskboard/claude-accounts"
        #expect(ClaudeAccount.name(inArguments: ["--model", "opus", "--settings", "\(dir)/sub.json"]) == "sub")
        #expect(ClaudeAccount.name(inArguments: ["--settings=\(dir)/spare.json"]) == "spare")
        #expect(ClaudeAccount.name(inArguments: ["--settings", "\(dir)/sub.json", "--settings", "\(dir)/spare.json"]) == "spare")
        #expect(ClaudeAccount.name(inArguments: ["--settings", "/tmp/other.json"]) == nil)
        #expect(ClaudeAccount.name(inArguments: ["--settings"]) == nil)
        #expect(ClaudeAccount.name(inArguments: []) == nil)
    }

    @Test("入れ替えはアカウントの --settings だけを外して末尾に足し、ほかの --settings は残す。nil なら外すだけ")
    func replacing() {
        let dir = "/s/claude-accounts"
        let args = ["--model", "opus", "--settings", "\(dir)/sub.json", "--settings", "/tmp/hooks.json", "--settings=\(dir)/old.json"]
        #expect(ClaudeAccounts.replacing(args, with: "\(dir)/spare.json") == ["--model", "opus", "--settings", "/tmp/hooks.json", "--settings", "\(dir)/spare.json"])
        #expect(ClaudeAccounts.replacing(args, with: nil) == ["--model", "opus", "--settings", "/tmp/hooks.json"])
        #expect(ClaudeAccounts.replacing([], with: nil) == [])
    }

    @Test("頼まれたアカウントはそのまま使い、login はマシンのログイン。知らない名前は断る")
    func requested() throws {
        let full = usage(login: 100, sub: 100, spare: 100)
        #expect(try choose(requested: "sub", full) == "sub")
        #expect(try choose(requested: ClaudeAccount.login, current: "sub", full) == nil)
        #expect(throws: ClaudeAccountError.unknown("nope", ["sub", "spare"])) { try choose(requested: "nope", full) }
    }

    @Test("頼まれなければ、引数のアカウント → 案件の割り当て → ログインの順。設定から消えたアカウントは割り当てから決め直す")
    func preference() throws {
        let fresh = usage(login: 10, sub: 10, spare: 10)
        #expect(try choose(current: "spare", boards: ["DAS"], fresh) == "spare")
        #expect(try choose(boards: ["DAS", "board-1"], fresh) == "sub")
        #expect(try choose(boards: ["other"], fresh) == nil)
        #expect(try choose(current: "gone", boards: ["DAS"], fresh) == "sub")
    }

    @Test("選んだアカウントの枠が閾値を越えていれば、ログイン・設定の順で越えていない最初のものに移す。全部越えていれば元のまま")
    func movesWhenExhausted() throws {
        #expect(try choose(usage(login: 95, sub: 10)) == "sub")
        #expect(try choose(boards: ["DAS"], usage(login: 10, sub: 95)) == nil)
        #expect(try choose(boards: ["DAS"], usage(login: 95, sub: 95, spare: 20)) == "spare")
        #expect(try choose(boards: ["DAS"], usage(login: 95, sub: 95, spare: 95)) == "sub")
        // 枠を知らないアカウントは越えていないとみる
        #expect(try choose(boards: ["DAS"], usage(login: 95, sub: 95, spare: nil)) == "spare")
    }

    @Test("既定のアカウントがあれば、割り当ての無い会話はそれで起き、移し先にログインを入れない。頼まれた login だけはログイン")
    func fallbackAccount() throws {
        let fresh = usage(login: 10)
        #expect(try choose(boards: ["other"], fallback: "spare", fresh) == "spare")
        #expect(try choose(boards: ["DAS"], fallback: "spare", fresh) == "sub")
        #expect(try choose(current: "sub", fallback: "spare", fresh) == "sub")
        #expect(try choose(requested: ClaudeAccount.login, fallback: "spare", fresh) == nil)
        // ログインの枠が空いていても移さない
        #expect(try choose(fallback: "spare", usage(login: 10, sub: 10, spare: 95)) == "sub")
        #expect(try choose(boards: ["DAS"], fallback: "spare", usage(login: 10, sub: 95, spare: 95)) == "sub")
    }

    @Test("割り当ての無い新しい会話は、閾値を越えていないアカウントのうち 1 週間の枠が早く戻るものを選ぶ。戻る時刻の分からないものは後ろで、並びが同じなら既定のアカウント")
    func soonestReset() throws {
        #expect(try choose(fallback: "spare", weekly(login: (10, 1), sub: (10, 2), spare: (10, 3))) == "sub")
        #expect(try choose(weekly(login: (10, 1), sub: (10, 2), spare: (10, 3))) == nil)
        #expect(try choose(fallback: "spare", weekly(login: nil, sub: nil, spare: (10, 3))) == "spare")
        #expect(try choose(fallback: "spare", weekly(login: nil, sub: (96, 1), spare: (10, 3))) == "spare")
        #expect(try choose(fallback: "spare", weekly(login: nil)) == "spare")
    }

    @Test("案件の割り当てと再開の会話は、閾値を越えるまで今のアカウントのまま。越えたら、越えていないうち早く戻るものへ移す")
    func pinnedUntilExhausted() throws {
        let sooner = weekly(login: (10, 1), sub: (10, 4), spare: (10, 2))
        #expect(try choose(boards: ["DAS"], fallback: "spare", sooner) == "sub")
        #expect(try choose(current: "sub", fallback: "spare", sooner) == "sub")
        let loginLater = weekly(login: (10, 4), sub: (10, 1), spare: (10, 2))
        #expect(try choose(resuming: true, loginLater) == nil, "ログインで起きていた会話は、既定のアカウントが無ければログインのまま")
        #expect(try choose(loginLater) == "sub", "新しい会話なら早く戻る方")
        #expect(try choose(fallback: "spare", resuming: true, loginLater) == "sub", "既定のアカウントがあればログインを使わない")
        #expect(try choose(current: "sub", fallback: "spare", weekly(login: nil, sub: (96, 4), spare: (10, 5))) == "spare")
        #expect(try choose(current: "sub", weekly(login: (10, 6), sub: (96, 4), spare: (10, 5))) == "spare")
    }

    @Test("戻る時刻が過ぎた窓は越えていないとみる")
    func expiredWindow() {
        let past = ClaudeUsage(fiveHour: UsageWindow(usedPercent: 100, resetsAt: now.addingTimeInterval(-1), windowSeconds: 18_000), sevenDay: nil, at: now)
        #expect(!ClaudeAccounts.exhausted(past, pause: pause, now: now))
        #expect(!ClaudeAccounts.exhausted(nil, pause: pause, now: now))
    }

    @Test("reload はトークンを 0600 の settings に書き、使えない名前と読めないトークンを除き、設定から消えたアカウントの settings を消す")
    func reloadWritesSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "claude-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let env = root.appending(path: "tokens.env")
        try "CLAUDE_A=sk-ant-oat-aaa\nCLAUDE_B=\n".write(to: env, atomically: true, encoding: .utf8)
        let config = """
            {"accounts": [
              {"name": "sub", "tokenFile": "\(env.path)", "tokenVariable": "CLAUDE_A", "boards": ["DAS"]},
              {"name": "empty", "tokenFile": "\(env.path)", "tokenVariable": "CLAUDE_B"},
              {"name": "login", "tokenFile": "\(env.path)", "tokenVariable": "CLAUDE_A"},
              {"name": "../x", "tokenFile": "\(env.path)", "tokenVariable": "CLAUDE_A"}
            ]}
            """
        try config.write(to: root.appending(path: "claude-accounts.json"), atomically: true, encoding: .utf8)
        let directory = root.appending(path: ClaudeAccount.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: "gone.json"))

        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        let accounts = ClaudeAccounts(supportDirectory: root, state: state, home: root.path)
        #expect(await accounts.reload() == [ClaudeAccounts.Entry(name: "sub", boards: ["DAS"])])

        let file = directory.appending(path: "sub.json")
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: String]]
        #expect(written?["env"] == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-aaa", ClaudeAccount.environmentName: "sub"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "gone.json").path))
        #expect(await state.usageSnapshot().claudeAccounts?.map(\.name) == ["sub"])

        // 引数はアカウントの settings を指し、名前に戻せる
        let applied = try await accounts.apply(to: ["--model", "opus"], requested: nil, boardKeys: ["DAS"], resuming: false, settings: pause, now: now)
        #expect(applied.account == "sub")
        #expect(applied.args == ["--model", "opus", "--settings", file.path])
        #expect(ClaudeAccount.name(inArguments: applied.args) == "sub")

        // 既定のアカウントは、割り当ての無い会話に使う。読めないアカウントを既定にしてもログインに戻る
        try config.replacingOccurrences(of: "{\"accounts\"", with: "{\"default\": \"sub\", \"accounts\"")
            .write(to: root.appending(path: "claude-accounts.json"), atomically: true, encoding: .utf8)
        #expect(try await accounts.apply(to: [], requested: nil, boardKeys: ["other"], resuming: false, settings: pause, now: now).account == "sub")
        #expect(await accounts.allExhausted(pause: pause, now: now) == false)
        try config.replacingOccurrences(of: "{\"accounts\"", with: "{\"default\": \"empty\", \"accounts\"")
            .write(to: root.appending(path: "claude-accounts.json"), atomically: true, encoding: .utf8)
        #expect(try await accounts.apply(to: [], requested: nil, boardKeys: ["other"], resuming: false, settings: pause, now: now).account == nil)

        // 設定を消すとアカウントも settings も消える
        try FileManager.default.removeItem(at: root.appending(path: "claude-accounts.json"))
        #expect(await accounts.reload().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await state.usageSnapshot().claudeAccounts == nil)
    }

    @Test("statusline の枠は報告のアカウントの枠に入り、ログインの枠を書き換えない。設定に無いアカウントの報告は載せない")
    func usagePerAccount() async {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t"))
        await state.setClaudeAccounts([ClaudeAccount(name: "sub", boards: [])])
        func report(_ session: String, _ percent: Double, account: String?) -> ClaudeUsageReport {
            ClaudeUsageReport(
                context: SessionContext(
                    agentSessionID: session, model: nil, effort: nil, usedPercent: nil, inputTokens: nil, windowSize: nil, account: account, at: now),
                fiveHour: UsageWindow(usedPercent: percent, resetsAt: now.addingTimeInterval(3_600), windowSeconds: 18_000), sevenDay: nil)
        }
        await state.record(report("a", 80, account: nil), now: now)
        await state.record(report("b", 5, account: "sub"), now: now)
        await state.record(report("c", 50, account: "unknown"), now: now)
        let usage = await state.usageSnapshot()
        #expect(usage.claude?.fiveHour?.usedPercent == 80)
        #expect(usage.claudeUsage(account: "sub")?.fiveHour?.usedPercent == 5)
        #expect(usage.claudeAccounts?.map(\.name) == ["sub"])
        #expect(usage.contexts.first { $0.agentSessionID == "b" }?.account == "sub")
        // 一覧を入れ直しても前の枠は残る
        await state.setClaudeAccounts([ClaudeAccount(name: "sub", boards: ["DAS"])])
        #expect(await state.usageSnapshot().claudeUsage(account: "sub")?.fiveHour?.usedPercent == 5)
    }

    @Test("同じセッションを別のアカウントで起こし直したら、記録の引数を新しいアカウントのものにする")
    func relinkReplacesArguments() throws {
        let store = try Store(inMemory: MachineID(rawValue: "m"))
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "アカウント"))
        let first = ["--settings", "/s/claude-accounts/sub.json"]
        let second = ["--settings", "/s/claude-accounts/spare.json"]
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "s1", cwd: "/tmp", label: "", launchArgs: first)
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "s1", cwd: "/tmp", label: "", launchArgs: second)
        #expect(try store.task(number: task.number)?.sessions.first?.launchArgs == second)
    }
}
