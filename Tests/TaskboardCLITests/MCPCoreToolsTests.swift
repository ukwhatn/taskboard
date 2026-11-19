import Foundation
import MCP
import Synchronization
import TaskboardKit
import Testing

@testable import taskboard

// MARK: - 案件・タスク

@Suite("taskboard mcp: 案件とタスクの操作")
struct MCPBoardTaskTests {
    @Test("案件は id・名前・大文字小文字を区別しない名前で引け、無いときと重なるときは候補を返す。省くとアーカイブしていない最初の案件")
    func resolvesBoards() throws {
        let boards = [board("b0", "old", archived: true), board("b1", "default", position: 1), board("b2", "DAS", position: 2), board("b3", "das", position: 3)]
        #expect(try TaskboardTools.board("b2", in: boards).id == "b2")
        #expect(try TaskboardTools.board("default", in: boards).id == "b1")
        #expect(try TaskboardTools.board("DAS", in: boards).id == "b2", "完全に一致する名前を先に採る")
        #expect(try TaskboardTools.board(nil, in: boards).id == "b1", "アーカイブした案件は既定にしない")
        #expect(try TaskboardTools.board("old", in: boards).id == "b0", "名指しならアーカイブした案件も引ける（移す・作るは daemon が断る）")
        #expect(throws: TaskboardTools.ToolError.self) { try TaskboardTools.board("Das", in: boards) }
        do {
            _ = try TaskboardTools.board("HR", in: boards)
            Issue.record("無い案件で投げない")
        } catch let error as TaskboardTools.ToolError {
            #expect(error.description.contains("ある案件: old (b0), default (b1), DAS (b2), das (b3)"))
        }
    }

