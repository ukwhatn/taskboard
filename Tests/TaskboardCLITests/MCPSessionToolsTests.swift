import Foundation
import MCP
import Synchronization
import TaskboardKit
import Testing

@testable import taskboard

// MARK: - セッション・オーケストレーター・設定

@Suite("taskboard mcp: セッションとマシンの操作")
struct MCPSessionMachineTests {
    @Test("session_resume は省くと最後に紐づいた止まっている会話を、ID を渡せばその会話を起こし直す")
    func resumeSession() async throws {
        var world = RecordingDaemon.World(
            snapshot: snapshot(tasks: [task(1, sessions: ["s-old", "s-new"])]))
        world.routes["POST /v1/tasks/1/sessions/resume"] = ok(SessionResumeResult(conversation: conversation(conversationA, phase: .idle)))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("session_resume", ["task_id": .int(1)])
        _ = try await tools.call("session_resume", ["task_id": .int(1), "session_id": .string("s-old")])
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/tasks/1/sessions/resume").map { try $0.decode(SessionResumeRequest.self).agentSessionID }
        #expect(sent == ["s-new", "s-old"])
    }

    @Test("session_history は会話ごとに題・ブランチ・動いているかを出す")
    func sessionHistory() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-a", "s-b"])]))
        world.routes["GET /v1/tasks/1/sessions/history"] = ok([
            SessionHistory(sessionID: "s-a", aiTitle: "ログインの直し", branch: "feature/login"), SessionHistory(sessionID: "s-b"),
        ])
        let (tools, _) = RecordingDaemon.tools(world)
        let lines = try await tools.call("session_history", ["task_id": .int(1)]).split(separator: "\n")
        #expect(lines[1] == "- s-a 止まっている 「ログインの直し」")
        #expect(lines[2] == "  - branch: feature/login")
        #expect(lines[3] == "- s-b 止まっている")
    }

    @Test("orchestrator_start は設定の引数に model を当てて、プロンプトを空で送る（daemon が起動プロンプトを入れる）。status と prompt も daemon に頼む")
    func orchestrator() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/settings"] = ok(MachineSettings.defaults)
        world.routes["POST /v1/orchestrator/start"] = ok(OrchestratorInfo())
        let info = OrchestratorInfo(enabled: true, lastError: "前の失敗")
        world.routes["GET /v1/orchestrator"] = ok(info)
        world.routes["POST /v1/orchestrator/prompt"] = ok(info)
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("orchestrator_start", ["model": .string("sonnet")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/orchestrator/start").first).decode(LaunchRequest.self)
        #expect(sent.prompt.isEmpty)
        #expect(sent.agentArgs == LaunchChoice(kind: .claude, model: "claude-sonnet-5", effort: .medium).args)

        let status = try await tools.call("orchestrator_status", [:])
        #expect(status == "オーケストレーターの状態\n- 常駐: 入\n- 居ない\n- 最後の失敗: 前の失敗")
        _ = try await tools.call("orchestrator_prompt", ["text": .string("全体を見て")])
        #expect(try RecordingDaemon.requests(host, "POST", "/v1/orchestrator/prompt").first?.decode(OrchestratorPromptRequest.self).text == "全体を見て")
    }

    @Test("orchestrator_restart は引数なしで daemon に破棄して再起動を頼み、起動中なら状態を、会話が決まっていれば会話の id を返す")
    func orchestratorRestart() async throws {
        for (info, expected) in [
            (OrchestratorInfo(), "- 状態: 起動中"), (OrchestratorInfo(conversationID: conversationA), "- conversation_id: \(conversationA)"),
        ] {
            var world = RecordingDaemon.World(snapshot: snapshot())
            world.routes["POST /v1/orchestrator/restart"] = ok(info)
            let (tools, host) = RecordingDaemon.tools(world)
            let text = try await tools.call("orchestrator_restart", [:])
            #expect(RecordingDaemon.requests(host, "POST", "/v1/orchestrator/restart").count == 1)
            #expect(text.contains(expected))
        }
    }

    @Test("settings_update は model・effort を今の引数に当て、選択肢に無い分は送らずに断る")
    func settings() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/settings"] = ok(MachineSettings.defaults)
        world.routes["PATCH /v1/settings"] = ok(MachineSettings(orchestrator: .init(enabled: false, agentArgs: []), idleStopMinutes: 0))
        let (tools, host) = RecordingDaemon.tools(world)
        #expect(try await tools.call("settings_get", [:]).contains("idle のセッションを停止するまで: 120 分"))
        let text = try await tools.call("settings_update", ["orchestrator_enabled": .bool(false), "orchestrator_effort": .string("high"), "idle_stop_minutes": .int(0)])
        let sent = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/settings").first).decode(MachineSettingsUpdate.self)
        #expect(sent.orchestratorEnabled == false && sent.idleStopMinutes == 0)
        #expect(sent.orchestratorAgentArgs == LaunchChoice(kind: .claude, model: "claude-opus-5-5[1m]", effort: .high).args)
        #expect(text.contains("停止しない"))
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("settings_update", ["idle_stop_minutes": .int(45)]) }
        #expect(RecordingDaemon.requests(host, "PATCH").count == 1)
    }

    @Test("settings_get は区切る使用率を出し、settings_update は渡した窓だけ送る。1〜100 の外は送らずに断る")
    func usagePauseSettings() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/settings"] = ok(MachineSettings.defaults)
        world.routes["PATCH /v1/settings"] = ok(MachineSettings.defaults)
        let (tools, host) = RecordingDaemon.tools(world)
        #expect(try await tools.call("settings_get", [:]).contains("利用枠で会話を区切る使用率: 5 時間 90%、7 日 99%"))
        _ = try await tools.call("settings_update", ["usage_pause_five_hour_percent": .int(85)])
        let sent = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/settings").first).decode(MachineSettingsUpdate.self)
        #expect(sent.usagePauseFiveHourPercent == 85 && sent.usagePauseSevenDayPercent == nil)
        for bad in [0, 101] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("settings_update", ["usage_pause_seven_day_percent": .int(bad)]) }
        }
        #expect(RecordingDaemon.requests(host, "PATCH").count == 1)
    }
}

// MARK: - 受信箱・PR・利用枠・health

@Suite("taskboard mcp: 受信箱・PR・利用枠・health")
struct MCPInboxHealthTests {
    @Test("inbox_list はアプリと同じ導出で並べ、inbox_dismiss は今の revision を付けて送る。無い項目は送らずに断る")
    func inbox() async throws {
        let open = Ask(
            machine: machine, askID: 4, taskNumber: 1, docID: 2, status: .open,
            questions: [AskQuestion(id: "q1", question: "移行してよいか", options: [AskOption(label: "はい")])], createdAt: t0)
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-a"])], asks: [open]))
        // 本物の daemon は無視と戻しの記録の一覧を返す（表に無い POST の既定は 204 で、client が本文を読めない）
        world.routes["POST /v1/inbox/dismiss"] = ok([InboxDismissal]())
        world.routes["POST /v1/inbox/restore"] = ok([InboxDismissal]())
        let (tools, host) = RecordingDaemon.tools(world)
        let list = try await tools.call("inbox_list", [:])
        #expect(list.hasPrefix("受信箱 1 件（対応待ち 1）\n- [ask/4] 対応待ち: 移行してよいか"), "\(list)")
        #expect(list.contains("#1 題1"))

        _ = try await tools.call("inbox_dismiss", ["item_ids": .array([.string("ask/4")])])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/inbox/dismiss").first).decode(InboxDismissRequest.self)
        #expect(sent.items == [InboxDismissRequest.Item(itemID: "ask/4", revision: "")])
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("inbox_dismiss", ["item_ids": .array([.string("ask/9")])]) }

