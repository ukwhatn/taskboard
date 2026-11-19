import Foundation
import MCP
import TaskboardKit
import Testing

@testable import taskboard

/// tool が返す結果の文の形（1 行目に何が起きたか、2 行目から `- 項目: 値`）
@Suite("taskboard mcp: 結果の文の形")
struct MCPResultTextTests {
    private func workItem(_ id: Int64, state: WorkItem.State = .todo) -> WorkItem {
        WorkItem(machine: machine, itemID: id, taskNumber: 1, title: "設計", state: state, position: 0, source: "session", createdAt: t0, updatedAt: t0)
    }

    private let doc = Document(machine: machine, docID: 5, taskNumber: 1, name: "plan.md", format: .markdown, latestRev: 2, createdAt: t0, updatedAt: t0)

    @Test("work_add と work_update は、何をしたかの 1 行と、作業項目・状態の項目を返す。断りは 1 文目に何ができないか、続けて直し方")
    func workResults() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/tasks/1/work"] = ok(workItem(3))
        world.routes["PATCH /v1/work/3"] = ok(workItem(3, state: .doing))
        let (tools, _) = RecordingDaemon.tools(world)
        #expect(try await tools.call("work_add", ["task_id": .int(1), "title": .string("設計")]) == "作業項目を追加した\n- 作業項目: [3] 設計\n- 状態: todo\n- タスク: #1")
        #expect(try await tools.call("work_update", ["id": .int(3), "state": .string("doing")]) == "作業項目を更新した\n- 作業項目: [3] 設計\n- 状態: doing")
        do {
            _ = try await tools.call("work_update", ["id": .int(3), "state": .string("wait")])
            Issue.record("待ち理由の無い wait を断らない")
        } catch let error as TaskboardTools.ToolError {
            #expect(error.description == "待ちにする指定に待ち理由が無い。blocker_kind か blocker_text を付ける")
        }
        do {
            _ = try await tools.call("work_update", ["id": .int(3), "state": .string("nope")])
            Issue.record("無い state を断らない")
        } catch let error as TaskboardTools.ToolError {
            #expect(error.description == "state が不正。todo・doing・wait・done・drop のどれかを渡す")
        }
    }

    @Test("doc_publish は文書・タスク・アプリの項目を返し、質問があれば ask_id と回答の届き方、未受領があれば次の操作を追加する")
    func publishResult() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/tasks/1/docs"] = ok(DocPublishResponse(document: doc, revision: 2, isNew: false, askID: 7, pendingFeedback: 1))
        let (tools, _) = RecordingDaemon.tools(world)
        let text = try await tools.call("doc_publish", ["task_id": .int(1), "content": .string("# 計画"), "name": .string("plan.md")])
        #expect(text.hasPrefix("文書を publish した\n- 文書: [5] plan.md ・ rev 2 ・ 更新\n- タスク: #1\n- アプリ: taskboard://task/m1/1/doc/5"))
        #expect(text.contains("\n- ask_id: 7\n- 回答: ブロックしない。taskboard がこのセッションに届ける"))
        #expect(text.hasSuffix("- 次の操作: 未受領のフィードバック 1 件を feedback_list で読む"))
    }

    @Test("doc_list は文書ごとに 1 行、未回答の質問とコメントは 2 段目に下ろす。無いときは 1 行")
    func listResult() async throws {
        let commented = Document(machine: machine, docID: 5, taskNumber: 1, name: "plan.md", format: .markdown, title: "計画", latestRev: 2, openComments: 2, createdAt: t0, updatedAt: t0)
        let ask = Ask(
            machine: machine, askID: 7, taskNumber: 1, docID: 5, status: .open,
            questions: [AskQuestion(id: "q1", question: "どれ", options: [AskOption(label: "A")])], createdAt: t0)
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1), task(2)], documents: [commented]))
        world.routes["GET /v1/tasks/1/docs"] = ok([commented])
        world.routes["GET /v1/tasks/1/asks"] = ok([ask])
        world.routes["GET /v1/tasks/2/docs"] = ok([Document]())
        let (tools, _) = RecordingDaemon.tools(world)
        #expect(
            try await tools.call("doc_list", ["task_id": .int(1)])
                == "タスク #1 の文書は 1 件\n- [5] plan.md「計画」 ・ markdown ・ rev 2\n  - 未回答の質問 1 問（ask_id 7） ・ 未解決コメント 2 件")
        #expect(try await tools.call("doc_list", ["task_id": .int(2)]) == "タスク #2 に文書は無い")
    }

    @Test("ask_user は ask_id・質問数・文書・回答の届き方を項目で返す。既存の文書に付けたときは本文を変えていないことを書く")
    func askResult() async throws {
        let questions: Value = .array([.object(["question": .string("どれ"), "options": .array([.object(["label": .string("A")])])])])
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/tasks/1/docs"] = ok(DocPublishResponse(document: doc, revision: 1, isNew: true, askID: 7, pendingFeedback: 0))
        world.routes["GET /v1/tasks/1/docs"] = ok([doc])
        world.routes["POST /v1/docs/5/asks"] = ok(DocPublishResponse(document: doc, revision: 2, isNew: false, askID: 8, pendingFeedback: 2))
        let (tools, _) = RecordingDaemon.tools(world)
        #expect(
            try await tools.call("ask_user", ["task_id": .int(1), "questions": questions])
                == "質問を作成した\n- ask_id: 7\n- 質問: 1 問\n- 文書: [5] plan.md ・ rev 1\n- タスク: #1\n- アプリ: taskboard://task/\(machine.rawValue)/1/doc/5\n- 回答: ブロックしない。taskboard がこのセッションに届ける。届かなければ feedback_list で取る")
        let attached = try await tools.call("ask_user", ["task_id": .int(1), "questions": questions, "name": .string("plan.md")])
        #expect(attached.contains("- 文書: [5] plan.md ・ rev 2（既存の文書に質問だけ付けた。本文は変えていない）"))
        #expect(attached.hasSuffix("- 次の操作: 先に未受領のフィードバック 2 件を feedback_list で読む"))
        await #expect(throws: TaskboardTools.ToolError.self) {
            try await tools.call("ask_user", ["task_id": .int(1), "questions": questions, "name": .string("plan.md"), "context": .string("背景")])
        }
    }

    @Test("review_request は、依頼した・未受領で依頼しなかったの 2 通りを項目で返す")
    func reviewResult() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot(tasks: [task(1)]))
        world.routes["POST /v1/tasks/1/review-request"] = ok(ReviewRequestResult(status: .requested, pendingFeedback: 0))
        let (tools, _) = RecordingDaemon.tools(world)
        let requested = try await tools.call("review_request", ["task_id": .int(1)])
        #expect(requested.hasPrefix("レビューを依頼した\n- タスク: #1\n- レビュー: ブロックしない。人が送るとこのセッションに届く"))
        #expect(requested.hasSuffix("- 次の操作: 届かなければ feedback_list で確認する"))

        world.routes["POST /v1/tasks/1/review-request"] = ok(ReviewRequestResult(status: .feedbackPending, pendingFeedback: 2))
        let (blocked, _) = RecordingDaemon.tools(world)
        #expect(
            try await blocked.call("review_request", ["task_id": .int(1)])
                == "レビューを依頼していない（未受領のレビューが 2 件ある）\n- 次の操作: feedback_list で読んでから、review_request をもう一度呼び出す")
    }

    @Test("comment_reply は comment_id を項目で返し、resolve のときだけ解決を追加する")
    func replyResult() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["POST /v1/comments/8/reply"] = ok(CommentReply(id: 1, commentID: 8, author: .agent, body: "直した", state: .submitted, createdAt: t0))
        let (tools, _) = RecordingDaemon.tools(world)
        #expect(try await tools.call("comment_reply", ["comment_id": .int(8), "body": .string("直した")]) == "コメントに返信した\n- comment_id: 8")
        #expect(try await tools.call("comment_reply", ["comment_id": .int(8), "body": .string("直した"), "resolve": .bool(true)]) == "コメントに返信した\n- comment_id: 8\n- 解決: した")
    }

    @Test("schedule_list・schedule_run は、件数の見出しと項目で返す。実行しなかったときは理由を項目にする")
    func scheduleResults() async throws {
        var world = RecordingDaemon.World(snapshot: snapshot())
        world.routes["GET /v1/schedules"] = ok([schedule(4)])
        world.routes["POST /v1/schedules/4/run"] = ok(ScheduleRun(id: 12, scheduleID: 4, scheduledAt: t0, trigger: .manual, requestID: "launch-1", createdAt: t0))
        world.routes["POST /v1/schedules/5/run"] = ok(ScheduleRun(id: 13, scheduleID: 5, scheduledAt: t0, trigger: .manual, skipped: "前回が動いている", createdAt: t0))
        let (tools, _) = RecordingDaemon.tools(world)
        let list = try await tools.call("schedule_list", [:])
        #expect(list.hasPrefix("定期起動は 1 件\n- [4] 朝の見回り ・ 有効 ・ "))
        #expect(list.contains("\n  - 実行: claude ・ /w\n  - 常設タスク: #1"))
        #expect(
            try await tools.call("schedule_run", ["id": .int(4)])
                == "定期起動を実行した\n- 実行: 12\n- request_id: launch-1\n- 次の操作: 進み具合は schedule_list か session_list で見る")
        #expect(try await tools.call("schedule_run", ["id": .string("5")]) == "定期起動は実行されなかった\n- 理由: 前回が動いている")
    }

    @Test("board_overview は案件の数の見出しで始まり、進行中のタスクは 1 行目に進捗、2 行目に PR と期日を出す")
    func overviewShape() async throws {
        let pr = TaskLink(id: 11, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0)
        var due = task(1, links: [pr])
        due.due = "2026-10-30"
        let items = [WorkItem(machine: machine, itemID: 3, taskNumber: 1, title: "設計", state: .done, position: 0, source: "session", createdAt: t0, updatedAt: t0)]
        let (tools, _) = RecordingDaemon.tools(.init(snapshot: snapshot(boards: [board("b1", "default")], tasks: [due], workItems: items)))
        let text = try await tools.call("board_overview", [:])
        #expect(text.hasPrefix("案件は 1 件\n## default (b1)\n"))
        #expect(text.contains("- working（作業中）: 1 件 ・ 実装・調査を進めている\n  - #1 題1 ・ 進捗 1 / 1\n    - PR r#1 ・ 期日 2026-10-30"))
    }

    @Test("task_get は 1 行目にタスク、続けて項目。リンクは 1 件 1 行、紐づいた会話があれば次の操作を最後に 1 つ")
    func describeShape() async throws {
        let pr = TaskLink(id: 11, url: "https://github.com/o/r/pull/1", kind: .githubPR, addedAt: t0)
        var state = snapshot(tasks: [task(1, links: [pr])])
        state.conversations = [conversation("c1", phase: .idle)]
        var world = RecordingDaemon.World(snapshot: state)
        world.routes["GET /v1/tasks/1/link-notices"] = ok(LinkNoticeList(undelivered: 0, notices: []))
        let (tools, _) = RecordingDaemon.tools(world)
        let lines = try await tools.call("task_get", ["task_id": .int(1)]).split(separator: "\n").map(String.init)
        #expect(lines.first == "タスク #1 題1")
        #expect(lines.contains("- 案件: default (b1)"))
        #expect(lines.contains("- リンク: https://github.com/o/r/pull/1 ・ github_pr ・ id 11"))
        #expect(lines.contains("- リンクの通知: 未通知 0 件（PR・issue の動きは taskboard がこのタスクの lead に通知する）"))
        #expect(lines.contains("- 次の操作: 会話への指示は session_prompt、再開は session_resume（どちらも conversation_id）"))
        #expect(lines.suffix(2) == ["作業項目は無い", "- 概況: 未登録（panel_set で登録する）"])
    }

    @Test("MCP の instructions と core の tool の説明は常体で、削除する操作の確認（confirm: true）を残す")
    func definitions() {
        let instructions = SessionGuidance.mcpInstructions
        #expect(instructions.contains("confirm: true を付けるまで実行せず") && !instructions.contains("ください") && !instructions.contains("ます。"))
        let owned = TaskboardTools.boardTools + TaskboardTools.documentTools + TaskboardTools.manageTools
        for tool in owned.map(\.definition) {
            let description = tool.description ?? ""
            #expect(!description.contains("ください") && !description.contains("知らせ") && !description.contains("結ん"), "\(tool.name)")
        }
        let deleting = ["board_delete", "task_delete", "work_delete", "doc_delete", "schedule_delete"]
        for tool in owned.map(\.definition) where deleting.contains(tool.name) {
            #expect(String(describing: tool.inputSchema).contains("削除すると取り消せない"), "\(tool.name) の confirm の説明")
        }
    }
}