    @Test("task_create は board の案件の既定の列に起票し、応答に案件を出す")
    func createInBoard() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["POST /v1/tasks"] = ok(task(7, board: "b2", column: "todo"))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("task_create", ["title": .string("移行の調査"), "board": .string("DAS"), "link_session": .bool(false)])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/tasks").first).decode(TaskCreateRequest.self)
        #expect(sent.boardID == "b2" && sent.columnID == "todo" && sent.title == "移行の調査")
        #expect(text == "タスクを起票した\n- タスク: #7 題7\n- 列: todo\n- 案件: DAS (b2)")
    }

    @Test("task_update の board で別の案件へ移し、移した先の案件と列を返す。remove_links は id と URL のどちらでも外す")
    func moveAndRemoveLinks() async throws {
        let links = [TaskLink(id: 11, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0), TaskLink(id: 12, url: "https://x.example/a", kind: .other, addedAt: t0)]
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, links: links)]))
        world.routes["PATCH /v1/tasks/1"] = ok(task(1, board: "b2", column: "working"))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call(
            "task_update", ["task_id": .int(1), "board": .string("b2"), "remove_links": .array([.int(12), .string("https://github.com/o/r/pull/1")])])
        let sent = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/tasks/1").first).decode(TaskUpdateRequest.self)
        #expect(sent.boardID == "b2" && sent.columnID == nil)
        #expect(sent.removeLinkIDs == [12, 11])
        #expect(text.contains("- 移した先の案件: DAS (b2)"))
        #expect(text.contains("- 移した先の列: working（作業中）: 実装・調査を進めている"))
        #expect(text.contains("- 外したリンク: 2 件"))

        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("task_update", ["task_id": .int(1), "remove_links": .array([.int(99)])])
        }
    }

    @Test("同じ案件を board に渡しても boardID は送らない（列はそのまま）")
    func sameBoardIsNoMove() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["PATCH /v1/tasks/1"] = ok(task(1))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("task_update", ["task_id": .int(1), "board": .string("default")])
        #expect(try #require(RecordingDaemon.requests(host, "PATCH", "/v1/tasks/1").first).decode(TaskUpdateRequest.self).boardID == nil)
    }

    @Test("unlink_session はこのセッションを、unlink_sessions は先頭 8 字以上で決まる別のセッションを外す。セッションは停止しない")
    func unlinkSessions() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-self", "abcdef12-3456", "abcdef99-0000"])]))
        world.routes["PATCH /v1/tasks/1"] = ok(task(1, sessions: ["s-self", "abcdef12-3456", "abcdef99-0000"]))
        world.routes["DELETE /v1/tasks/1/sessions/abcdef12-3456"] = ok(task(1, sessions: ["s-self", "abcdef99-0000"]))
        world.routes["DELETE /v1/tasks/1/sessions/s-self"] = ok(task(1, sessions: ["abcdef99-0000"]))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("task_update", ["task_id": .int(1), "unlink_sessions": .array([.string("abcdef12")]), "unlink_session": .bool(true)])
        #expect(RecordingDaemon.requests(host, "DELETE").map(\.path) == ["/v1/tasks/1/sessions/abcdef12-3456", "/v1/tasks/1/sessions/s-self"])
        #expect(text.contains("- 紐づけを外したセッション: abcdef12（セッションは停止していない）"))
        #expect(!RecordingDaemon.writes(host).contains { $0.path.contains("stop") })

        await #expect(throws: TaskboardTools.ToolError.self, "7 字では決めない") {
            try await tools.call("task_update", ["task_id": .int(1), "unlink_sessions": .array([.string("abcdef1")])])
        }
        await #expect(throws: TaskboardTools.ToolError.self, "2 つに合う先頭は断る") {
            try await tools.call("task_update", ["task_id": .int(1), "unlink_sessions": .array([.string("abcdef")])])
        }
    }

    @Test("task_delete は confirm が無ければ削除されるものを返すだけで削除せず、confirm: true で削除する")
    func deleteTask() async throws {
        let items = [WorkItem(machine: machine, itemID: 3, taskNumber: 1, title: "a", state: .todo, position: 0, source: "session", createdAt: t0, updatedAt: t0)]
        let world = RecordingDaemon.World(
            snapshot: with(
                [conversation(conversationA, phase: .running, task: 1)], snapshot(tasks: [task(1, sessions: ["s-self"])], workItems: items, schedules: [schedule(4)])))
        let (tools, host) = RecordingDaemon.tools(world)
        let preview = try await tools.call("task_delete", ["task_id": .int(1)])
        #expect(preview.hasPrefix("まだ削除していない（confirm: true が無い）\n削除されるもの:\n- #1 題1（案件「default」の working）"))
        #expect(preview.contains("作業項目 1 件、文書 0 件、リンク 0 件"))
        #expect(preview.contains("セッションの紐づけ 1 件（今動いている 1 件。セッションは停止しない）"))
        #expect(preview.contains("常設タスクにしている定期起動: [4] 朝の見回り"))
        #expect(preview.contains("このセッションが紐づいているタスク"))
        #expect(preview.hasSuffix("削除すると取り消せない。削除するなら、同じ引数に confirm: true を付けてもう一度呼び出す"))
        #expect(RecordingDaemon.writes(host).isEmpty)

        let done = try await tools.call("task_delete", ["task_id": .int(1), "confirm": .bool(true)])
        #expect(done == "タスクを削除した\n- タスク: #1 題1")
        #expect(RecordingDaemon.writes(host).map { "\($0.method) \($0.path)" } == ["DELETE /v1/tasks/1"])
        await #expect(throws: TaskboardTools.ToolError.missing("task_id"), "このセッションのタスクを暗に削除しない") {
            try await tools.call("task_delete", ["confirm": .bool(true)])
        }
    }

    @Test("board_create は名前で作り、列を返す")
    func createBoard() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["POST /v1/boards"] = ok(board("b9", "HR"))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("board_create", ["name": .string("HR")])
        #expect(try #require(RecordingDaemon.requests(host, "POST", "/v1/boards").first).decode(BoardCreateRequest.self).name == "HR")
        #expect(text.hasPrefix("案件を作った\n- 案件: HR (b9)\n- マージ後の列: deploying\n- 列:\n  - standing（常設）"))
    }

    @Test("列の編集・削除・追加を今の列に当てて、列の全体を作る。「完了」は削除できない")
    func columnEdits() throws {
        let edits = try TaskboardTools.columnEdits(
            board("b1", "default"),
            edit: [.object(["id": .string("planning"), "label": .string("設計"), "description": .string("設計を詰める")])],
            add: [.object(["label": .string("検証"), "after": .string("working")]), .object(["label": .string("保留"), "kind": .string("terminal")])],
            remove: ["review_req"])
        #expect(edits.map { $0.id ?? "+\($0.label)" } == ["standing", "todo", "planning", "working", "+検証", "review", "deploying", "done", "wontfix", "+保留"])
        let planning = try #require(edits.first { $0.id == "planning" })
        #expect(planning.label == "設計" && planning.description == "設計を詰める")
        #expect(edits.first { $0.id == "todo" }?.description == nil, "触らない列の説明は nil（変えない）で送る")
        #expect(edits.last?.collapsed == true, "終端の列は折りたたむ")
        let appended = try TaskboardTools.columnEdits(board("b1", "default"), edit: [], add: [.object(["label": .string("末尾")])], remove: [])
        #expect(appended.map { $0.id ?? "+" }.firstIndex(of: "+") == 7, "after を省くと進行中の列の最後（完了の前）")
        #expect(throws: TaskboardTools.ToolError.self) { try TaskboardTools.columnEdits(board("b1", "default"), edit: [], add: [], remove: ["done"]) }
        #expect(throws: TaskboardTools.ToolError.self) { try TaskboardTools.columnEdits(board("b1", "default"), edit: [], add: [], remove: ["nope"]) }
        var reversed = board("b1", "default")
        reversed.columns.reverse()
        #expect(try TaskboardTools.columnEdits(reversed, edit: [], add: [], remove: []).map(\.id) == BoardColumn.standard.map(\.id), "列は配列の順でなく position の順")
        #expect(TaskboardTools.describe(board: reversed) == TaskboardTools.describe(board: board("b1", "default")))
    }

    @Test("board_update は名前・マージしたら・列と移す先を 1 回の PATCH で送る")
    func updateBoard() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        var updated = board("b2", "DAS 移行")
        updated.mergeTarget = .done
        world.routes["PATCH /v1/boards/b2"] = ok(updated)
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call(
            "board_update",
            ["board": .string("DAS"), "name": .string("DAS 移行"), "merge_target": .string("done"), "remove_columns": .array([.string("deploying")]),
             "reassign": .object(["deploying": .string("done")])])
        let sent = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/boards/b2").first).decode(BoardUpdateRequest.self)
        #expect(sent.name == "DAS 移行" && sent.mergeTarget == .done && sent.reassign == ["deploying": "done"])
        #expect(sent.columns?.contains { $0.id == "deploying" } == false)
        #expect(text.hasPrefix("案件を更新した\n- 案件: DAS 移行 (b2)\n- マージ後の列: done"))
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("board_update", ["board": .string("DAS")]) }
    }

    @Test("board_delete はタスクのある案件を断り、空の案件は confirm: true で削除する")
    func deleteBoard() async throws {
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snapshot(tasks: [task(1, board: "b1")])))
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("board_delete", ["board": .string("default"), "confirm": .bool(true)]) }
        let preview = try await tools.call("board_delete", ["board": .string("DAS")])
        #expect(preview.contains("案件「DAS」(b2)と、その列 9 本"))
        #expect(RecordingDaemon.writes(host).isEmpty)
        _ = try await tools.call("board_delete", ["board": .string("DAS"), "confirm": .bool(true)])
        #expect(RecordingDaemon.writes(host).map { "\($0.method) \($0.path)" } == ["DELETE /v1/boards/b2"])
    }

    @Test("work_list は state を 1 回だけ読み、作業項目と、PR をリンクしたタスクの届けていないリンクの知らせを出す。無いタスクは断る")
    func workListReadsStateOnce() async throws {
        let pr = TaskLink(id: 11, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0)
        let items = [
            WorkItem(machine: machine, itemID: 4, taskNumber: 1, title: "実装", state: .todo, dependsOn: [3], position: 1, source: "session", createdAt: t0, updatedAt: t0),
            WorkItem(machine: machine, itemID: 3, taskNumber: 1, title: "設計", state: .done, position: 0, source: "session", createdAt: t0, updatedAt: t0),
            WorkItem(machine: machine, itemID: 5, taskNumber: 2, title: "別", state: .todo, position: 0, source: "session", createdAt: t0, updatedAt: t0),
        ]
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, links: [pr]), task(2)], workItems: items))
        world.routes["GET /v1/tasks/1/link-notices"] = ok(LinkNoticeList(undelivered: 2, notices: []))
        let (tools, host) = RecordingDaemon.tools(world)
        let text = try await tools.call("work_list", ["task_id": .int(1)])
        #expect(
            text == """
                タスク #1 の作業項目
                - リンクの通知: 未通知 2 件（PR・issue の動きは taskboard がこのタスクの lead に通知する）
                作業項目 1 / 2 完了（着手できる 1、作業中 0、待ち 0）
                - [3] 完了: 設計
                - [4] 着手できる: 実装
                  - depends_on: 3
                """)
        #expect(RecordingDaemon.requests(host, "GET").map(\.path) == ["/v1/state", "/v1/tasks/1/link-notices"])
        await #expect(throws: TaskboardTools.ToolError.invalid("タスク #9 が無い。board_overview で番号を確認する")) { try await tools.call("work_list", ["task_id": .int(9)]) }
    }

    @Test("work_delete は依存している項目を添えて確認、confirm: true で削除する")
    func deleteWork() async throws {
        let items = [
            WorkItem(machine: machine, itemID: 3, taskNumber: 1, title: "設計", state: .done, position: 0, source: "session", createdAt: t0, updatedAt: t0),
            WorkItem(machine: machine, itemID: 4, taskNumber: 1, title: "実装", state: .todo, dependsOn: [3], position: 1, source: "session", createdAt: t0, updatedAt: t0),
        ]
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snapshot(tasks: [task(1)], workItems: items)))
        let preview = try await tools.call("work_delete", ["id": .int(3)])
        #expect(preview.contains("[3] done: 設計（#1 の作業項目。進捗の母数からも外れる）"))
        #expect(preview.contains("これに依存している項目: [4] 実装"))
        #expect(RecordingDaemon.writes(host).isEmpty)
        #expect(try await tools.call("work_delete", ["id": .int(3), "confirm": .bool(true)]) == "作業項目を削除した\n- 作業項目: [3] 設計")
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/work/3"])
    }
}

