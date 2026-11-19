import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store: 文書の本文の印と送る文面")
struct DocDraftStoreTests {
    private let machine = MachineID(rawValue: "m-test")

    private func makeStore() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "planning", title: "設計"))
        return (store, task)
    }

    private let question = AskQuestion(id: "q1", question: "方式はどちらにするか", options: [AskOption(label: "A", recommended: true), AskOption(label: "B")])
    private let slack = DocDraftSpec(id: "slack-1", draft: PanelDraft(title: "告知", to: "#dev のスレッド", body: "明日リリースします。"))

    private func publish(_ store: Store, _ task: BoardTask, _ content: String, questions: [AskQuestion]? = nil, drafts: [DocDraftSpec]? = nil) throws
        -> DocPublishResponse
    {
        try store.publish(task: task.number, DocPublishRequest(name: "plan.md", format: .markdown, content: content, questions: questions, drafts: drafts))
    }

    @Test("無い id を指す印と同じ印の重複は理由つきで断り、文書も版も作らない")
    func refusesUnknownMarkers() throws {
        let (store, task) = try makeStore()
        #expect(throws: StoreError.invalid(Copy.text("agent.doc.marker.unknownAsk", ["id": "q2"]))) {
            try publish(store, task, "前提\n<!-- ask: q2 -->", questions: [question])
        }
        #expect(throws: StoreError.invalid(Copy.text("agent.doc.marker.unknownDraft", ["id": "mail"]))) {
            try publish(store, task, "<!-- draft: mail -->", drafts: [slack])
        }
        #expect(throws: StoreError.invalid(Copy.text("agent.doc.marker.duplicate", ["slot": "ask:q1"]))) {
            try publish(store, task, "<!-- ask: q1 -->\n<div data-ask=\"q1\"></div>", questions: [question])
        }
        #expect(try store.documents(task: task.number).isEmpty)
    }

    @Test("questions・drafts を省いた再 publish の印は、今ある質問（本文と一緒に出した束）と文面を指す")
    func omittedKeepsExistingIDs() throws {
        let (store, task) = try makeStore()
        let first = try publish(store, task, "<!-- ask: q1 --><!-- draft: slack-1 -->", questions: [question], drafts: [slack])
        let asks = try store.asks(task: task.number)
        #expect(asks.count == 1 && asks[0].inBody, "doc_publish の質問は本文の印に入る")
        let second = try publish(store, task, "直した前提\n<!-- ask: q1 -->\n<!-- draft: slack-1 -->")
        #expect(second.revision == 2 && second.askID == first.askID && second.document.drafts.map(\.id) == ["slack-1"])
        #expect(throws: StoreError.invalid(Copy.text("agent.doc.marker.unknownDraft", ["id": "slack-1"]))) {
            try publish(store, task, "<!-- draft: slack-1 -->", drafts: [])
        }
    }

    @Test("ask_user で既存の文書に付けた束は本文の印に入らない")
    func attachedAskIsNotInBody() throws {
        let (store, task) = try makeStore()
        let doc = try publish(store, task, "前提だけ").document
        _ = try store.attachQuestions(doc: doc.docID, questions: [question])
        #expect(try store.asks(task: task.number).map(\.inBody) == [false])
        #expect(throws: StoreError.invalid(Copy.text("agent.doc.marker.unknownAsk", ["id": "q1"]))) {
            try publish(store, task, "<!-- ask: q1 -->")
        }
    }

    @Test("承認は同じ本文に 1 回だけで、人が直した本文が文書名つきで未受領の束に載る。会話が本文を変えると承認は外れ、変えない再 publish では残る")
    func approveOnceAndReset() throws {
        let (store, task) = try makeStore()
        let doc = try publish(store, task, "<!-- draft: slack-1 -->", drafts: [slack]).document
        #expect(doc.openDrafts.map(\.id) == ["slack-1"])
        #expect(throws: StoreError.invalid(Copy.text("agent.panel.invalid.empty", ["id": "slack-1", "field": "body"]))) {
            try store.approveDocDraft(doc: doc.docID, draftID: "slack-1", body: "  ")
        }
        #expect(try store.approveDocDraft(doc: doc.docID, draftID: "slack-1", body: "明後日リリースします。\n") == task.number)
        #expect(try store.approveDocDraft(doc: doc.docID, draftID: "slack-1", body: "別の本文") == task.number, "2 回目は何もしない")
        let peek = try store.peekUndeliveredFeedback(task: task.number)
        #expect(peek.bundle.drafts.count == 1)
        let approved = try #require(peek.bundle.drafts.first)
        #expect(approved.docName == "plan.md" && approved.partID == "slack-1" && approved.body == "明後日リリースします。" && approved.edited)
        #expect(try store.document(id: doc.docID)?.drafts.first?.answer?.body == "明後日リリースします。")

        _ = try publish(store, task, "版 2\n<!-- draft: slack-1 -->", drafts: [slack])
        #expect(try store.document(id: doc.docID)?.drafts.first?.answer != nil, "本文の同じ文面は承認を残す")
        var changed = slack
        changed.draft.body = "明後日の 10 時にリリースします。"
        _ = try publish(store, task, "版 3\n<!-- draft: slack-1 -->", drafts: [changed])
        #expect(try store.document(id: doc.docID)?.openDrafts.map(\.id) == ["slack-1"], "本文を変えた文面は承認を待ち直す")
        #expect(throws: StoreError.refused(.notFound, ["kind": "doc_draft"], Copy.text("agent.doc.drafts.notFound", ["id": "x"]))) {
            try store.approveDocDraft(doc: doc.docID, draftID: "x", body: "a")
        }
    }

    @Test("会話へ届く文は今の送る文面と同じ見出しで始まり、文書名と文書の更新の指示を添える")
    func promptText() throws {
        let item = PanelDraftFeedback(
            answerID: 1, taskNumber: 7, partID: "slack-1", title: "告知", to: "#dev", original: "a", body: "a", answeredAt: Date(), docName: "plan.md")
        let text = FeedbackText.forPrompt(FeedbackBundle(drafts: [item])).text
        #expect(text.contains(TaskboardNotice.draftPrefix + "7）。"))
        #expect(text.contains(Copy.text("agent.notice.feedbackPrompt.draft.document", ["name": "plan.md"])))
        #expect(text.contains(Copy.text("agent.notice.feedbackPrompt.draft.send.document")))
        #expect(!text.contains(Copy.text("agent.notice.feedbackPrompt.draft.send")), "概況の部品の指示（panel_update）は出さない")
    }
}