        _ = try await tools.call("inbox_restore", ["item_ids": .array([.string("ask/4")])])
        #expect(try RecordingDaemon.requests(host, "POST", "/v1/inbox/restore").first?.decode(InboxRestoreRequest.self).itemIDs == ["ask/4"])
    }

    @Test("prs_list は取得の状態と PR を、category で絞って出す。prs_refresh は取り直しを頼む")
    func prs() async throws {
        let pr = PullRequestSummary(
            machine: machine, host: "github.com", account: "ukwhatn", category: .reviewRequested, url: "https://github.com/o/r/pull/3", repository: "o/r", number: 3,
            title: "直す", author: "someone", isDraft: false, headRef: "fix", createdAt: t0, updatedAt: t0, checks: .failure)
        let prs = PRSnapshot(accounts: [PRAccountStatus(host: "github.com", account: "ukwhatn", fetchedAt: t0)], pullRequests: [pr])
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/prs"] = ok(prs)
        world.routes["POST /v1/prs/refresh"] = ok(prs)
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("prs_list", [:])
        #expect(text.contains("- [reviewRequested] o/r#3 直す CI=FAILURE"))
        #expect(text.contains("https://github.com/o/r/pull/3"))
        #expect(try await tools.call("prs_list", ["category": .string("myDraft")]).contains("PR 0 件"))
        _ = try await tools.call("prs_refresh", [:])
        #expect(RecordingDaemon.requests(host, "POST", "/v1/prs/refresh").count == 1)
    }

    @Test("usage_get は利用枠と、context を使っている順に出す")
    func usage() async throws {
        let usage = UsageSnapshot(
            claude: ClaudeUsage(fiveHour: UsageWindow(usedPercent: 42.4, resetsAt: nil, windowSeconds: 18000), sevenDay: nil, at: t0),
            contexts: [
                SessionContext(agentSessionID: "s-a", model: "opus", effort: nil, usedPercent: 20, inputTokens: nil, windowSize: nil, at: t0),
                SessionContext(agentSessionID: "s-bbbbbbbbbb", model: nil, effort: nil, usedPercent: 80, inputTokens: nil, windowSize: nil, at: t0),
            ])
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/usage"] = ok(usage)
        let (tools, _) = RecordingDaemon.tools(world)
        let lines = try await tools.call("usage_get", [:]).split(separator: "\n").map(String.init)
        #expect(lines == ["Claude: 5 時間 42%", "context（使っている順）", "- s-bbbbbb… 80%", "- s-a… 20% opus"])
    }

    @Test("health はオーケストレーター・うまくいかなかった定期起動・常設タスクの無い定期起動・APNs の鍵の無さを 1 画面に出す")
    func healthReport() {
        let now = t0.addingTimeInterval(3600)
        let failedRun = ScheduleRun(id: 2, scheduleID: 4, scheduledAt: t0, trigger: .schedule, stage: .failed, error: "作業ディレクトリが無い: /gone", createdAt: t0)
        let snap = snapshot(
            tasks: [task(1, sessions: ["s-a"])],
            schedules: [schedule(4, lastRun: failedRun), schedule(5, task: nil)],
            orchestrator: OrchestratorInfo(enabled: true))
        let text = TaskboardTools.healthReport(snapshot: snap, apnsConfigured: false, now: now)
        #expect(text.contains("- gh: PR を取得していない"))
        #expect(text.contains("- APNs: 鍵が無い（iPhone・iPad に通知を送らない）"))
        #expect(text.contains("- オーケストレーター: 常駐 入、居ない"))
        #expect(text.contains("- [4] 朝の見回り: 前回 実行 2（定時、"))
        #expect(text.contains("失敗: 作業ディレクトリが無い: /gone（schedule_runs で履歴）"))
        #expect(text.contains("- [5] 朝の見回り: 常設タスクが無い"))
        #expect(text.hasSuffix("受信箱の対応待ち: 0 件（inbox_list）"))

        var conversational = snap
        conversational.orchestrator = OrchestratorInfo(enabled: true, conversationID: "c-1")
        let report = TaskboardTools.healthReport(snapshot: conversational, apnsConfigured: false, now: now)
        #expect(report.contains("- オーケストレーター: 常駐 入、会話 c-1"))
    }

    @Test("health は着手済みで動いていないタスクを数えて並べ、未着手のタスクは数えない")
    func healthStalledTasks() {
        let now = t0.addingTimeInterval(5 * 24 * 3600)
        let snap = snapshot(tasks: [task(1, sessions: ["s-a"]), task(2, column: "todo")])
        let text = TaskboardTools.healthReport(snapshot: snap, apnsConfigured: true, now: now)
        #expect(text.contains("着手済みで 3 日以上動いていないタスク: 1 件（inbox_list の stall/<番号>）\n- [stall/1] お知らせ: #1 題1"))
        #expect(!text.contains("stall/2"))
    }

    @Test("health の見張りの節は有効・取れていない・取り消しを数え、取れていない見張りと、取り消したか届け先の会話が無くなって終えた見張りだけを並べる")
    func healthWatches() {
        let url = "https://github.com/o/r/pull/3"
        var snap = snapshot(tasks: [task(1)])
        snap.watches = [
            Watch(watchID: 1, machine: machine, url: url, taskNumber: 1, fetchedAt: t0, createdAt: t0, updatedAt: t0),
            Watch(watchID: 2, machine: machine, url: url, taskNumber: 1, error: "not found", createdAt: t0, updatedAt: t0),
            Watch(watchID: 3, machine: machine, url: url, taskNumber: 1, state: .cancelled, createdAt: t0, updatedAt: t0),
            Watch(watchID: 4, machine: machine, url: url, conversationID: "c-gone", state: .ended, ending: .targetMissing, createdAt: t0, updatedAt: t0),
            Watch(watchID: 5, machine: machine, url: url, taskNumber: 1, once: true, state: .ended, ending: .delivered, createdAt: t0, updatedAt: t0),
        ]
        let text = TaskboardTools.healthReport(snapshot: snap, apnsConfigured: true, now: t0)
        #expect(text.contains("## 監視（有効 2・取得できていない 1・取り消し 2。watch_list の all: true）"))
        #expect(text.contains("- [2] active \(url) → #1 の lead ・ 最後の取得: まだ取得できていない ・ 取得の失敗: not found"))
        #expect(text.contains("- [3] cancelled \(url) → #1 の lead"))
        #expect(text.contains("- [4] ended（target_missing） \(url) → 会話 c-gone"))
        #expect(!text.contains("- [1] "))
        #expect(!text.contains("- [5] "))
    }

    @Test("health は APNs の鍵の有無をファイルで見る（中身は読まない）")
    func healthReadsAPNsFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "tb-apns-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["AuthKey.p8", "apns.json"] { FileManager.default.createFile(atPath: dir.appending(path: name).path, contents: Data("x".utf8)) }
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: snapshot()), apns: dir)
        let text = try await tools.call("health", [:])
        #expect(text.contains("- APNs: 鍵と設定がある"))
    }
}

// MARK: - host の会話