// MARK: - 文書・質問・定期起動

@Suite("taskboard mcp: 文書・質問・定期起動の操作")
struct MCPDocScheduleTests {
    private let doc = Document(machine: machine, docID: 5, taskNumber: 1, name: "plan.md", format: .markdown, latestRev: 3, openComments: 1, createdAt: t0, updatedAt: t0)

    @Test("doc_read は本文と未解決のコメントを返す")
    func readDocument() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)], documents: [doc]))
        world.routes["GET /v1/docs/5/content"] = ok(DocContent(docID: 5, rev: 3, format: .markdown, content: "# 計画\n本文"))
        world.routes["GET /v1/docs/5/comments"] = ok([
            DocComment(id: 8, docID: 5, docName: "plan.md", rev: 3, body: "ここは別の PR に", state: .open, createdAt: t0),
            DocComment(id: 9, docID: 5, docName: "plan.md", rev: 2, body: "済み", state: .resolved, createdAt: t0),
        ])
        let (tools, _) = RecordingDaemon.tools(world)
        let text = try await tools.call("doc_read", ["doc_id": .int(5)])
        #expect(text.hasPrefix("文書 5 rev 3（markdown）\n\n# 計画\n本文"))
        #expect(text.contains("- [8] rev 3: ここは別の PR に"))
        #expect(!text.contains("済み"))
    }

    @Test("doc_delete は confirm が無ければ削除せず、confirm: true で削除する")
    func deleteDocument() async throws {
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snapshot(tasks: [task(1)], documents: [doc])))
        let preview = try await tools.call("doc_delete", ["doc_id": .int(5)])
        #expect(preview.contains("[5] plan.md（#1、3 リビジョン、未解決コメント 1 件、未回答の質問 0 件）"))
        #expect(RecordingDaemon.writes(host).isEmpty)
        _ = try await tools.call("doc_delete", ["doc_id": .int(5), "confirm": .bool(true)])
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/docs/5"])
    }

    @Test("ask_cancel は回答待ちの質問を取り下げ、回答済みは送らずに断る")
    func cancelAsk() async throws {
        let question = AskQuestion(id: "q1", question: "どちら？", options: [AskOption(label: "A")])
        let asks = [
            Ask(machine: machine, askID: 6, taskNumber: 1, docID: 5, status: .open, questions: [question], createdAt: t0),
            Ask(machine: machine, askID: 7, taskNumber: 1, docID: 5, status: .answered, questions: [question], createdAt: t0),
        ]
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snapshot(tasks: [task(1)], asks: asks)))
        #expect(try await tools.call("ask_cancel", ["ask_id": .int(6)]) == "質問を取り下げた\n- ask_id: 6")
        await #expect(throws: TaskboardTools.ToolError.self) { try await tools.call("ask_cancel", ["ask_id": .int(7)]) }
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/asks/6/cancel"])
    }

    @Test("schedule_delete は confirm が無ければ削除せず、confirm: true で削除する")
    func deleteSchedule() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/schedules"] = ok([schedule(4)])
        let (tools, host) = RecordingDaemon.tools(world)
        let preview = try await tools.call("schedule_delete", ["id": .int(4)])
        #expect(preview.contains("[4] 朝の見回り"))
        #expect(preview.contains("常設タスクは残る"))
        #expect(RecordingDaemon.writes(host).isEmpty)
        _ = try await tools.call("schedule_delete", ["id": .int(4), "confirm": .bool(true)])
        #expect(RecordingDaemon.writes(host).map { "\($0.method) \($0.path)" } == ["DELETE /v1/schedules/4"])
    }

    @Test("schedule_runs は新しい順に、失敗とスキップの理由を出す")
    func scheduleRuns() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/schedules/4/runs"] = ok([
            ScheduleRun(id: 1, scheduleID: 4, scheduledAt: t0, trigger: .schedule, stage: .done, createdAt: t0),
            ScheduleRun(id: 2, scheduleID: 4, scheduledAt: t0.addingTimeInterval(60), trigger: .manual, stage: .failed, error: "作業ディレクトリが無い: /gone", createdAt: t0),
            ScheduleRun(id: 3, scheduleID: 4, scheduledAt: t0.addingTimeInterval(120), trigger: .schedule, skipped: "前回が動いている", createdAt: t0),
        ])
        let (tools, _) = RecordingDaemon.tools(world)
        let lines = try await tools.call("schedule_runs", ["id": .int(4), "limit": .int(2)]).split(separator: "\n").map(String.init)
        #expect(lines[0] == "定期起動 4 の実行は 3 件（新しい順に 2 件）")
        #expect(lines[1].hasPrefix("- 実行 3（定時、") && lines[1].hasSuffix("）: スキップ: 前回が動いている"))
        #expect(lines[2].hasPrefix("- 実行 ") && lines[2].contains("（手動、") && lines[2].hasSuffix("）: 失敗: 作業ディレクトリが無い: /gone"))
        #expect(lines.count == 3)
    }

    @Test("schedule_update は常設タスクを付け替え・新しく作る・外すのどれか 1 つ。new_task は board の案件に作る。agent と引数も変えられる")
    func retargetSchedule() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["PATCH /v1/schedules/4"] = ok(schedule(4, task: 9))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("schedule_update", ["id": .int(4), "new_task": .bool(true), "board": .string("DAS"), "agent_args": .array([.string("--model"), .string("opus")])])
        let sent = try #require(RecordingDaemon.requests(host, "PATCH", "/v1/schedules/4").first).decode(ScheduleUpdateRequest.self)
        #expect(sent.newTask == .init(boardID: "b2", columnID: "todo"))
        #expect(sent.agentArgs == ["--model", "opus"])
        _ = try await tools.call("schedule_update", ["id": .string("4"), "clear_task": .bool(true)])
        #expect(try RecordingDaemon.requests(host, "PATCH", "/v1/schedules/4").last!.decode(ScheduleUpdateRequest.self).clearTask)
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("schedule_update", ["id": .int(4), "task_id": .int(1), "clear_task": .bool(true)])
        }
    }

    @Test("schedule_create の new_task も board の案件に作る")
    func createScheduleInBoard() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["POST /v1/schedules"] = ok(schedule(5, task: 9))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call(
            "schedule_create",
            ["name": .string("朝"), "cron": .string("0 9 * * *"), "cwd": .string("/w"), "prompt": .string("p"), "new_task": .bool(true), "board": .string("b2")])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/schedules").first).decode(ScheduleCreateRequest.self)
        #expect(sent.newTask?.boardID == "b2")
    }
}

