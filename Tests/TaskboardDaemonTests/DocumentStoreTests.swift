import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store: 文書・質問・レビュー・フィードバック")
struct DocumentStoreTests {
    /// 未受領の回答とレビューの数（Stop hook と feedback_list が読む束から数える）
    private func undelivered(_ store: Store, task number: Int) throws -> Int {
        let peek = try store.peekUndeliveredFeedback(task: number)
        return peek.items.count
    }

    private let machine = MachineID(rawValue: "m-test")

    private func makeStore() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "設計"))
        return (store, task)
    }

    private let twoQuestions = [
        AskQuestion(id: "q1", question: "方式はどちらにするか", header: "方式", options: [AskOption(label: "A"), AskOption(label: "B", description: "遅いが堅い")]),
        AskQuestion(id: "q2", question: "期日は守るか", options: [AskOption(label: "守る"), AskOption(label: "ずらす")], multiSelect: true),
    ]

    @Test("同じ名前への publish はリビジョンが増え、title 省略は維持、形式は作成時で固定。本文は rev ごとに取れる")
    func publishRevisions() throws {
        let (store, task) = try makeStore()
        let first = try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .markdown, content: "# v1", title: "計画", sourcePath: "/tmp/plan.md"))
        #expect(first.isNew && first.revision == 1 && first.askID == nil && first.pendingFeedback == 0)
        #expect(first.document.title == "計画" && first.document.hasSourceFile && first.document.latestRev == 1)

        let second = try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .markdown, content: "# v2"))
        #expect(!second.isNew && second.revision == 2 && second.document.docID == first.document.docID)
        #expect(second.document.title == "計画", "title 省略は変えない")
        #expect(!second.document.hasSourceFile, "sourcePath 省略は元ファイル無しに戻す")
        #expect(try store.revisions(doc: first.document.docID).map(\.rev) == [1, 2])
        #expect(try store.content(doc: first.document.docID, rev: 1).content == "# v1")
        #expect(try store.content(doc: first.document.docID, rev: nil).rev == 2)
        #expect(throws: StoreError.revisionNotFound(9)) { try store.content(doc: first.document.docID, rev: 9) }

        #expect(throws: StoreError.docFormatMismatch(name: "plan.md", existing: .markdown)) {
            try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .html, content: "<p>"))
        }
        #expect(throws: StoreError.invalid("文書名にパス区切りは使えない")) {
            try store.publish(task: task.number, DocPublishRequest(name: "a/b.md", format: .markdown, content: ""))
        }
        #expect(throws: StoreError.taskNotFound(404)) { try store.publish(task: 404, DocPublishRequest(name: "x.md", format: .markdown, content: "")) }
        #expect(try store.documents(task: task.number).count == 1)
        #expect(try store.deleteDocument(id: first.document.docID) == task.number)
        #expect(try store.documents().isEmpty)
    }

    @Test("質問は文書に 1 つだけ open。同じ質問の再 publish は作り直さず、違えば前を cancelled にし、空配列で取り下げ")
    func askSwap() throws {
        let (store, task) = try makeStore()
        let first = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions))
        let askID = try #require(first.askID)
        let same = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "? rev2", questions: twoQuestions))
        #expect(same.askID == askID, "同じ質問なら入力途中の回答を消さない")
        let untouched = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "? rev3"))
        #expect(untouched.askID == askID, "questions 省略は今ある質問に触らない")

        let changed = try store.publish(
            task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: [twoQuestions[0]]))
        let newID = try #require(changed.askID)
        #expect(newID != askID)
        let all = try store.asks(task: task.number)
        #expect(all.map(\.status) == [.cancelled, .open])
        #expect(try store.asks(pending: true).map(\.askID) == [newID], "cancelled は snapshot に載せない")

        let withdrawn = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: []))
        #expect(withdrawn.askID == nil)
        #expect(try store.asks(pending: true).isEmpty)

        #expect(throws: StoreError.invalid("質問 id が重複している: q1")) {
            try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: [twoQuestions[0], twoQuestions[0]]))
        }
    }

    @Test("既存の文書に質問だけ付けると、本文・題・リビジョンは変わらない（ask_user が計画書の本文を質問の文で上書きしていた）")
    func attachQuestionsKeepsContent() throws {
        let (store, task) = try makeStore()
        let plan = try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .markdown, content: "# 計画の本文", title: "計画"))
        let attached = try store.attachQuestions(doc: plan.document.docID, questions: twoQuestions)
        #expect(!attached.isNew && attached.revision == 1 && attached.document.title == "計画")
        #expect(try store.revisions(doc: plan.document.docID).map(\.rev) == [1])
        #expect(try store.content(doc: plan.document.docID, rev: nil).content == "# 計画の本文")
        let askID = try #require(attached.askID)
        #expect(try store.ask(id: askID)?.docID == plan.document.docID)
        #expect(try store.attachQuestions(doc: plan.document.docID, questions: twoQuestions).askID == askID, "同じ質問なら作り直さない")
        #expect(throws: StoreError.docNotFound(999)) { try store.attachQuestions(doc: 999, questions: twoQuestions) }
    }

    @Test("タスクを終端の列（完了・見送り）に移すと未回答の質問を取り下げる。回答済みと、終端でない列への移動には触らない")
    func terminalColumnCancelsOpenAsks() throws {
        let (store, task) = try makeStore()
        let open = try #require(try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions)).askID)
        let answered = try #require(try store.publish(task: task.number, DocPublishRequest(name: "a.md", format: .markdown, content: "?", questions: [twoQuestions[0]])).askID)
        _ = try store.answerAsk(id: answered, answers: [AskAnswer(questionID: "q1", selected: ["A"])])

        let working = try store.updateTaskCancellingAsks(number: task.number, TaskUpdateRequest(columnID: "working"))
        #expect(working.cancelled.isEmpty && working.task.columnID == "working")
        #expect(try store.ask(id: open)?.status == .open)

        let done = try store.updateTaskCancellingAsks(number: task.number, TaskUpdateRequest(columnID: "done"))
        #expect(done.cancelled.map(\.askID) == [open] && done.cancelled.allSatisfy { $0.status == .cancelled })
        #expect(try store.ask(id: answered)?.status == .answered, "回答済みは届ける前に消さない")

        let again = try store.updateTaskCancellingAsks(number: task.number, TaskUpdateRequest(title: "題だけ変える"))
        #expect(again.cancelled.isEmpty)
    }

    @Test("質問に作業項目を結ぶと、その項目は回答待ちになり、回答か取り下げで作業中に戻る。差し替えた質問は結びを引き継ぎ、別のタスクの項目は結べない")
    func askLinkedWorkItem() throws {
        let (store, task) = try makeStore()
        let item = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "方式を決める", state: .doing))
        let first = try #require(
            try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions, workItem: item.itemID)).askID)
        let waiting = try #require(try store.workItems(task: task.number).first)
        #expect(waiting.state == .wait && waiting.blockerKind == .approval && waiting.blockerText == "質問「方式はどちらにするか」の回答待ち")

        // 違う質問で出し直すと前は取り下げになるが、項目は待ちのまま新しい質問に結ばれる
        let doc = try #require(try store.ask(id: first)).docID
        let second = try #require(try store.attachQuestions(doc: doc, questions: [twoQuestions[1]]).askID)
        #expect(second != first)
        #expect(try store.workItems(task: task.number).first?.state == .wait)

        _ = try store.answerAsk(id: second, answers: [AskAnswer(questionID: "q2", selected: ["守る"])])
        let resumed = try #require(try store.workItems(task: task.number).first)
        #expect(resumed.state == .doing && resumed.blockerKind == nil && resumed.blockerText.isEmpty)

        // 取り下げでも戻る
        let third = try #require(
            try store.publish(task: task.number, DocPublishRequest(name: "r.md", format: .markdown, content: "?", questions: [twoQuestions[0]], workItem: item.itemID)).askID)
        #expect(try store.workItems(task: task.number).first?.state == .wait)
        _ = try store.cancelAsk(id: third)
        #expect(try store.workItems(task: task.number).first?.state == .doing)

        let board = try #require(try store.boards().first)
        let other = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "別"))
        #expect(throws: StoreError.self) {
            try store.publish(task: other.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions, workItem: item.itemID))
        }
    }

    @Test("回答は全問必須。answered は未受領として claim に載り、受領で delivered が付く")
    func answerAndDeliver() throws {
        let (store, task) = try makeStore()
        let published = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions))
        let askID = try #require(published.askID)
        #expect(throws: StoreError.askUnanswered(["q2"])) {
            try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        }
        #expect(throws: StoreError.askUnanswered(["q1", "q2"])) {
            try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: [], freeText: "")])
        }
        let answered = try store.answerAsk(
            id: askID, answers: [AskAnswer(questionID: "q1", selected: [], freeText: "C がよい"), AskAnswer(questionID: "q2", selected: ["守る", "ずらす"])])
        #expect(answered.status == .answered && answered.answeredAt != nil && answered.deliveredAt == nil)
        #expect(answered.answers?.count == 2)
        #expect(throws: StoreError.askNotOpen(askID)) { try store.answerAsk(id: askID, answers: []) }
        #expect(try store.cancelAsk(id: askID) == nil, "answered は取り下げられない（何もしない）")

        #expect(try undelivered(store, task: task.number) == 1)
        let peek = try store.peekUndeliveredFeedback(task: task.number)
        #expect(peek.items == [.ask(askID)] && peek.bundle.answeredAsks.first?.answers?.first?.freeText == "C がよい")
        #expect(try undelivered(store, task: task.number) == 1, "peek は受領済みにしない")
        #expect(try store.asks(pending: true).count == 1, "answered で未受領は snapshot に残る")

        let delivered = try store.markFeedbackDelivered(peek.items)
        #expect(delivered.first?.deliveredAt != nil)
        #expect(try undelivered(store, task: task.number) == 0)
        #expect(try store.asks(pending: true).isEmpty, "受領済みは落ちる")
        #expect(try store.takeUndeliveredFeedback(task: task.number).0.isEmpty)
    }

    @Test("コメントは draft のまま貯まり、レビュー送信で open になって依頼が消え、1 回だけ届く。返信は agent 即時 / human は送信まで draft")
    func reviewFlow() throws {
        let (store, task) = try makeStore()
        let doc = try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .markdown, content: "本文 abc", title: "計画")).document
        let (requested, request) = try store.requestReview(task: task.number, note: "2 章を見てほしい")
        #expect(requested.status == .requested && request?.note == "2 章を見てほしい")
        #expect(try store.reviewRequests().count == 1)

        let c1 = try store.createDraftComment(doc: doc.docID, CommentCreateRequest(rev: 1, anchor: CommentAnchor(exact: "abc", prefix: "本文 ", suffix: ""), body: "ここが曖昧"))
        let c2 = try store.createDraftComment(doc: doc.docID, CommentCreateRequest(rev: 1, body: "全体に長い"))
        #expect(c1.state == .draft && c1.docName == "plan.md" && c1.anchor?.exact == "abc")
        #expect(throws: StoreError.revisionNotFound(5)) { try store.createDraftComment(doc: doc.docID, CommentCreateRequest(rev: 5, body: "x")) }
        #expect(try store.document(id: doc.docID)?.draftComments == 2)
        _ = try store.updateDraftComment(id: c2.id, body: "全体に長い。半分に")
        let draft = try store.reviewDraft(task: task.number)
        #expect(draft.review == nil && draft.comments.map(\.id) == [c1.id, c2.id])
        #expect(try undelivered(store, task: task.number) == 0, "draft は届かない")

        _ = try store.setReviewSummary(task: task.number, summary: "方向はよい")
        let submitted = try store.submitReview(task: task.number)
        #expect(submitted.state == .submitted && submitted.summary == "方向はよい" && submitted.submittedAt != nil)
        #expect(try store.reviewRequests().isEmpty, "送信で依頼は消える")
        let after = try store.document(id: doc.docID)
        #expect(after?.openComments == 2 && after?.draftComments == 0)
        #expect(throws: StoreError.commentNotDraft(c1.id)) { try store.updateDraftComment(id: c1.id, body: "x") }
        #expect(throws: StoreError.commentNotDraft(c1.id)) { try store.deleteDraftComment(id: c1.id) }

        let taken = try store.takeUndeliveredFeedback(task: task.number).0
        #expect(taken.reviews.count == 1 && taken.reviews[0].comments.map(\.body) == ["ここが曖昧", "全体に長い。半分に"])
        #expect(taken.reviews[0].review.summary == "方向はよい")
        #expect(try store.takeUndeliveredFeedback(task: task.number).0.isEmpty, "1 回だけ返る")

        let agentReply = try store.addReply(comment: c1.id, author: .agent, body: "直した", resolve: true)
        #expect(agentReply.state == .submitted)
        #expect(try store.comment(id: c1.id)?.state == .resolved)
        #expect(try store.document(id: doc.docID)?.openComments == 1)
        let humanReply = try store.addReply(comment: c1.id, author: .human, body: "まだ足りない", resolve: false)
        #expect(humanReply.state == .draft)
        _ = try store.setCommentResolved(id: c1.id, false)
        #expect(try store.comment(id: c1.id)?.state == .open)

        // 2 回目のレビュー: 人の返信が submitted になって届く
        _ = try store.submitReview(task: task.number)
        let second = try store.takeUndeliveredFeedback(task: task.number).0
        #expect(second.reviews.count == 1 && second.reviews[0].comments.isEmpty)
        #expect(second.reviews[0].replies.map(\.reply.body) == ["まだ足りない"] && second.reviews[0].replies[0].commentBody == "ここが曖昧")
        #expect(try store.comment(id: c1.id)?.replies.map(\.state) == [.submitted, .submitted])
    }

    @Test("未受領のあるタスクの番号は、回答・レビュー・受領と、SQL で直に書いた分も commit のたびに読み直す。rollback した分は入らない")
    func undeliveredTaskNumbers() throws {
        let (store, task) = try makeStore()
        let other = try store.createTask(TaskCreateRequest(boardID: task.boardID, columnID: "planning", title: "別"))
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty)
        let published = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions))
        let askID = try #require(published.askID)
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty, "回答待ちは未受領でない")
        _ = try store.answerAsk(
            id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"]), AskAnswer(questionID: "q2", selected: ["守る"])])
        #expect(try store.tasksWithUndeliveredFeedback() == [task.number])
        _ = try store.publish(task: other.number, DocPublishRequest(name: "a.md", format: .markdown, content: "a"))
        _ = try store.submitReview(task: other.number)
        #expect(try store.tasksWithUndeliveredFeedback() == [task.number, other.number])
        _ = try store.markFeedbackDelivered([.ask(askID)])
        #expect(try store.tasksWithUndeliveredFeedback() == [other.number])
        _ = try store.takeUndeliveredFeedback(task: other.number)
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty)

        try store.database.write { db in try db.execute(sql: "UPDATE ask SET deliveredAt = NULL WHERE id = ?", arguments: [askID]) }
        #expect(try store.tasksWithUndeliveredFeedback() == [task.number], "Store の口を通らない書き込みも拾う")
        _ = try store.markFeedbackDelivered([.ask(askID)])
        struct Abort: Error {}
        #expect(throws: Abort.self) {
            try store.database.write { db in
                try db.execute(sql: "UPDATE ask SET deliveredAt = NULL WHERE id = ?", arguments: [askID])
                throw Abort()
            }
        }
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty)
    }

    @Test("読んでいる間に ask・review への書き込みが commit されたら、読んだ値は控えず、次はまた読む")
    func undeliveredTaskNumbersDropStaleRead() throws {
        let (store, task) = try makeStore()
        let published = try store.publish(task: task.number, DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: twoQuestions))
        let tasks = UndeliveredFeedbackTasks()
        store.database.add(transactionObserver: tasks)
        let stale = try tasks.numbers {
            try store.database.write { db in try db.execute(sql: "UPDATE ask SET status = 'answered' WHERE id = ?", arguments: [published.askID]) }
            return []
        }
        #expect(stale.isEmpty)
        var loads = 0
        let fresh = tasks.numbers {
            loads += 1
            return [task.number]
        }
        #expect(fresh == [task.number] && loads == 1)
        #expect(tasks.numbers { [] } == [task.number], "書き込みが無ければ控えを返す")
    }

    @Test("未受領のレビューが残っているうちは依頼を立てない")
    func requestBlockedByPendingReview() throws {
        let (store, task) = try makeStore()
        _ = try store.publish(task: task.number, DocPublishRequest(name: "a.md", format: .markdown, content: "a"))
        _ = try store.submitReview(task: task.number)
        let (result, request) = try store.requestReview(task: task.number, note: "")
        #expect(result.status == .feedbackPending && result.pendingFeedback == 1 && request == nil)
        #expect(try store.reviewRequests().isEmpty)
    }

    @Test("タスクを消すと文書・質問・レビューも消える")
    func cascade() throws {
        let (store, task) = try makeStore()
        let doc = try store.publish(task: task.number, DocPublishRequest(name: "a.md", format: .markdown, content: "a", questions: [twoQuestions[0]]))
        _ = try store.createDraftComment(doc: doc.document.docID, CommentCreateRequest(rev: 1, body: "x"))
        _ = try store.requestReview(task: task.number, note: "")
        try store.deleteTask(number: task.number)
        #expect(try store.documents().isEmpty && (try store.asks(pending: true)).isEmpty && (try store.reviewRequests()).isEmpty)
        #expect(try store.document(id: doc.document.docID) == nil)
    }

    @Test("手作業を済ませると作業中に戻って待ち理由が消え、頼んだ文が未受領の知らせに残る。手作業待ちでない項目は断り、受領済みにすると残らない")
    func finishManualWork() throws {
        let (store, task) = try makeStore()
        let item = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "実機の確認"))
        #expect(throws: StoreError.conflict("作業項目 \(item.itemID) は手作業待ちでない")) { try store.finishManualWork(id: item.itemID) }
        _ = try store.updateWorkItem(id: item.itemID, WorkItemUpdateRequest(state: .wait, blockerKind: .manual, blockerText: "iPhone をつなぐ"))

        #expect(try store.finishManualWork(id: item.itemID) == task.number)
        let back = try #require(try store.workItems(task: task.number).first)
        #expect(back.state == .doing && back.blockerKind == nil && back.blockerText == "")
        #expect(try store.tasksWithUndeliveredFeedback() == [task.number])
        let peek = try store.peekUndeliveredFeedback(task: task.number)
        #expect(peek.items == [.finished(item.itemID)])
        #expect(peek.bundle.finishedWork.map(\.request) == ["iPhone をつなぐ"] && peek.bundle.finishedWork.map(\.title) == ["実機の確認"])
        #expect(throws: StoreError.conflict("作業項目 \(item.itemID) は手作業待ちでない"), "2 回押しても 2 通にしない") {
            try store.finishManualWork(id: item.itemID)
        }
        #expect(throws: StoreError.workItemNotFound(999)) { try store.finishManualWork(id: 999) }

        _ = try store.markFeedbackDelivered(peek.items)
        #expect(try undelivered(store, task: task.number) == 0)
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty)
    }
}

