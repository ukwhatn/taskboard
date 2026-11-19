import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// `claude plugin` の偽物。起こされた引数を控え、サブコマンド（`install`・`marketplace remove` など）ごとに決めた出力を返す
private final class FakePluginCLI: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var outputs: [String: [(Int32, String)]] = [:]

    /// 1 回ごとに頭から使い、最後の 1 つは使い続ける
    func answer(_ command: String, _ replies: (Int32, String)...) { lock.withLock { outputs[command] = replies } }
    var all: [[String]] { lock.withLock { calls } }

    func run(_ arguments: [String]) -> Subprocess.Outcome {
        lock.withLock {
            calls.append(arguments)
            let command = arguments.dropFirst().first == "marketplace" ? "marketplace " + (arguments.dropFirst(2).first ?? "") : arguments.dropFirst().first ?? ""
            var queue = outputs[command] ?? [(0, #"{"outcome":"ok"}"#)]
            let (status, stdout) = queue[0]
            if queue.count > 1 { queue.removeFirst() }
            outputs[command] = queue
            // 終了コード -1 は時間切れ、-2 は出力の上限
            return Subprocess.Outcome(status: status, stdout: Data(stdout.utf8), stderr: Data("stderr SECRET-TOKEN".utf8), timedOut: status == -1, overflowed: status == -2)
        }
    }
}

@Suite("Claude の plugin と marketplace（偽の CLI）", .serialized)
struct ClaudePluginsTests {
    private let machine = MachineID(rawValue: "m-plugins")

    private func make() async throws -> (ClaudeConversation, FakeHost, FakePluginCLI) {
        try await make(logs: LogLines())
    }

    private func make(logs: LogLines) async throws -> (ClaudeConversation, FakeHost, FakePluginCLI) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話"))
        let saved = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w/app", model: "haiku", runner: .none))
        let host = FakeHost()
        let cli = FakePluginCLI()
        var timing = ConversationTiming()
        timing.control = .seconds(2)
        timing.stopResult = .milliseconds(300)
        timing.stopInput = .milliseconds(300)
        timing.stopTerm = .milliseconds(300)
        var context = ClaudeConversation.Context(
            shared: ConversationContext(
                machine: machine, store: store, host: host, launch: { EngineLaunch(executable: "/x/claude", environment: ["PATH": "/usr/bin", "CLAUDE_CODE_CHILD_SESSION": "1"]) },
                attachments: nil, guide: { _ in nil }, becameIdle: { _ in }, logger: logs.logger, timing: timing))
        context.readFile = { url in
            url.path == "/w/app/.claude/settings.json" ? Data(#"{"extraKnownMarketplaces":{"m":{"source":{"source":"directory","path":"/m"}}}}"#.utf8) : nil
        }
        context.pluginCLI = { _, arguments, environment, cwd in
            #expect(environment == ["PATH": "/usr/bin"] && cwd == "/w/app")
            return cli.run(arguments)
        }
        let conversation = ClaudeConversation(record: saved, context: context)
        await host.connect(conversation.inbox, key: saved.id)
        await host.setReply("reload_plugins", #"{"commands":[],"agents":[],"plugins":[],"mcpServers":[],"error_count":0}"#)
        try await conversation.start(resume: false)
        return (conversation, host, cli)
    }

    private func edit(_ conversation: ClaudeConversation, _ edit: ConversationSettingsEdit) async throws -> ConversationSettingsEditResult {
        let response = try await conversation.control(ConversationControlRequest(kind: .editSettings, edit: edit))
        return try WireJSON.decoder().decode(ConversationSettingsEditResult.self, from: Data(try #require(response.payloadJSON).utf8))
    }

    private func reloads(_ host: FakeHost) async -> Int { await host.written("reload_plugins").count }

    private func rejection(_ body: () async throws -> Any) async -> ConversationError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? ConversationError
        }
    }

    private static let refused = #"{"command":"install","outcome":"failed","plugin":"cmdp@m","failureCode":"command_source_refused","message":"English","shownCommand":{"kind":"command_source","pluginId":"cmdp@m","command":"echo /p","mode":"copy","catalogRevision":"sha256:c","sha256":"fe01"}}"#

    @Test("コマンドで入れる plugin：1 回目は CLI が見せたコマンドと sha256 を返して入れず、読み直しも送らない。人が見た sha256 を acceptCommand で渡すと --accept-command で入れ、reload_plugins を送る")
    func installsCommandSourceInTwoSteps() async throws {
        let (conversation, host, cli) = try await make()
        // CLI は JSON の行の前に人向けの文を出す
        cli.answer("install", (1, "\"cmdp\" is installed by running a command\n  echo /p\n" + Self.refused), (0, #"{"command":"install","outcome":"ok"}"#))
        let first = try await edit(conversation, .plugin(op: .install, id: "cmdp@m", scope: .user))
        #expect(first.shownCommand == .init(command: "echo /p", sha256: "fe01"))
        #expect(cli.all.last == ["plugin", "install", "cmdp@m", "--json", "-s", "user"])
        #expect(await reloads(host) == 0)

        let second = try await edit(conversation, .plugin(op: .install, id: "cmdp@m", scope: .user, acceptCommand: "fe01"))
        #expect(second == .init())
        #expect(cli.all.last == ["plugin", "install", "cmdp@m", "--json", "-s", "user", "--accept-command", "fe01"])
        #expect(await reloads(host) == 1)
    }

    @Test("外す：データの置き場は残す（--keep-data）。保存した設定がある plugin は設定の名前と digest を返して外さず、confirm と同じ digest の送り直しだけで外す。層を省いたら入れた層で外す")
    func uninstallKeepsDataAndConfirmsOptions() async throws {
        let (conversation, host, cli) = try await make()
        cli.answer("configure", (0, #"{"pluginId":"p@m","inputs":{"token":"secret-value"},"configured":["token"],"unconfigured":[]}"#))
        cli.answer("list", (0, #"[{"id":"p@m","version":"1.0.0","scope":"local","enabled":true,"hasUserConfig":true},{"id":"q@m","scope":"user","hasUserConfig":false}]"#))
        let asked = try #require(try await edit(conversation, .plugin(op: .uninstall, id: "p@m")).confirmation)
        #expect(asked.loss == .options && asked.plugins == [.init(id: "p@m", scope: "local")] && asked.options == ["token"] && asked.digest.count == 64)
        #expect(!String(decoding: try JSONEncoder().encode(asked), as: UTF8.self).contains("secret-value"))
        // confirm だけ・違う digest では外さず、確かめ直す
        for digest in [nil, String(repeating: "0", count: 64)] {
            #expect(try await edit(conversation, .plugin(op: .uninstall, id: "p@m", confirm: true, confirmDigest: digest)).confirmation == asked)
        }
        #expect(!cli.all.contains { $0.dropFirst().first == "uninstall" })

        #expect(try await edit(conversation, .plugin(op: .uninstall, id: "p@m", confirm: true, confirmDigest: asked.digest)) == .init())
        #expect(cli.all.last == ["plugin", "uninstall", "p@m", "--json", "-s", "local", "--keep-data"])
        #expect(await reloads(host) == 1)

        // 保存する設定の無い plugin は CLI に聞かずに外す
        let configures = cli.all.filter { $0.dropFirst().first == "configure" }.count
        #expect(try await edit(conversation, .plugin(op: .uninstall, id: "q@m", scope: .user)) == .init())
        #expect(cli.all.last == ["plugin", "uninstall", "q@m", "--json", "-s", "user", "--keep-data"])
        #expect(cli.all.filter { $0.dropFirst().first == "configure" }.count == configures)
        // 入れていない（その層に無い）plugin は外さない
        let error = await rejection { try await self.edit(conversation, .plugin(op: .uninstall, id: "q@m", scope: .project)) }
        #expect(error?.params["reason"] == "not_found")
    }

    @Test("保存した設定を読めない（終了コード・時間切れ・出力の上限・JSON の誤り・configured の型の違い）ときは、設定なしとみなさず外さない")
    func optionsReadFailureBlocksUninstall() async throws {
        let (conversation, _, cli) = try await make()
        cli.answer("list", (0, #"[{"id":"p@m","scope":"user","hasUserConfig":true}]"#))
        for (status, stdout) in [(1, #"{"configured":[]}"#), (-1, #"{"configured":[]}"#), (-2, #"{"configured":[]}"#), (0, "{broken"), (0, #"{"configured":"token"}"#), (0, #"{}"#)] {
            cli.answer("configure", (Int32(status), stdout))
            let error = await rejection { try await self.edit(conversation, .plugin(op: .uninstall, id: "p@m")) }
            #expect(error?.code == .sessionCommandFailed && error?.status == 502, "\(status) \(stdout)")
            let marketplace = await rejection { try await self.edit(conversation, .marketplace(op: .remove, name: "m")) }
            #expect(marketplace?.status == 502, "\(status) \(stdout)")
        }
        #expect(!cli.all.contains { $0.dropFirst().first == "uninstall" || $0.contains("remove") })
    }

    @Test("データごと消す：いつも確かめ、confirm と同じ digest で --keep-data を付けずに外す")
    func purgeAlwaysConfirms() async throws {
        let (conversation, _, cli) = try await make()
        cli.answer("list", (0, #"[{"id":"p@m","scope":"user","hasUserConfig":false}]"#))
        let asked = try #require(try await edit(conversation, .plugin(op: .purge, id: "p@m", scope: .user)).confirmation)
        #expect(asked.loss == .data && asked.plugins == [.init(id: "p@m", scope: "user")] && asked.options.isEmpty)
        #expect(try await edit(conversation, .plugin(op: .purge, id: "p@m", scope: .user, confirm: true)).confirmation == asked)
        #expect(!cli.all.contains { $0.dropFirst().first == "uninstall" })
        _ = try await edit(conversation, .plugin(op: .purge, id: "p@m", scope: .user, confirm: true, confirmDigest: asked.digest))
        #expect(cli.all.last == ["plugin", "uninstall", "p@m", "--json", "-s", "user"])
    }

    @Test("marketplace を外す：先に plugin を入れた層でデータを残して外してから外す。確かめた後に plugin が増えたら digest が替わり、確かめ直す。層を付けたらその層の plugin だけを対象にする")
    func removesMarketplaceAfterPlugins() async throws {
        let (conversation, _, cli) = try await make()
        cli.answer(
            "list", (0, #"[{"id":"a@m","scope":"user","hasUserConfig":false},{"id":"b@m","scope":"project","hasUserConfig":true},{"id":"c@other","scope":"user"}]"#),
            (0, #"[{"id":"a@m","scope":"user","hasUserConfig":false},{"id":"b@m","scope":"project","hasUserConfig":true},{"id":"d@m","scope":"user","hasUserConfig":false}]"#))
        cli.answer("configure", (0, #"{"configured":["key"]}"#))
        let first = try #require(try await edit(conversation, .marketplace(op: .remove, name: "m")).confirmation)
        #expect(first.plugins == [.init(id: "a@m", scope: "user"), .init(id: "b@m", scope: "project")] && first.options == ["key"])
        // 確かめた後に d@m が入った：見せた対象と違うので書かない
        let second = try #require(try await edit(conversation, .marketplace(op: .remove, name: "m", confirm: true, confirmDigest: first.digest)).confirmation)
        #expect(second.digest != first.digest && second.plugins.map(\.id) == ["a@m", "b@m", "d@m"])
        #expect(!cli.all.contains { $0.contains("remove") || $0.dropFirst().first == "uninstall" })

        _ = try await edit(conversation, .marketplace(op: .remove, name: "m", confirm: true, confirmDigest: second.digest))
        let writes = cli.all.filter { $0.dropFirst().first == "uninstall" || $0.contains("remove") }
        #expect(
            writes == [
                ["plugin", "uninstall", "a@m", "--json", "-s", "user", "--keep-data"], ["plugin", "uninstall", "b@m", "--json", "-s", "project", "--keep-data"],
                ["plugin", "uninstall", "d@m", "--json", "-s", "user", "--keep-data"], ["plugin", "marketplace", "remove", "m", "--json"],
            ])
    }

    @Test("外す対象を決める一覧の形が違う（配列でない・表でない項目・id か層の無い項目・壊れた JSON）ときは、空とみなさず何も外さない。正しい空の配列なら marketplace だけを外す")
    func removalNeedsReadableList() async throws {
        let (conversation, _, cli) = try await make()
        for list in [#"{}"#, #"[{"scope":"user"}]"#, #"[{"id":"a@m"}]"#, #"["a@m"]"#, "[{broken"] {
            cli.answer("list", (0, list))
            let marketplace = await rejection { try await self.edit(conversation, .marketplace(op: .remove, name: "m")) }
            #expect(marketplace?.status == 502, "\(list)")
            let plugin = await rejection { try await self.edit(conversation, .plugin(op: .uninstall, id: "a@m")) }
            #expect(plugin?.status == 502, "\(list)")
        }
        #expect(!cli.all.contains { $0.dropFirst().first == "uninstall" || $0.contains("remove") })
        cli.answer("list", (0, "[]"))
        _ = try await edit(conversation, .marketplace(op: .remove, name: "m"))
        #expect(cli.all.filter { $0.dropFirst().first == "uninstall" || $0.contains("remove") } == [["plugin", "marketplace", "remove", "m", "--json"]])
    }

    @Test("層を付けた marketplace の削除は、その層の plugin だけを外し、確かめる対象にもその層のものだけを入れる")
    func removesMarketplaceInOneScope() async throws {
        let (conversation, _, cli) = try await make()
        cli.answer("list", (0, #"[{"id":"a@m","scope":"user","hasUserConfig":true},{"id":"b@m","scope":"project","hasUserConfig":true}]"#))
        cli.answer("configure", (0, #"{"configured":["key"]}"#))
        let asked = try #require(try await edit(conversation, .marketplace(op: .remove, name: "m", scope: .project)).confirmation)
        #expect(asked.plugins == [.init(id: "b@m", scope: "project")])
        _ = try await edit(conversation, .marketplace(op: .remove, name: "m", scope: .project, confirm: true, confirmDigest: asked.digest))
        let writes = cli.all.filter { $0.dropFirst().first == "uninstall" || $0.contains("remove") }
        #expect(writes == [["plugin", "uninstall", "b@m", "--json", "-s", "project", "--keep-data"], ["plugin", "marketplace", "remove", "m", "--json", "--scope", "project"]])

        // その層が宣言していない marketplace は、plugin を外す前に断る（CLI は外した後で not_configured で断る）
        let before = cli.all.count
        let error = await rejection { try await self.edit(conversation, .marketplace(op: .remove, name: "m", scope: .local, confirm: true, confirmDigest: asked.digest)) }
        #expect(error?.params["reason"] == "not_found" && cli.all.count == before)
    }

    @Test("途中で失敗した削除：外せた分は戻さず、入れた plugin の一覧を読み直して reload_plugins を送ってから失敗を返す")
    func partialRemovalRefreshes() async throws {
        let (conversation, host, cli) = try await make()
        cli.answer("list", (0, #"[{"id":"a@m","scope":"user","hasUserConfig":false},{"id":"b@m","scope":"user","hasUserConfig":false}]"#))
        cli.answer("uninstall", (0, #"{"outcome":"ok"}"#), (1, #"{"outcome":"failed","failureCode":"x","message":"boom"}"#))
        let error = await rejection { try await self.edit(conversation, .marketplace(op: .remove, name: "m")) }
        #expect(error?.code == .sessionCommandFailed)
        #expect(!cli.all.contains { $0.contains("remove") })
        // 対象を決める 1 回と、失敗の後の読み直しの 1 回
        #expect(cli.all.filter { $0 == ["plugin", "list", "--json"] }.count == 2)
        #expect(await reloads(host) == 1)
    }

    @Test("断り：理由の種類だけを返し、CLI の文は応答にもログにも出さない。切った plugin を切るのは成功。- で始まる id と source、改行を含む source は CLI を起こさない。パスの空白は通す")
    func rejections() async throws {
        let logs = LogLines()
        let (conversation, _, cli) = try await make(logs: logs)
        cli.answer("uninstall", (1, #"{"command":"uninstall","outcome":"failed","failureCode":"not_installed","message":"Plugin \"x@m\" not found in installed plugins SECRET-TOKEN"}"#))
        cli.answer("configure", (0, #"{"configured":[]}"#))
        cli.answer("list", (0, #"[{"id":"x@m","scope":"user","hasUserConfig":false}]"#))
        do {
            _ = try await edit(conversation, .plugin(op: .uninstall, id: "x@m", scope: .user))
            Issue.record("断りを成功にした")
        } catch let error as ConversationError {
            #expect(error.params == ["reason": "not_found"] && !error.description.contains("installed plugins"))
        }
        cli.answer("disable", (1, #"{"command":"disable","outcome":"failed","failureCode":"already_in_goal_state","alreadyInGoalState":true}"#))
        #expect(try await edit(conversation, .plugin(op: .disable, id: "x@m")) == .init())
        cli.answer("marketplace add", (1, #"{"outcome":"failed","message":"bad source SECRET-TOKEN"}"#), (0, #"{"outcome":"ok"}"#))
        _ = await rejection { try await self.edit(conversation, .marketplace(op: .add, source: "/tmp/x")) }
        #expect(!logs.joined.contains("SECRET-TOKEN") && logs.joined.contains("conversation settings rejected"))
        #expect(try await edit(conversation, .marketplace(op: .add, source: "/Users/u/My Plugins")) == .init())
        #expect(cli.all.last == ["plugin", "marketplace", "add", "/Users/u/My Plugins", "--json"])
        let before = cli.all.count
        for bad in [ConversationSettingsEdit.plugin(op: .install, id: "--yes"), .marketplace(op: .add, source: "-x"), .marketplace(op: .add, source: "a\nb"), .plugin(op: .install, id: "a b")] {
            do {
                _ = try await edit(conversation, bad)
                Issue.record("\(bad) を受けた")
            } catch let error as ConversationError {
                #expect(error.code == .invalidRequest)
            }
        }
        #expect(cli.all.count == before)
    }

    @Test("一覧：入れた plugin と、入れていない plugin を文字で絞って 200 件まで（数は全体）。marketplace は足した元つき")
    func listsPlugins() async throws {
        let (conversation, _, cli) = try await make()
        let available = (0..<250).map { #"{"pluginId":"tool\#($0)@official","name":"tool\#($0)","description":"Tool","marketplaceName":"official","source":{"source":"github","repo":"o/r"}}"# }
            + [#"{"pluginId":"p@m","name":"p","marketplaceName":"m","source":"./plugins/p"}"#, #"{"pluginId":"zebra@m","name":"zebra","description":"Stripes","marketplaceName":"m","source":"./z"}"#]
        cli.answer("list", (0, #"{"installed":[{"id":"p@m","version":"1.0.0","scope":"user","enabled":false,"hasUserConfig":true}],"available":[\#(available.joined(separator: ","))]}"#))
        cli.answer("marketplace list", (0, #"[{"name":"m","source":"directory","path":"/tmp/m"},{"name":"official","source":"github","repo":"o/r"}]"#))
        let all = try WireJSON.decoder().decode(
            ConversationPlugins.self, from: Data(try #require(try await conversation.control(ConversationControlRequest(kind: .plugins)).payloadJSON).utf8))
        #expect(all.installed == [.init(id: "p@m", name: "p", marketplace: "m", version: "1.0.0", scope: "user", installed: true, enabled: false, hasOptions: true)])
        #expect(all.available.count == 200 && all.availableTotal == 251 && !all.available.contains { $0.id == "p@m" })
        #expect(all.marketplaces == [.init(name: "m", source: "/tmp/m"), .init(name: "official", source: "o/r")])
        let zebra = try WireJSON.decoder().decode(
            ConversationPlugins.self, from: Data(try #require(try await conversation.control(ConversationControlRequest(kind: .plugins, value: "STRIPE")).payloadJSON).utf8))
        #expect(zebra.available == [.init(id: "zebra@m", name: "zebra", marketplace: "m", description: "Stripes", installed: false, source: "local")] && zebra.availableTotal == 1)
        #expect(cli.all.contains(["plugin", "list", "--json", "--available"]))
    }
}