// MARK: - タスクのセッションの見分け

@Suite("taskboard mcp: タスクの会話と止まったセッション")
struct MCPTaskSessionsTests {
    private func conversation(_ id: String, sessionID: String, task: Int? = 1, phase: Conversation.Phase = .stopped, parent: String? = nil) -> Conversation {
        Conversation(
            id: id, machine: machine, taskNumber: task, agentSessionID: sessionID, cwd: "/w", runner: phase == .stopped ? .none : .host, phase: phase,
            parentConversationID: parent, createdAt: t0, updatedAt: t0)
    }

    @Test("session_resume は session_id を省くと、今ある会話の Claude の会話 ID を外した止まったセッションのうち、後に結んだものを戻す")
    func resumeSkipsConversations() async throws {
        var state = snapshot(tasks: [task(1, sessions: ["tui-1", "conv-1"])])
        state.conversations = [conversation("c1", sessionID: "conv-1")]
        var world = RecordingDaemon.World(snapshot: state)
        world.routes["POST /v1/tasks/1/sessions/resume"] = ok(SessionResumeResult(conversation: conversation("c2", sessionID: "tui-1", phase: .idle)))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("session_resume", ["task_id": .int(1)])
        let sent = try #require(RecordingDaemon.requests(host, "POST", "/v1/tasks/1/sessions/resume").first)
        #expect(try sent.decode(SessionResumeRequest.self).agentSessionID == "tui-1")
    }