@Suite("FeedbackService: claim / ack / 待機")
struct FeedbackServiceTests {
    private let machine = MachineID(rawValue: "m-test")

    private func make() async throws -> (Store, DaemonState, FeedbackService, BoardTask, Int64) {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "設計"))
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "sess-1", cwd: "/repo", label: "")
        let published = try store.publish(
            task: task.number,
            DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: [AskQuestion(id: "q1", question: "どっち", options: [AskOption(label: "A")])]))
        return (store, state, FeedbackService(store: store, state: state), task, try #require(published.askID))
    }

    @Test("紐づくタスクが無ければ no-session。未受領があれば待たずに claim、ack で受領済み。知らない claim は false")
    func claimImmediate() async throws {
        let (store, _, service, _, askID) = try await make()
        #expect(try await service.claim(FeedbackClaimRequest(agentSessionID: "nobody", timeoutMs: 10)).status == .noSession)

        _ = try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        let claimed = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 10))
        #expect(claimed.status == .feedback && claimed.bundle?.answeredAsks.count == 1)
        let claimID = try #require(claimed.claimID)
        // ack 前にもう一度 claim すると同じものが返る（二重配送は hook が ack しなかったときだけ）
        let again = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 10))
        #expect(again.status == .feedback && again.claimID != claimID)

        #expect(try await service.ack(claimID: claimID))
        #expect(try await service.ack(claimID: "unknown") == false)
        #expect(try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 10)).status == .pending)
    }

    @Test("未受領が無ければ待ち、回答の notify で起きて claim を返す。timeout なら pending")
    func claimWaits() async throws {
        let (store, _, service, task, askID) = try await make()
        let waiting = Task { try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 5_000)) }
        // 待機に入るまで少し待ってから回答する
        for _ in 0..<50 where await service.waiterCount(task: task.number) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await service.waiterCount(task: task.number) == 1)
        _ = try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        await service.notify(task: task.number)
        let result = try await waiting.value
        #expect(result.status == .feedback && result.claimID != nil)

        _ = try await service.ack(claimID: try #require(result.claimID))
        let timedOut = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 50))
        #expect(timedOut.status == .pending)
    }

    @Test("同じタスクの新しい claim は前の待機者を解放する（hook は毎ターン走る）")
    func releasesPreviousWaiter() async throws {
        let (_, _, service, task, _) = try await make()
        let first = Task { try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 5_000)) }
        for _ in 0..<50 where await service.waiterCount(task: task.number) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let second = Task { try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 100)) }
        let firstResult = try await first.value
        #expect(firstResult.status == .pending, "解放された方は pending で返る")
        #expect(try await second.value.status == .pending)
        #expect(await service.waiterCount(task: task.number) == 0)
    }

    private func makeWithMarkers() async throws -> (Store, FeedbackService, FeedbackMarkers, BoardTask, Int64, URL) {
        let (store, state, _, task, askID) = try await make()
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "sess-2", cwd: "/repo", label: "")
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-markers-\(UUID().uuidString)", directoryHint: .isDirectory)
        let markers = FeedbackMarkers(directory: dir)
        return (store, FeedbackService(store: store, state: state, markers: markers), markers, task, askID, dir)
    }

    @Test("回答の notify で、そのタスクに結ばれた全部のセッションに印を置く。ack で未受領が無くなれば全部消す")
    func notifyMarksLinkedSessions() async throws {
        let (store, service, markers, task, askID, dir) = try await makeWithMarkers()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!markers.isMarked("sess-1") && !markers.isMarked("sess-2"))

        _ = try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        await service.notify(task: task.number)
        #expect(markers.isMarked("sess-1") && markers.isMarked("sess-2"))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let claimed = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 10))
        #expect(try await service.ack(claimID: try #require(claimed.claimID)))
        #expect(!markers.isMarked("sess-1") && !markers.isMarked("sess-2"), "届けきったので、ほかのセッションの印も要らない")
    }

    @Test("timeoutMs 0 は待たない: 未受領があれば返し、無ければ pending。どちらでも自分の印を消し、待っている Stop hook を解放しない")
    func claimWithoutWaiting() async throws {
        let (store, service, markers, task, askID, dir) = try await makeWithMarkers()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        await service.notify(task: task.number)

        let now = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 0))
        #expect(now.status == .feedback && now.bundle?.answeredAsks.count == 1)
        #expect(!markers.isMarked("sess-1"), "長くて ack できなくても、ツールのたびに同じ文を入れ直さない")
        #expect(markers.isMarked("sess-2"), "まだ受領されていないので、ほかのセッションの印は残る")

        _ = try await service.ack(claimID: try #require(now.claimID))
        let waiting = Task { try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-1", timeoutMs: 5_000)) }
        for _ in 0..<50 where await service.waiterCount(task: task.number) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        let empty = try await service.claim(FeedbackClaimRequest(agentSessionID: "sess-2", timeoutMs: 0))
        #expect(empty.status == .pending)
        #expect(await service.waiterCount(task: task.number) == 1, "ツールの hook の claim で Stop hook の待ちを切らない")
        waiting.cancel()
        await service.notify(task: task.number)
        _ = try? await waiting.value
    }

    @Test("feedback_list（take）で受け取ったら印を消す")
    func takeClearsMarkers() async throws {
        let (store, service, markers, task, askID, dir) = try await makeWithMarkers()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.answerAsk(id: askID, answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        await service.notify(task: task.number)
        let bundle = try await service.take(task: task.number)
        #expect(bundle.answeredAsks.count == 1)
        #expect(!markers.isMarked("sess-1") && !markers.isMarked("sess-2"))
    }

    @Test("ファイル名に使えないセッション ID には印を置かない")
    func markerRejectsUnsafeIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-markers-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let markers = FeedbackMarkers(directory: dir)
        markers.mark(sessions: ["../escape", "", ".", "..", "a/b", "ok-1_2.3", "日本語"])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["ok-1_2.3"])
        #expect(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "escape").path))
    }

}