@Suite("taskboard mcp: host の会話")
struct MCPConversationTests {
    @Test("session_list は会話を、動いているものを先に出し、待っている問いと裏のタスクを書く。自分の会話に印を付ける")
    func list() async throws {
        let snap = with(
            [conversation(conversationB, phase: .stopped, title: "前の調べ"), conversation(conversationA, phase: .waiting, requests: [question("r1")], title: "実装", backgroundKnown: false)],
            snapshot(tasks: [task(1)]))
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: snap), environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("session_list", [:])
        #expect(
            text == """
                host の会話 2 件
                - 会話 \(conversationA) waiting model=opus cwd=/w 「実装」 → #1 題1 回答待ち 1（session_answer） 裏のタスク 不明  ← このセッション
                - 会話 \(conversationB) stopped（止めた） model=opus cwd=/w 「前の調べ」 → #1 題1
                """)
    }

    @Test("session_list の会話の行に effort・コンテキストの使用率・フォーク元・差分を書く")
    func listE3() async throws {
        var forked = conversation(conversationA, phase: .idle, title: "分けた")
        forked.effort = "high"
        forked.contextPercent = 42
        forked.forkSource = conversationB
        forked.forkPending = true
        forked.diff = ConversationDiffSummary(isRepo: true, branch: "main", files: 3, insertions: 10, deletions: 2)
        var terminal = conversation(conversationB, phase: .stopped, title: "元")
        terminal.diff = ConversationDiffSummary(isRepo: true, branch: "main")
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: with([forked, terminal])))
        let text = try await tools.call("session_list", [:])
        #expect(
            text == """
                host の会話 2 件
                - 会話 \(conversationA) idle model=opus effort=high コンテキスト 42% cwd=/w 「分けた」 → #1 題1 フォーク元 6f1d2b8e（まだ送っていない） 差分 3 ファイル +10 -2
                - 会話 \(conversationB) stopped（止めた） model=opus cwd=/w 「元」 → #1 題1
                """)
    }

    @Test("session_list の会話の行に役目・未通知・利用枠の上限の待ちを書く")
    func listE4() async throws {
        var child = conversation(conversationA, phase: .stopped, title: "委譲")
        child.parentNoticePending = true
        let resumeAt = Date(timeIntervalSince1970: 1_791_003_600)
        child.limitResumeAt = resumeAt
        var orchestrator = conversation(conversationB, phase: .idle, title: "オーケストレーター")
        orchestrator.purpose = .orchestrator
        orchestrator.taskNumber = nil
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: with([child, orchestrator])))
        let text = try await tools.call("session_list", [:])
        #expect(
            text == """
                host の会話 2 件
                - 会話 \(conversationB) idle model=opus cwd=/w 「オーケストレーター」 オーケストレーター
                - 会話 \(conversationA) stopped（止めた） model=opus cwd=/w 「委譲」 → #1 題1 未通知 利用枠の上限のため \(TaskboardTools.time(resumeAt)) に続きを送る
                """)
    }

    @Test("session_fork は conversation_id を頭から引き、message_id と prompt を載せて送る。requestID は tool が振る")
    func fork() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .idle)]))
        world.routes["POST /v1/conversations/\(conversationA)/fork"] = ok(conversation(conversationB, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call(
            "session_fork", ["conversation_id": .string(String(conversationA.prefix(12))), "message_id": .string("u-1"), "prompt": .string("別案で")])
        #expect(
            text == """
                会話を分けた
                - 元の会話: \(conversationA)
                - conversation_id: \(conversationB)
                - 分けた位置: 発言 u-1 まで
                - タスク: #1 題1
                - 次の操作: 指示は session_prompt の conversation_id
                """)
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/fork").map { try $0.decode(ConversationForkRequest.self) }
        #expect(sent.count == 1 && sent.first?.messageID == "u-1" && sent.first?.prompt == "別案で" && sent.first?.requestID.isEmpty == false)
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_fork", [:]) }
    }

    @Test("session_prompt は conversation_id を頭 8 字からでも引いて送る。当たらない頭・短すぎる頭・自分の会話は送らずに断る")
    func prompt() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .idle)]))
        world.routes["POST /v1/conversations/\(conversationA)/messages"] = ok(ConversationSendResponse(outcome: "accepted"))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationB])
        let text = try await tools.call("session_prompt", ["conversation_id": .string(conversationA.uppercased()), "text": .string("続けて")])
        #expect(text == "会話に文を送った\n- conversation_id: \(conversationA)\n- 字数: 3\n- 状態: 生成中のため待ち行列に追加された")
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/messages").map { try $0.decode(ConversationSendRequest.self).text }
        #expect(sent == ["<!-- taskboard: session_prompt from=\(conversationB.prefix(8)) task=1 -->\n[taskboard 通知] 別のセッションからの発言\n- 送り主: 会話 \(conversationB.prefix(8))（#1）。人の発言ではない\n本文:\n続けて"])
        for args: [String: Value] in [
            ["conversation_id": .string("6f1d2b8e"), "text": .string("x")],
            ["conversation_id": .string("6f1d"), "text": .string("x")],
            ["conversation_id": .string("deadbeef-0000"), "text": .string("x")],
            ["conversation_id": .string(conversationB), "text": .string("x")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_prompt", args) }
        }
        #expect(RecordingDaemon.writes(host).count == 1)
    }

    @Test("session_answer は答えを省くと問いの中身を返し、質問には選択肢の label で、権限の確認には allow で答える")
    func answer() async throws {
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .waiting, requests: [question("r1"), permission("r2")])])))
        let ask = try await tools.call("session_answer", ["conversation_id": .string(conversationA)])
        #expect(ask == "まだ答えていない。回答待ちが 2 件ある。request_id で選ぶ\n回答待ち r1: 質問\n  - q0「色は？」 選択肢: 赤 / 青\n回答待ち r2: 権限の確認 Bash: ls")
        let detail = try await tools.call("session_answer", ["conversation_id": .string(conversationA), "request_id": .string("r2")])
        #expect(detail == "まだ答えていない。allow で許可か拒否を渡す\n回答待ち r2: 権限の確認 Bash: ls")
        #expect(RecordingDaemon.writes(host).isEmpty)

        _ = try await tools.call(
            "session_answer", ["conversation_id": .string(conversationA), "request_id": .string("r1"), "answers": .array([.object(["selected": .array([.string("赤")])])])])
        let done = try await tools.call(
            "session_answer", ["conversation_id": .string(conversationA), "request_id": .string("r2"), "allow": .bool(false), "message": .string("ls は不要")])
        #expect(done == "回答待ちに答えた\n- conversation_id: \(conversationA)\n- request_id: r2")
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/answers").map { try $0.decode(ConversationAnswerRequest.self) }
        #expect(
            sent == [
                ConversationAnswerRequest(requestID: "r1", answers: [AskAnswer(questionID: "q0", selected: ["赤"])]),
                ConversationAnswerRequest(requestID: "r2", allow: false, message: "ls は不要"),
            ])
    }

    @Test("session_answer の選択肢に無い label は daemon に送り、daemon の断りの文をそのまま返す")
    func answerMismatchFromDaemon() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .waiting, requests: [question("r1")])]))
        world.routes["POST /v1/conversations/\(conversationA)/answers"] = (400, Data(#"{"error":{"message":"「緑」は q0 の選択肢に無い。選択肢: 赤 / 青"}}"#.utf8))
        let (tools, host) = RecordingDaemon.tools(world)
        await #expect(throws: SessionSourceError.rejected(DaemonRejection(status: 400, message: "「緑」は q0 の選択肢に無い。選択肢: 赤 / 青", code: nil, params: [:]))) {
            try await tools.call(
                "session_answer",
                ["conversation_id": .string(conversationA), "request_id": .string("r1"), "answers": .array([.object(["selected": .array([.string("緑")])])])])
        }
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/answers").map { try $0.decode(ConversationAnswerRequest.self) }
        #expect(sent == [ConversationAnswerRequest(requestID: "r1", answers: [AskAnswer(questionID: "q0", selected: ["緑"])])])
    }

    @Test("session_answer は権限の確認の許可に、候補の id（suggestion_id）を添えて答える。無い候補・拒否・質問に添えたものは送らずに断る")
    func answerWithSuggestion() async throws {
        var asked = permission("r2")
        asked.suggestions = [PermissionSuggestion(id: "0", kind: .rule, subject: "Bash(ls)", scope: .folder)]
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .waiting, requests: [question("r1"), asked])])))
        let detail = try await tools.call("session_answer", ["conversation_id": .string(conversationA), "request_id": .string("r2")])
        #expect(detail.contains("今後は聞かない候補 0: 規則 Bash(ls) を許可（このフォルダの設定に保存）"))
        let base: [String: Value] = ["conversation_id": .string(conversationA), "request_id": .string("r2")]
        for extra: [String: Value] in [
            ["allow": .bool(true), "suggestion_id": .string("9")],
            ["allow": .bool(false), "suggestion_id": .string("0")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_answer", base.merging(extra, uniquingKeysWith: { $1 })) }
        }
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call(
                "session_answer",
                ["conversation_id": .string(conversationA), "request_id": .string("r1"), "allow": .bool(true), "suggestion_id": .string("0"),
                    "answers": .array([.object(["selected": .array([.string("赤")])])])])
        }
        #expect(RecordingDaemon.writes(host).isEmpty)
        _ = try await tools.call("session_answer", base.merging(["allow": .bool(true), "suggestion_id": .string("0")], uniquingKeysWith: { $1 }))
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/answers").map { try $0.decode(ConversationAnswerRequest.self) }
        #expect(sent == [ConversationAnswerRequest(requestID: "r2", allow: true, suggestionID: "0")])
    }

    @Test("session_answer は MCP の server の問いに action と content で答える。schema に合わない入力と、断る・取り消すだけの問いを受けるのは送らずに断る")
    func answerElicitation() async throws {
        let schema = #"{"type":"object","properties":{"name":{"type":"string","minLength":1},"age":{"type":"integer"}},"required":["name"]}"#
        let form = ConversationRequest(
            id: "e1", kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: RequestWaiting(id: "e1", since: Date(timeIntervalSince1970: 0)),
            elicitation: Elicitation(serverName: "github", message: "入れて", mode: .form, form: Elicitation.Form(schema: Data(schema.utf8))))
        let url = ConversationRequest(
            id: "e2", kind: .elicitation, toolName: "elicitation", toolUseID: nil, waiting: RequestWaiting(id: "e2", since: Date(timeIntervalSince1970: 0)),
            elicitation: Elicitation(serverName: "linear", message: "開いて", mode: .url))
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .waiting, requests: [form, url])])))
        let detail = try await tools.call("session_answer", ["conversation_id": .string(conversationA), "request_id": .string("e1")])
        #expect(detail.hasPrefix("まだ答えていない。action で答える\n回答待ち e1: MCP の確認（github）「入れて」"))
        let base: [String: Value] = ["conversation_id": .string(conversationA), "request_id": .string("e1"), "action": .string("accept")]
        for extra: [String: Value] in [
            ["content": .object(["age": .int(3)])],
            ["content": .object(["name": .string("x"), "age": .double(1.5)])],
            ["content": .object(["name": .array([])])],
            ["action": .string("approve"), "content": .object(["name": .string("x")])],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_answer", base.merging(extra, uniquingKeysWith: { $1 })) }
        }
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("session_answer", ["conversation_id": .string(conversationA), "request_id": .string("e2"), "action": .string("accept")])
        }
        #expect(RecordingDaemon.writes(host).isEmpty)
        _ = try await tools.call("session_answer", base.merging(["content": .object(["name": .string("山田"), "age": .int(30)])], uniquingKeysWith: { $1 }))
        _ = try await tools.call("session_answer", ["conversation_id": .string(conversationA), "request_id": .string("e2"), "action": .string("cancel")])
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/answers").map { try $0.decode(ConversationAnswerRequest.self) }
        #expect(
            sent == [
                ConversationAnswerRequest(requestID: "e1", action: .accept, content: ["name": .string("山田"), "age": .number(30)]),
                ConversationAnswerRequest(requestID: "e2", action: .cancel),
            ])
    }

    @Test("session_stop の conversation_id: 生成中は force が必要で、force のときとタスクに結ばれていない会話は confirm: true まで停止しない")
    func stop() async throws {
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .idle, task: nil)])))
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_stop", ["conversation_id": .string(conversationA)]) }
        let preview = try await tools.call("session_stop", ["conversation_id": .string(conversationA), "force": .bool(true)])
        #expect(preview.hasPrefix("まだ停止していない（confirm: true が無い）\n止まるもの:\n- 会話 \(conversationA) running model=opus cwd=/w → #1 題1\n- 生成中でも止まる\n- session_resume"))
        let unbound = try await tools.call("session_stop", ["conversation_id": .string(conversationB)])
        #expect(unbound.contains("\n- タスクに紐づいていないので、停止すると記録が削除されて再開できない\n"))
        #expect(RecordingDaemon.writes(host).isEmpty)

        _ = try await tools.call("session_stop", ["conversation_id": .string(conversationA), "force": .bool(true), "confirm": .bool(true)])
        let stopped = try await tools.call("session_stop", ["conversation_id": .string(conversationB), "confirm": .bool(true)])
        #expect(stopped == "会話を停止した\n- conversation_id: \(conversationB)\n- 記録: 削除した（タスクに紐づいていない）")
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/conversations/\(conversationA)/stop", "/v1/conversations/\(conversationB)/stop"])
    }

    @Test("session_stop の close: 止まっている会話はすぐ終了する（記録は残る）。生成中は force と confirm: true が必要で、それまでは何が止まるかを返すだけ")
    func close() async throws {
        let (tools, host) = RecordingDaemon.tools(
            .init(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .stopped, task: nil)])))
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("session_stop", ["conversation_id": .string(conversationA), "close": .bool(true)])
        }
        let running = try await tools.call("session_stop", ["conversation_id": .string(conversationA), "close": .bool(true), "force": .bool(true)])
        #expect(
            running == """
                まだ停止していない（confirm: true が無い）
                止まるもの:
                - 会話 \(conversationA) running model=opus cwd=/w → #1 題1
                - 生成中でも止まる
                停止すると今の作業は取り消せない。停止するなら、同じ引数に confirm: true を付けてもう一度呼び出す
                """)
        #expect(RecordingDaemon.writes(host).isEmpty)

        let closed = try await tools.call("session_stop", ["conversation_id": .string(conversationB), "close": .bool(true)])
        #expect(closed == "会話を終了した\n- conversation_id: \(conversationB)\n- 記録: 残した（session_list から外れる）\n- 次の操作: 再開は session_resume の conversation_id")
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/conversations/\(conversationB)/close"])
    }

    @Test("session_exit は、host の会話の中ならこの会話をターンの後に終了するよう daemon に頼み、外では断る。session_stop は自分の会話を断って session_exit へ案内する")
    func exit() async throws {
        let (tools, host) = RecordingDaemon.tools(
            .init(snapshot: with([conversation(conversationA, phase: .running)])), environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("session_exit", [:])
        #expect(
            text == "このターンを終えてから、この会話を終了する\n- conversation_id: \(conversationA)\n- 記録: 残す（session_list から外れる）\n- 次の操作: 報告を書いてターンを終える。再開は session_resume の conversation_id")
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/close").first).decode(ConversationCloseRequest.self)
        #expect(sent.afterTurn == true)
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("session_stop", ["conversation_id": .string(conversationA), "close": .bool(true)])
        }

        let (outside, outsideHost) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .running)])))
        await #expect(throws: TaskboardTools.ToolError.self) { try await outside.call("session_exit", [:]) }
        #expect(RecordingDaemon.writes(outsideHost).isEmpty)
    }

    @Test("session_list は終了した会話（人の終了・定期起動の回の終わり）を出さない")
    func listHidesClosed() async throws {
        var closed = conversation(conversationB, phase: .stopped)
        closed.lastExit = ConversationStopCause.closed.lastExit
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: with([conversation(conversationA, phase: .stopped), closed])))
        let text = try await tools.call("session_list", [:])
        #expect(text.contains(conversationA) && !text.contains(conversationB))
    }

    @Test("session_resume の conversation_id は止まっている会話を起こし直し、動いている会話には何も送らない")
    func resume() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .stopped)]))
        world.routes["POST /v1/conversations/\(conversationB)/resume"] = ok(conversation(conversationB, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        #expect(try await tools.call("session_resume", ["conversation_id": .string(conversationB)]) == "会話を再開した\n- conversation_id: \(conversationB)\n- 状態: idle\n- 作業ディレクトリ: /w\n- 次の操作: 指示は session_prompt の conversation_id")
        #expect(try await tools.call("session_resume", ["conversation_id": .string(conversationA)]) == "会話 \(conversationA) は動いている（running）ので再開は不要")
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/conversations/\(conversationB)/resume"])
    }

    @Test("session_start: claude は会話を起こし、model・effort・起動プロンプト・worktree・使わせない tool（要素の中のカンマでも分ける）を渡す。知らせる先の無い notify は断る")
    func start() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/conversations"] = ok(conversation(conversationA, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call(
            "session_start",
            [
                "task_id": .int(1), "model": .string("sonnet"), "effort": .string("high"), "prompt": .string("#{{id}} を調べて"), "cwd": .string("/w/x"),
                "worktree_branch": .string("feature/x"), "worktree_base": .string("main"), "disallowed_tools": .array([.string("Agent"), .string("Workflow, WebFetch"), .string(" ")]),
            ])
        #expect(
            text == """
                会話を起動した
                - conversation_id: \(conversationA)
                - タスク: #1 題1
                - モデル: Claude Code・Sonnet 5・high
                - 作業ディレクトリ: /w
                - 次の操作: 指示は session_prompt の conversation_id、状態は session_list
                """)
        var expected = ConversationStartRequest(
            cwd: "/w/x", taskNumber: 1, model: "claude-sonnet-5", effort: "high", prompt: "#{{id}} を調べて", extraArgs: ["--disallowedTools", "Agent", "Workflow", "WebFetch"])
        expected.worktree = LaunchRequest.WorktreeSpec(branch: "feature/x", base: "main")
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations").map { try $0.decode(ConversationStartRequest.self) }
        #expect(sent == [expected])
        for args: [String: Value] in [
            ["task_id": .int(1), "notify": .bool(true), "cwd": .string("/w")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_start", args) }
        }
        #expect(RecordingDaemon.writes(host).count == 1)
    }

    @Test("session_start: kind・model・effort を省くと案件の起動の既定で起こし、既定の無い案件は opus / medium。渡した値は既定に重ね、kind を替えたらその kind の既定。会話に渡せない既定の引数は断る")
    func startUsesBoardDefaults() async throws {
        func defaults(_ kind: AgentKind, _ args: [String]) -> LaunchDefaults { LaunchDefaults(kind: kind, agentArgs: args) }
        var boards = [board("b1", "default"), board("b2", "DAS", position: 1), board("b3", "c", position: 2), board("b4", "d", position: 3), board("b5", "e", position: 4)]
        boards[0].launchDefaults = defaults(.claude, ["--dangerously-skip-permissions", "--model", "claude-fable-5-1[1m]", "--effort", "high"])
        boards[2].launchDefaults = defaults(.codex, ["--model", "gpt-6.1-sol"])
        boards[3].launchDefaults = defaults(.claude, ["--dangerously-skip-permissions", "--add-dir", "/extra", "--model", "claude-fable-5-1[1m]"])
        boards[4].launchDefaults = defaults(.claude, ["--chrome"])
        var world = RecordingDaemon.World(
            snapshot: snapshot(boards: boards, tasks: [task(1), task(2, board: "b2"), task(3, board: "b3"), task(4, board: "b4"), task(5, board: "b5")]))
        world.routes["POST /v1/conversations"] = ok(conversation(conversationA, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        for args: [String: Value] in [
            ["task_id": .int(1)], ["task_id": .int(1), "effort": .string("low")], ["task_id": .int(1), "kind": .string("codex")], ["task_id": .int(2)],
            ["task_id": .int(3)], ["task_id": .int(3), "kind": .string("claude")], ["task_id": .int(4)],
        ] {
            _ = try await tools.call("session_start", args.merging(["cwd": .string("/w"), "prompt": .string("")]) { $1 })
        }
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations").map { try $0.decode(ConversationStartRequest.self) }
        #expect(sent.map(\.engine) == [nil, nil, .codex, nil, .codex, nil, nil])
        #expect(sent.map(\.model) == ["claude-fable-5-1[1m]", "claude-fable-5-1[1m]", nil, "claude-opus-5-5[1m]", "gpt-6.1-sol", "claude-opus-5-5[1m]", "claude-fable-5-1[1m]"])
        #expect(sent.map(\.effort) == ["high", "low", nil, "medium", nil, "medium", nil])
        // 構造に合わない既定は、wake と同じく会話の引数に読み替える
        #expect(sent.last?.permissionMode == "bypassPermissions" && sent.last?.extraArgs == ["--add-dir", "/extra"])

        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_start", ["task_id": .int(5), "cwd": .string("/w")]) }
    }

    @Test("session_start: codex は会話を起こし、モデルと effort は codex の名前のまま渡す。使わせない tool・形の違う名前は断る")
    func startCodexConversation() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/conversations"] = ok(conversation(conversationA, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call(
            "session_start",
            [
                "task_id": .int(1), "kind": .string("codex"), "model": .string("gpt-6.1-sol"), "effort": .string("ultra"),
                "prompt": .string(""), "cwd": .string("/w/x"),
            ])
        #expect(
            text == """
                会話を起動した
                - conversation_id: \(conversationA)
                - タスク: #1 題1
                - モデル: Codex・gpt-6.1-sol・ultra
                - 作業ディレクトリ: /w
                - 次の操作: 指示は session_prompt の conversation_id、状態は session_list
                """)
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations").map { try $0.decode(ConversationStartRequest.self) }
        #expect(sent == [ConversationStartRequest(cwd: "/w/x", taskNumber: 1, model: "gpt-6.1-sol", effort: "ultra", engine: .codex)])
        for args: [String: Value] in [
            ["task_id": .int(1), "kind": .string("codex"), "disallowed_tools": .array([.string("Agent")]), "cwd": .string("/w")],
            ["task_id": .int(1), "kind": .string("codex"), "model": .string("gpt 6"), "cwd": .string("/w")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_start", args) }
        }
        #expect(RecordingDaemon.writes(host).count == 1)
    }

    @Test("session_start を host の会話の中で呼ぶと、その会話を委譲元にしてターンの終わりを知らせる。オーケストレーターの会話からは notify を渡したときだけ")
    func startNotifiesParent() async throws {
        for (fromOrchestrator, notify, expected) in [(false, nil as Bool?, true), (true, nil, false), (true, true, true), (false, false, false)] {
            var snap = with([conversation(conversationB, phase: .running)])
            if fromOrchestrator { snap.orchestrator = OrchestratorInfo(enabled: true, conversationID: conversationB) }
            var world = RecordingDaemon.World(snapshot: snap)
            world.routes["POST /v1/conversations"] = ok(conversation(conversationA, phase: .idle))
            let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationB, "CLAUDE_CODE_SESSION_ID": "s-02"])
            var args: [String: Value] = ["task_id": .int(1), "cwd": .string("/w")]
            if let notify { args["notify"] = .bool(notify) }
            let text = try await tools.call("session_start", args)
            let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/conversations").first).decode(ConversationStartRequest.self)
            #expect(sent.notifyParent == (expected ? true : nil))
            #expect(sent.parent == (expected ? ConversationParent(conversationID: conversationB, agentSessionID: "s-02") : nil))
            #expect(text.contains("- 通知: ターンの終了と回答待ちを、taskboard がこのセッションに送る（人の発言でも承認でもない）") == expected)
        }
    }

    @Test("session_start で自分のタスクでないタスクのセッションを起こすと、委譲先にしない（委譲元を付けず、知らせない）。notify を渡せば会話は知らせる")
    func startForAnotherTask() async throws {
        let environment = ["TASKBOARD_CONVERSATION_ID": conversationB, "CLAUDE_CODE_SESSION_ID": "s-02"]
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationB, phase: .running)], snapshot(tasks: [task(1), task(2)])))
        world.routes["GET /v1/resolve"] = ok(TaskResolution(task: task(1), method: "existing"))
        world.routes["POST /v1/conversations"] = ok(conversation(conversationA, phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world, environment: environment)
        for (number, notify) in [(2, nil as Bool?), (2, true), (1, nil)] {
            var args: [String: Value] = ["task_id": .int(number), "cwd": .string("/w")]
            if let notify { args["notify"] = .bool(notify) }
            _ = try await tools.call("session_start", args)
        }
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations").map { try $0.decode(ConversationStartRequest.self) }
        #expect(sent.map(\.notifyParent) == [nil, true, true])
        #expect(sent.map { $0.parent != nil } == [false, true, true])
    }

    @Test("session_control は model・effort・permission_mode を替え、interrupt で生成を停止する。止まっている会話は次に起こしたときに効くと書く。自分の生成は停止しない")
    func control() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .stopped)]))
        world.routes["POST /v1/conversations/\(conversationB)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call(
            "session_control",
            ["conversation_id": .string(conversationB), "model": .string("sonnet"), "effort": .string("high"), "permission_mode": .string("plan")])
        #expect(text == "会話を操作した\n- conversation_id: \(conversationB)\n- 内容: model を sonnet に、effort を high に、permission_mode を plan に\n- 注意: 止まっている会話なので、次の再開から効く")
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").map { try $0.decode(ConversationControlRequest.self) }
        #expect(
            sent == [
                ConversationControlRequest(kind: .setModel, value: "claude-sonnet-5"), ConversationControlRequest(kind: .setEffort, value: "high"),
                ConversationControlRequest(kind: .setPermissionMode, value: "plan"),
            ])
        for args: [String: Value] in [
            ["conversation_id": .string(conversationA), "interrupt": .bool(true)],
            ["conversation_id": .string(conversationB)],
            ["conversation_id": .string(conversationB), "model": .string("gpt")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_control", args) }
        }
        #expect(RecordingDaemon.writes(host).count == 3)
    }

    @Test("session_control の notify は、起こした後の会話の通知を入れるか停止するかを送る")
    func controlNotify() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running), conversation(conversationB, phase: .running)]))
        world.routes["POST /v1/conversations/\(conversationB)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("session_control", ["conversation_id": .string(conversationB), "notify": .bool(false)])
        #expect(text == "会話を操作した\n- conversation_id: \(conversationB)\n- 内容: 通知を停止した")
        _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "notify": .bool(true)])
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").map { try $0.decode(ConversationControlRequest.self) }
        #expect(sent == [ConversationControlRequest(kind: .setNotifyParent, value: "off"), ConversationControlRequest(kind: .setNotifyParent, value: "on")])
    }

    @Test("session_control の codex の会話のモデルと effort は、起動と同じく名前の形だけを見る（Claude の一覧で確認しない）")
    func codexSettings() async throws {
        var codex = conversation(conversationB, phase: .stopped)
        codex.engine = .codex
        var world = RecordingDaemon.World(snapshot: with([codex]))
        world.routes["POST /v1/conversations/\(conversationB)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string("gpt-6-astra"), "effort": .string("ultra")])
        for key in ["model", "effort"] {
            for value in ["ex tra", "gpt/6"] {
                await #expect(throws: TaskboardTools.ToolError.self) {
                    try await tools.call("session_control", ["conversation_id": .string(conversationB), key: .string(value)])
                }
            }
        }
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").map { try $0.decode(ConversationControlRequest.self) }
        #expect(sent == [ConversationControlRequest(kind: .setModel, value: "gpt-6-astra"), ConversationControlRequest(kind: .setEffort, value: "ultra")])
    }

    @Test("model はマシンの Claude Code の一覧（GET /v1/claude）で確認、--model に渡す名前にそろえる。一覧に無い名前は、選べる名前を並べて送らずに断る")
    func listedModels() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationB, phase: .stopped)]))
        world.routes["GET /v1/claude"] = ok(
            ClaudeMachineInfo(models: [
                .init(value: "opus", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus 5.5", efforts: ["low"]),
                .init(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5", efforts: ["low"]),
                .init(value: "claude-opus-4-8", resolvedModel: "claude-opus-4-8", displayName: "Opus 4.8", efforts: ["low"]),
            ]))
        world.routes["POST /v1/conversations/\(conversationB)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        world.routes["GET /v1/settings"] = ok(MachineSettings.defaults)
        world.routes["PATCH /v1/settings"] = ok(MachineSettings.defaults)
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string("sonnet")])
        _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string("claude-opus-4-8")])
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").map { try $0.decode(ConversationControlRequest.self).value }
        #expect(sent == ["claude-sonnet-5-5", "claude-opus-4-8"])
        do {
            _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string("fable")])
            Issue.record("断らなかった")
        } catch let error as TaskboardTools.ToolError {
            #expect("\(error)".contains("使える値: opus, sonnet, claude-opus-4-8"))
        }
        _ = try await tools.call("settings_update", ["orchestrator_model": .string("sonnet")])
        let settings = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/settings").first).decode(MachineSettingsUpdate.self)
        #expect(settings.orchestratorAgentArgs?.contains("claude-sonnet-5-5") == true)
        #expect(try await tools.call("settings_get", [:]).contains("Opus 5.5"))
        #expect(RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").count == 2)
    }

    @Test("GET /v1/claude の無い古い daemon には、前の版が受け付けた名前（控えの一覧）で確認して送る")
    func olderDaemonWithoutModelList() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationB, phase: .stopped)]))
        world.routes["POST /v1/conversations/\(conversationB)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world)
        for model in ["opus", "sonnet", "fable", "haiku", "claude-sonnet-5-5"] {
            _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string(model)])
        }
        let sent = try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationB)/control").map { try $0.decode(ConversationControlRequest.self).value }
        #expect(sent == ["claude-opus-5-5[1m]", "claude-sonnet-5", "claude-fable-5-1[1m]", "claude-haiku-5-5", "claude-sonnet-5-5"])
        do {
            _ = try await tools.call("session_control", ["conversation_id": .string(conversationB), "model": .string("claude-opus-4-8")])
            Issue.record("断らなかった")
        } catch let error as TaskboardTools.ToolError {
            #expect("\(error)".contains("使える値: opus, sonnet, fable, haiku, claude-sonnet-5-5"))
        }
        #expect(!RecordingDaemon.requests(host, "GET", "/v1/claude").isEmpty)
    }

    @Test("session_history の conversation_id は直近の発言を古い順に、文は 2,000 字まで、tool は名前だけ、思考は印を付けて 1 行目だけで返す")
    func conversationHistory() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .idle)]))
        world.routes["GET /v1/conversations/\(conversationA)/history"] = ok(
            ConversationHistoryResponse(
                messages: [
                    ChatMessage(id: "1", role: .user, kind: .text, text: "調べて"),
                    ChatMessage(id: "2", role: .assistant, kind: .toolUse, text: "ls -la", toolName: "Bash", toolID: "toolu_1"),
                    ChatMessage(id: "3", role: .user, kind: .toolResult, text: "秘密の出力", toolID: "toolu_1", isError: true),
                    ChatMessage(id: "4", role: .assistant, kind: .notice, text: "画像"),
                    ChatMessage(id: "6", role: .assistant, kind: .text, text: "長さを見る\n2 行目", thinking: true),
                    ChatMessage(id: "5", role: .assistant, kind: .text, text: String(repeating: "あ", count: 2001)),
                ], nextCursor: nil, agentSessionID: "s-01"))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("session_history", ["conversation_id": .string(conversationA), "limit": .int(5)])
        #expect(
            text == "会話 \(conversationA) の直近の発言 6 件（古い順）\n- user: 調べて\n- assistant: tool Bash を呼んだ\n- tool Bash の結果（error）\n- assistant の思考: 長さを見る\n- assistant: "
                + String(repeating: "あ", count: 2000) + "…")
        #expect(RecordingDaemon.requests(host, "GET", "/v1/conversations/\(conversationA)/history").first?.query == [URLQueryItem(name: "limit", value: "5")])
    }

    @Test("session_rename の conversation_id は会話に名前を付け、空なら外して自動の題に戻す。改行は断る")
    func conversationRename() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .idle)]))
        world.routes["POST /v1/conversations/\(conversationA)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world)
        #expect(try await tools.call("session_rename", ["conversation_id": .string(conversationA), "label": .string(" 実装 ")]) == "会話に名前を付けた\n- conversation_id: \(conversationA)\n- 名前: 実装")
        #expect(
            try await tools.call("session_rename", ["conversation_id": .string(conversationA), "label": .string(" ")])
                == "会話の名前を外した（自動の題に戻る）\n- conversation_id: \(conversationA)")
        #expect(
            try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/control").map { try $0.decode(ConversationControlRequest.self) }
                == [ConversationControlRequest(kind: .rename, value: "実装"), ConversationControlRequest(kind: .rename, value: nil)])
        for args: [String: Value] in [
            ["conversation_id": .string(conversationA), "label": .string("a\nb")],
        ] {
            await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("session_rename", args) }
        }
        #expect(RecordingDaemon.writes(host).count == 2)
    }

    @Test("session_stop は止まっている会話でも、利用枠の上限の後に続きを送る予定なら取り消す（stop は呼ばない。タスクの無い会話の記録を削除するため）")
    func stopCancelsLimitWait() async throws {
        var waiting = conversation(conversationA, phase: .stopped, task: nil)
        waiting.limitResumeAt = t0.addingTimeInterval(3600)
        var world = RecordingDaemon.World(snapshot: with([waiting, conversation(conversationB, phase: .stopped)]))
        world.routes["POST /v1/conversations/\(conversationA)/control"] = ok(ConversationControlResponse(payloadJSON: nil))
        let (tools, host) = RecordingDaemon.tools(world)
        #expect(try await tools.call("session_stop", ["conversation_id": .string(conversationA)]) == "利用枠の上限の後に送る続きを取り消した\n- conversation_id: \(conversationA)\n- 状態: 会話は止まっている")
        #expect(try await tools.call("session_stop", ["conversation_id": .string(conversationB)]) == "会話 \(conversationB) は止まっている")
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/conversations/\(conversationA)/control"])
        #expect(
            try RecordingDaemon.requests(host, "POST", "/v1/conversations/\(conversationA)/control").first?.decode(ConversationControlRequest.self)
                == ConversationControlRequest(kind: .cancelLimitResume))
    }

    @Test("health は会話の host の様子と、問いを待っている会話を出す。入れ替えを待っている間は残っている会話を並べる")
    func health() {
        let snap = with(
            [conversation(conversationA, phase: .waiting, requests: [permission("r2")], title: "実装"), conversation(conversationB, phase: .idle)],
            agentHost: AgentHostInfo(connected: true))
        let text = TaskboardTools.healthReport(snapshot: snap, apnsConfigured: true, now: t0)
        #expect(text.contains("- 会話の host: 繋がっている。動いている会話 2（idle 1 / waiting 1）"))
        #expect(text.contains("## 回答待ちの会話 1\n- 会話 6f1d2b8e 「実装」 → #1 題1: 権限の確認 Bash（session_answer で答える）"))

        let draining = with(
            [conversation(conversationA, phase: .idle, title: "実装")],
            agentHost: AgentHostInfo(connected: false, draining: true, remaining: [conversationA, "0000aaaa-2c4a-4a8f-9c11-5d7e0a3b9f09"]))
        #expect(
            TaskboardTools.healthReport(snapshot: draining, apnsConfigured: true, now: t0).contains(
                "- 会話の host: 更新待ち（会話を起動できない）。動いている会話 2 件が終わるか止まると更新される: 6f1d2b8e「実装」、0000aaaa（session_stop の conversation_id で停止する）"))
        #expect(!TaskboardTools.healthReport(snapshot: snapshot(), apnsConfigured: true, now: t0).contains("会話の host"), "古い daemon は出さない")
    }
}