    @Test("session_resume の session_id が今ある会話のものなら、その会話を戻す")
    func resumeConversationBySession() async throws {
        var state = snapshot(tasks: [task(1, sessions: ["conv-1"])])
        state.conversations = [conversation("c1", sessionID: "conv-1")]
        var world = RecordingDaemon.World(snapshot: state)
        world.routes["POST /v1/conversations/c1/resume"] = ok(conversation("c1", sessionID: "conv-1", phase: .idle))
        let (tools, host) = RecordingDaemon.tools(world)
        _ = try await tools.call("session_resume", ["task_id": .int(1), "session_id": .string("conv-1")])
        #expect(RecordingDaemon.writes(host).map(\.path) == ["/v1/conversations/c1/resume"])
    }

    @Test("task_get は、タスクに結ばれた会話（委譲先の印つき）と止まったセッションを分けて出す")
    func taskGetSessions() async throws {
        var state = snapshot(tasks: [task(1, sessions: ["conv-1", "tui-1"])])
        state.conversations = [
            conversation("c1", sessionID: "conv-1", phase: .idle), conversation("c2", sessionID: "conv-2", parent: "c1"),
            conversation("c3", sessionID: "conv-3", task: 2),
        ]
        let (tools, _) = RecordingDaemon.tools(RecordingDaemon.World(snapshot: state))
        let text = try await tools.call("task_get", ["task_id": .int(1)])
        #expect(text.contains("- 会話: c1 ・ idle"))
        #expect(text.contains("- 会話: c2 ・ stopped ・ 委譲先"))
        #expect(!text.contains("c3"))
        #expect(text.contains("- 止まったセッション: tui-1 ・ claude\n  - cwd: /w"))
        #expect(!text.contains("conv-1 claude cwd=/w (herdr に無い)"))
    }
}

// MARK: - このセッション

@Suite("taskboard mcp: このセッションのタスクと会話 ID")
struct MCPOwnSessionTests {
    /// 会話の中の MCP。環境の CLAUDE_CODE_SESSION_ID は起動したときの ID のまま（/clear の後は古い）
    private let inConversation = ["TASKBOARD_CONVERSATION_ID": conversationA, "CLAUDE_CODE_SESSION_ID": "s-stale"]

    @Test("会話の中では、task_id を省くと会話の記録のタスクを使い、daemon に会話 ID で引き直さない")
    func conversationTaskFirst() async throws {
        let snap = with([conversation(conversationA, phase: .running, task: 2)], snapshot(tasks: [task(1, sessions: ["s-stale"]), task(2)]))
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snap), environment: inConversation)
        #expect(try await tools.call("session_guide", [:]).hasPrefix("このセッションは taskboard のタスク #2"))
        #expect(try await tools.call("board_overview", [:]).hasSuffix("このセッションに紐づくタスク: #2 題2（working）"))
        #expect(!RecordingDaemon.requests(host).contains { $0.path == "/v1/resolve" })
    }

    @Test("会話がタスクに結ばれていなければ、環境の ID で別のタスクを拾わずに結び方を案内する")
    func unboundConversation() async throws {
        let snap = with([conversation(conversationA, phase: .running, task: nil)], snapshot(tasks: [task(1, sessions: ["s-stale"])]))
        let (tools, host) = RecordingDaemon.tools(.init(snapshot: snap), environment: inConversation)
        await #expect(throws: TaskboardTools.ToolError.unresolved) { try await tools.call("work_list", [:]) }
        #expect(!RecordingDaemon.requests(host).contains { $0.path == "/v1/resolve" })
    }

    @Test("会話が state に無ければ（前の版の daemon など）、環境の ID で引く")
    func missingConversationFallsBack() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1, sessions: ["s-stale"])]))
        world.routes["GET /v1/resolve"] = ok(TaskResolution(task: task(1, sessions: ["s-stale"]), method: "existing"))
        let (tools, host) = RecordingDaemon.tools(world, environment: inConversation)
        #expect(try await tools.call("session_guide", [:]).hasPrefix("このセッションは taskboard のタスク #1"))
        #expect(RecordingDaemon.requests(host, "GET", "/v1/resolve").first?.query == [URLQueryItem(name: "session", value: "s-stale")])
    }

    @Test("会話の中の unlink_session は、会話の今の Claude の会話 ID の紐づけを外す（環境の古い ID ではない）")
    func unlinkCurrentConversationSession() async throws {
        let snap = with([conversation(conversationA, phase: .running, task: 1)], snapshot(tasks: [task(1, sessions: ["s-stale", "s-01"])]))
        var world = RecordingDaemon.World(snapshot: snap)
        world.routes["PATCH /v1/tasks/1"] = ok(task(1, sessions: ["s-stale", "s-01"]))
        world.routes["DELETE /v1/tasks/1/sessions/s-01"] = ok(task(1, sessions: ["s-stale"]))
        let (tools, host) = RecordingDaemon.tools(world, environment: inConversation)
        let text = try await tools.call("task_update", ["unlink_session": .bool(true)])
        #expect(RecordingDaemon.requests(host, "DELETE").map(\.path) == ["/v1/tasks/1/sessions/s-01"])
        #expect(text.contains("- 紐づけを外したセッション: s-01（セッションは停止していない）"))
    }
}