// MARK: - 起こす予定

@Suite("taskboard mcp: 起こす予定")
struct MCPWakeTests {
    private func created(_ request: WakeCreateRequest, id: Int64 = 3) -> (Int, Data) {
        ok(
            Wake(
                wakeID: id, machine: machine, at: request.at, prompt: request.prompt, conversationID: request.conversationID, taskNumber: request.taskNumber,
                closesCreator: request.closeConversationID != nil, createdBy: request.createdBy, createdAt: t0, updatedAt: t0))
    }

    @Test("host の会話の中の wake_create は、省くとこの会話に届け、close でこの会話をターンの後に終了する")
    func createInConversation() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        let at = t0.addingTimeInterval(3 * 24 * 3600)
        world.routes["POST /v1/wakes"] = created(WakeCreateRequest(at: at, prompt: "デプロイを確認する", conversationID: conversationA, closeConversationID: conversationA))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("wake_create", ["at": .string("2027-01-18T17:00:00+09:00"), "prompt": .string("デプロイを確認する"), "close": .bool(true)])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/wakes").first).decode(WakeCreateRequest.self)
        #expect(sent.conversationID == conversationA && sent.taskNumber == nil && sent.closeConversationID == conversationA && sent.createdBy == conversationA)
        #expect(sent.at == ISO8601DateFormatter().date(from: "2027-01-18T08:00:00Z"))
        #expect(sent.cwd == "/w")
        #expect(text.hasPrefix("予定を作った\n- id: 3\n- 状態: pending\n- 時刻: \(Wake.agentTime(at))\n- 届け先: 会話 \(conversationA.prefix(8))「実装」（この会話）\n- 指示: デプロイを確認する\n- 終了: 作成した会話をターンの後に終了する"))
    }

    @Test("会話の外の wake_create は、このセッションのタスクの lead に届ける。close は会話の外では断る。task_id と conversation_id は一緒に渡せない")
    func createOutsideConversation() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-self"])]))
        world.routes["GET /v1/resolve"] = ok(TaskResolution(task: task(1, sessions: ["s-self"]), method: "existing"))
        world.routes["POST /v1/wakes"] = created(WakeCreateRequest(at: t0.addingTimeInterval(3600), prompt: "p", taskNumber: 1))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("wake_create", ["at": .string("2030-01-01T09:00"), "prompt": .string("p")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/wakes").first).decode(WakeCreateRequest.self)
        #expect(sent.taskNumber == 1 && sent.conversationID == nil && sent.closeConversationID == nil && sent.createdBy == "s-self")

        await #expect(throws: (any Error).self) { try await tools.call("wake_create", ["at": .string("2030-01-01T09:00"), "prompt": .string("p"), "close": .bool(true)]) }
        await #expect(throws: (any Error).self) {
            try await tools.call("wake_create", ["at": .string("2030-01-01T09:00"), "prompt": .string("p"), "task_id": .int(1), "conversation_id": .string(conversationA)])
        }
        await #expect(throws: (any Error).self) { try await tools.call("wake_create", ["at": .string("あした"), "prompt": .string("p")]) }
        #expect(RecordingDaemon.requests(host, "POST", "/v1/wakes").count == 1)
    }

    @Test("wake_list は既定でこの会話とこのタスク宛ての待っている予定だけ、all で全部。wake_cancel は id の予定を取り消す")
    func listAndCancel() async throws {
        let wakes = [
            Wake(wakeID: 1, machine: machine, at: t0, prompt: "自分\n2 行目", conversationID: conversationA, createdAt: t0, updatedAt: t0),
            Wake(wakeID: 2, machine: machine, at: t0, prompt: "タスク", taskNumber: 1, createdAt: t0, updatedAt: t0),
            Wake(wakeID: 3, machine: machine, at: t0, prompt: "ほか", taskNumber: 2, createdAt: t0, updatedAt: t0),
            Wake(wakeID: 4, machine: machine, at: t0, prompt: "済み", conversationID: conversationA, state: .failed, failure: "会話が無い", createdAt: t0, updatedAt: t0),
        ]
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .idle, title: "実装")], snapshot(tasks: [task(1), task(2)])))
        world.routes["GET /v1/wakes"] = ok(wakes)
        world.routes["POST /v1/wakes/2/cancel"] = ok(Wake(wakeID: 2, machine: machine, at: t0, prompt: "タスク", taskNumber: 1, state: .cancelled, createdAt: t0, updatedAt: t0))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let own = try await tools.call("wake_list", [:])
        #expect(own.contains("[1] pending") && own.contains("[2] pending") && !own.contains("[3]") && !own.contains("[4]"))
        #expect(own.contains("  - 指示: 自分\n") && own.hasPrefix("予定 2 件\n- [1] pending"))
        let all = try await tools.call("wake_list", ["all": .bool(true)])
        #expect(all.contains("[3] pending") && all.contains("[4] failed") && all.contains("  - 失敗: 会話が無い"))
        let cancelled = try await tools.call("wake_cancel", ["id": .string("2")])
        #expect(cancelled.hasPrefix("予定を取り消した\n- id: 2\n- 状態: cancelled"))
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/wakes/2/cancel"])
    }

    @Test("at はオフセットつきの ISO 8601 と、オフセットを省いたこのマシンの時刻（秒は省いてよい）を読む")
    func parsesTime() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let expected = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")
        #expect(TaskboardTools.wakeTime("2026-10-25T09:00:00+09:00") == expected)
        #expect(TaskboardTools.wakeTime("2026-10-25T00:00:00.000Z") == expected)
        #expect(TaskboardTools.wakeTime("2026-10-25T09:00", timeZone: tokyo) == expected)
        #expect(TaskboardTools.wakeTime("2026-10-25 09:00:00", timeZone: tokyo) == expected)
        #expect(TaskboardTools.wakeTime("10/25 9:00") == nil)
        #expect(TaskboardTools.wakeTime("") == nil)
    }
}