// MARK: - tool の表

@Suite("taskboard mcp: tool の表")
struct MCPToolTableTests {
    /// Claude Code と codex のセッションが名前で呼ぶので、並びと名前を固定する
    static let names = [
        "board_overview", "task_get", "session_guide", "task_create", "task_update", "work_list", "work_add", "work_update", "schedule_list", "schedule_create",
        "schedule_update", "schedule_run", "session_list", "session_start", "doc_publish", "doc_list", "ask_user", "review_request", "feedback_list",
        "comment_reply", "session_prompt", "session_account", "board_create", "board_update", "board_delete", "task_delete", "work_delete", "doc_read", "doc_delete", "ask_cancel",
        "schedule_delete", "schedule_runs", "health", "session_stop", "session_exit", "session_resume", "session_history", "session_rename",
        "orchestrator_status", "orchestrator_start", "orchestrator_restart", "orchestrator_prompt", "settings_get", "settings_update", "inbox_list",
        "inbox_dismiss", "inbox_restore", "prs_list", "prs_refresh", "usage_get", "usage_history", "session_control", "session_answer", "session_fork", "wake_create",
        "wake_list", "wake_cancel", "watch_create", "watch_list", "watch_cancel", "devin_start", "devin_get", "devin_message", "slack_get", "slack_reply", "panel_set", "panel_update",
    ]

    @Test("一覧に出す tool の名前と並びは変わらず、名前は重ならない")
    func namesAreStable() {
        let listed = TaskboardTools.definitions.map(\.name)
        #expect(listed == Self.names)
        #expect(Set(listed).count == listed.count)
    }

    @Test("一覧に出す tool はどれも処理に届く（知らない tool の誤りにならない）")
    func everyDefinitionDispatches() async {
        let (tools, _) = RecordingDaemon.tools(RecordingDaemon.World(snapshot: snapshot()))
        for name in TaskboardTools.definitions.map(\.name) {
            do {
                _ = try await tools.call(name, [:])
            } catch let error as TaskboardTools.ToolError {
                #expect(error != .unknown(name), "\(name) に処理が無い")
            } catch {}
        }
    }

    @Test("一覧に無い名前は知らない tool の誤りを返す")
    func unknownName() async {
        let (tools, _) = RecordingDaemon.tools(RecordingDaemon.World(snapshot: snapshot()))
        await #expect(throws: TaskboardTools.ToolError.unknown("task_list")) { try await tools.call("task_list", [:]) }
    }
}

@Suite("taskboard mcp: 質問の選択肢の見本と推奨")
struct MCPAskOptionTests {
    @Test("options の preview と recommended を読み、渡さなければ見本なし・推奨なし")
    func readsPreviewAndRecommended() throws {
        let value: Value = .array([
            .object([
                "question": .string("どちらにしますか"),
                "options": .array([
                    .object(["label": .string("A"), "preview": .string("<p>見本</p>"), "recommended": .bool(true)]),
                    .object(["label": .string("B")]),
                ]),
            ])
        ])
        let options = try #require(try TaskboardTools.questions(from: value)?.first?.options)
        #expect(options[0] == AskOption(label: "A", preview: "<p>見本</p>", recommended: true))
        #expect(options[1] == AskOption(label: "B"))
    }
}