// MARK: - 見張り

@Suite("taskboard mcp: 見張り")
struct MCPWatchTests {
    private let url = "https://github.com/o/r/pull/12"

    @Test("host の会話の中の watch_create は、省くとこの会話に届け、作ったときの様子を返す。知らない種類と読めない期限は断る")
    func createInConversation() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        let watch = Watch(
            watchID: 5, machine: machine, url: url, events: [.merged, .checksFailed], conversationID: conversationA, prompt: "デプロイを確認する", once: true,
            fetchedAt: t0, createdBy: conversationA, createdAt: t0, updatedAt: t0)
        let snapshot = LinkSnapshot.pullRequest(PullRequestSnapshot(state: .open, isDraft: true, checks: .pending, mergeable: .conflicting))
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: watch, snapshot: snapshot))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call(
            "watch_create",
            ["url": .string(url), "events": .array([.string("merged"), .string("checks_failed")]), "prompt": .string("デプロイを確認する"), "once": .bool(true)])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/watches").first).decode(WatchCreateRequest.self)
        #expect(sent.url == url && sent.events == [.merged, .checksFailed] && sent.once && sent.prompt == "デプロイを確認する")
        #expect(sent.conversationID == conversationA && sent.taskNumber == nil && sent.createdBy == conversationA)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(
            Array(lines.prefix(10)) == [
                "監視を作った", "- id: 5", "- 状態: active", "- 対象: \(url)", "- 届け先: 会話 \(conversationA.prefix(8))「実装」（この会話）", "- 通知する動き: merged・checks_failed",
                "- 条件: 1 回だけ", "- 最後の取得: \(Wake.agentTime(t0))", "- 指示: デプロイを確認する", "- 基準: open（draft）・CI 実行中・conflict あり（これより後の動きを通知する）",
            ])

        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "events": .array([.string("pushed")])]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "expires_at": .string("あした")]) }
        await #expect(throws: (any Error).self) {
            try await tools.call("watch_create", ["url": .string(url), "task_id": .int(1), "conversation_id": .string(conversationA)])
        }
        #expect(RecordingDaemon.requests(host, "POST", "/v1/watches").count == 1)
    }

    @Test("command の watch_create は条件と間隔を送り、コマンドと条件を返す。url との同時指定、condition の抜け、知らない条件、command の無い condition は断る")
    func createCommandWatch() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        let spec = CommandWatchSpec(command: "curl -fsS localhost:8080/health\necho", cwd: "/tmp", condition: .succeeds, intervalSeconds: 30)
        let watch = Watch(watchID: 6, machine: machine, kind: .command, command: spec, conversationID: conversationA, createdBy: conversationA, createdAt: t0, updatedAt: t0)
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: watch, snapshot: nil))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call(
            "watch_create",
            ["command": .string(spec.command), "condition": .string("succeeds"), "interval_seconds": .int(30), "cwd": .string("/tmp")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/watches").first).decode(WatchCreateRequest.self)
        #expect(sent.command == spec && sent.url == nil && sent.conversationID == conversationA)
        #expect(
            text.split(separator: "\n").map(String.init) == [
                "監視を作った", "- id: 6", "- 状態: active", "- 対象: コマンド `curl -fsS localhost:8080/health`", "- 届け先: 会話 \(conversationA.prefix(8))「実装」（この会話）",
                "- 通知の条件: succeeds", "- 間隔: 30 秒", "- 打ち切り: 60 秒", "- 作業フォルダ: /tmp", "- 最後に回した: まだ回していない",
                "- 基準: 1 回目で条件に合えば通知する（その後は、合わない回をはさんで合ったときに通知する）", "- 次の操作: 取り消しは watch_cancel の id",
            ])

        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "command": .string("ls"), "condition": .string("succeeds")]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["command": .string("ls")]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["command": .string("ls"), "condition": .string("exits")]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "condition": .string("succeeds")]) }
        #expect(RecordingDaemon.requests(host, "POST", "/v1/watches").count == 1)
    }

    @Test("リンクの通知で届く PR の監視を daemon が作らなかったら、そう返し、指示を残したことと監視が必要場合を添える")
    func watchCoveredByLink() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: nil, snapshot: nil, link: .linked(task: 4)))
        let (tools, _) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("watch_create", ["url": .string(url), "prompt": .string("マージされたら片付ける")])
        #expect(
            text.split(separator: "\n").map(String.init) == [
                "監視は作らなかった（リンクの通知で届く）",
                "- 理由: PR はタスク #4 にリンクしてある。マージ・クローズ・CI・レビュー・コメント・conflict は、taskboard がそのタスクの lead に自動で通知する",
                "- リンク: PR をタスク #4 にリンクした（PR の状態で列が進む）",
                "- 指示: リンクのメモに残した（通知の「作成時の指示:」に載る）",
                "- 監視が必要なとき: 決めた動きだけを待つ（events）・タグ（tag_pattern）・1 回だけ（once）・期限（expires_at）なら監視を作る",
            ])
    }

    @Test("会話の外の watch_create は、このセッションのタスクに届ける。同じ見張りがあればそう返し、様子が取れていなければ理由を返す")
    func createOutsideConversation() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-self"])]))
        world.routes["GET /v1/resolve"] = ok(TaskResolution(task: task(1, sessions: ["s-self"]), method: "existing"))
        let watch = Watch(watchID: 6, machine: machine, url: url, taskNumber: 1, error: "not found", createdAt: t0, updatedAt: t0)
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: watch, snapshot: nil, existing: true))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("watch_create", ["url": .string(url), "expires_at": .string("2030-01-01T09:00")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/watches").first).decode(WatchCreateRequest.self)
        #expect(sent.taskNumber == 1 && sent.conversationID == nil && sent.createdBy == "s-self" && sent.expiresAt != nil && sent.events.isEmpty)
        #expect(text.hasPrefix("同じ監視が既にある\n- id: 6\n- 状態: active\n- 対象: \(url)\n- 届け先: #1 の lead"))
        #expect(text.contains("- 基準: 今の状態を取得できなかった（not found）。取得できた回を基準にする"))
    }

    @Test("watch_create の repo は検索語と一緒に送り、取れていれば今あるものを見たと返す。url と repo の両方・どちらも無い、repo で選べない opened は断る")
    func createRepoWatch() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        let watch = Watch(
            watchID: 7, machine: machine, kind: .repo, repo: "o/r", query: "is:issue label:bug", conversationID: conversationA, fetchedAt: t0, createdAt: t0,
            updatedAt: t0)
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: watch, snapshot: nil))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("watch_create", ["repo": .string("o/r"), "query": .string("is:issue label:bug")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/watches").first).decode(WatchCreateRequest.self)
        #expect(sent.url == nil && sent.repo == "o/r" && sent.query == "is:issue label:bug" && sent.conversationID == conversationA)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.contains("- 対象: o/r の新しい issue・PR") && lines.contains("- 検索語: is:issue label:bug") && lines.contains("- 最後の取得: \(Wake.agentTime(t0))"))
        #expect(lines.contains("- 基準: 今ある issue・PR を確認した（これより後に出たものを通知する）"))

        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "repo": .string("o/r")]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", [:]) }
        await #expect(throws: (any Error).self) { try await tools.call("watch_create", ["url": .string(url), "events": .array([.string("opened")])]) }
        #expect(RecordingDaemon.requests(host, "POST", "/v1/watches").count == 1)
    }

    @Test("watch_create の tag_pattern は events と一緒に送り、作る前からタグに入っていたらそう返す。一覧は型と入ったタグを添える")
    func createTagWatch() async throws {
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .running, title: "実装")]))
        let ended = Watch(
            watchID: 8, machine: machine, url: url, events: [.tagged], tagPattern: "*-prod", tag: "v2-20261015-01-prod", conversationID: conversationA,
            state: .ended, ending: .finished, fetchedAt: t0, createdAt: t0, updatedAt: t0)
        let merged = LinkSnapshot.pullRequest(PullRequestSnapshot(state: .merged, mergeCommit: "m1"))
        world.routes["POST /v1/watches"] = ok(WatchCreated(watch: ended, snapshot: merged))
        world.routes["GET /v1/watches"] = ok([
            Watch(watchID: 9, machine: machine, url: url, tagPattern: "*-prod", conversationID: conversationA, createdAt: t0, updatedAt: t0), ended,
        ])
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let text = try await tools.call("watch_create", ["url": .string(url), "events": .array([.string("tagged")]), "tag_pattern": .string("*-prod")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/watches").first).decode(WatchCreateRequest.self)
        #expect(sent.events == [.tagged] && sent.tagPattern == "*-prod")
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(3) == ["監視を作った", "- id: 8", "- 状態: ended（finished）"])
        #expect(lines.contains("- 通知する動き: tagged") && lines.contains("- タグの型: *-prod") && lines.contains("- 入ったタグ: v2-20261015-01-prod"))
        #expect(lines.contains("- 結果: もうタグ v2-20261015-01-prod に含まれている（作る前からの状態なので、通知せずに終えた）"))
        #expect(!text.contains("基準"))
        let list = try await tools.call("watch_list", [:])
        #expect(list.contains("- [9] active \(url) → 会話 ") && list.contains("  - タグの型: *-prod"), "\(list)")
    }

    @Test("watch_list は既定でこの会話とこのタスク宛ての有効な見張りだけ、all で全部。watch_cancel は id の見張りを取り消す")
    func listAndCancel() async throws {
        let watches = [
            Watch(watchID: 1, machine: machine, url: url, conversationID: conversationA, prompt: "自分\n2 行目", createdAt: t0, updatedAt: t0),
            Watch(watchID: 2, machine: machine, url: url, taskNumber: 1, createdAt: t0, updatedAt: t0),
            Watch(watchID: 3, machine: machine, url: url, taskNumber: 2, createdAt: t0, updatedAt: t0),
            Watch(watchID: 4, machine: machine, url: url, conversationID: conversationA, state: .ended, ending: .finished, createdAt: t0, updatedAt: t0),
        ]
        var world = RecordingDaemon.World(snapshot: with([conversation(conversationA, phase: .idle, title: "実装")], snapshot(tasks: [task(1), task(2)])))
        world.routes["GET /v1/watches"] = ok(watches)
        world.routes["POST /v1/watches/2/cancel"] = ok(Watch(watchID: 2, machine: machine, url: url, taskNumber: 1, state: .cancelled, createdAt: t0, updatedAt: t0))
        let (tools, host) = RecordingDaemon.tools(world, environment: ["TASKBOARD_CONVERSATION_ID": conversationA])
        let own = try await tools.call("watch_list", [:])
        #expect(own.contains("[1] active") && own.contains("[2] active") && !own.contains("[3]") && !own.contains("[4]"), "\(own)")
        #expect(own.contains("最後の取得: まだ取得できていない") && own.contains("\n  - 指示: 自分") && own.hasPrefix("監視 2 件\n- [1] active"))
        let all = try await tools.call("watch_list", ["all": .bool(true)])
        #expect(all.contains("[3] active") && all.contains("[4] ended（finished）"))
        let cancelled = try await tools.call("watch_cancel", ["id": .string("2")])
        #expect(cancelled.hasPrefix("監視を取り消した\n- id: 2\n- 状態: cancelled"))
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/watches/2/cancel"])
    }
}
