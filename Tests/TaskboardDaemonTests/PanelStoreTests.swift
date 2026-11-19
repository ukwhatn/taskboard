import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store: 概況の部品")
struct PanelStoreTests {
    private let machine = MachineID(rawValue: "m-test")

    private func makeStore() throws -> (Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "移行"))
        return (store, task)
    }

    private func gauge(_ id: String, _ value: String) -> PanelPartSpec {
        PanelPartSpec(id: id, content: .gauge(PanelGauge(label: "回答", value: value, basis: PanelBasis(kind: .denominator, value: "6"))), place: .band)
    }

    private let draft = PanelPartSpec(id: "notice", content: .draft(PanelDraft(title: "告知", to: "フォーラムのスレッド", body: "改定しました。")), place: .composer)

    @Test("panel_set は並びごと置き換え、中身の変わらない部品は更新の時刻とターン数を残す")
    func setKeepsUnchanged() throws {
        let (store, task) = try makeStore()
        let first = try store.setPanel(task: task.number, PanelSetRequest(parts: [gauge("a", "1"), gauge("b", "2")]), requesterSessionID: "sess-1").panel
        #expect(first.parts.map(\.id) == ["a", "b"] && first.turn == 0)
        try store.notePanelTurn(task: task.number)
        try store.notePanelTurn(task: task.number)
        let second = try store.setPanel(task: task.number, PanelSetRequest(parts: [gauge("b", "3"), gauge("a", "1")]), requesterSessionID: "sess-1").panel
        #expect(second.parts.map(\.id) == ["b", "a"])
        #expect(second.turn == 2)
        #expect(second.parts.map(\.updatedTurn) == [2, 0], "a は中身が同じなので前の回のまま")
        #expect(second.isStale(second.parts[1]) && !second.isStale(second.parts[0]))
        #expect(try store.panels().map(\.taskNumber) == [task.number])

        let cleared = try store.setPanel(task: task.number, PanelSetRequest(parts: []), requesterSessionID: nil)
        #expect(cleared.panel.parts.isEmpty)
        #expect(try store.panel(task: task.number) == nil && store.panels().isEmpty)
    }

    @Test("場所の数を超えた登録は誤りで返り、部品は変わらない（MCP も HTTP も同じ入口を通る）")
    func budgetRejects() throws {
        let (store, task) = try makeStore()
        _ = try store.setPanel(task: task.number, PanelSetRequest(parts: [gauge("a", "1")]), requesterSessionID: nil)
        let five = (1...5).map { gauge("g\($0)", "\($0)") }
        #expect(throws: StoreError.invalid("band に置ける部品は 4 個まで（5 個ある）")) {
            try store.setPanel(task: task.number, PanelSetRequest(parts: five), requesterSessionID: nil)
        }
        _ = try store.setPanel(task: task.number, PanelSetRequest(parts: Array(five.prefix(4))), requesterSessionID: nil)
        #expect(throws: StoreError.invalid("band に置ける部品は 4 個まで（5 個ある）")) {
            try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: gauge("g5", "5")), requesterSessionID: nil)
        }
        #expect(try store.panel(task: task.number)?.parts.count == 4)
        #expect(throws: StoreError.taskNotFound(999)) { try store.setPanel(task: 999, PanelSetRequest(parts: []), requesterSessionID: nil) }
    }

    @Test("panel_update は id で置き換え、無ければ位置に加え、remove で外す")
    func update() throws {
        let (store, task) = try makeStore()
        _ = try store.setPanel(task: task.number, PanelSetRequest(parts: [gauge("a", "1"), gauge("b", "2")]), requesterSessionID: nil)
        try store.notePanelTurn(task: task.number)
        var panel = try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: gauge("b", "5")), requesterSessionID: nil).panel
        #expect(panel.parts.map(\.id) == ["a", "b"] && panel.parts.map(\.updatedTurn) == [0, 1])
        panel = try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: gauge("c", "0"), position: 0), requesterSessionID: nil).panel
        #expect(panel.parts.map(\.id) == ["c", "a", "b"])
        panel = try store.updatePanelPart(task: task.number, PanelUpdateRequest(remove: "a"), requesterSessionID: nil).panel
        #expect(panel.parts.map(\.id) == ["c", "b"])
        #expect(throws: StoreError.refused(.notFound, ["kind": "panel_part"], "概況の部品 a が無い")) {
            try store.updatePanelPart(task: task.number, PanelUpdateRequest(remove: "a"), requesterSessionID: nil)
        }

        let colored = PanelPartSpec(id: "free", content: .html(PanelHTML(html: "<div style=\"color:#ff0000\">x</div>")))
        #expect(try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: colored), requesterSessionID: nil).warnings.count == 1)
        let other = try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: gauge("b", "6")), requesterSessionID: nil)
        #expect(other.warnings.isEmpty, "注意は置き換えた部品の分だけ（ほかの部品の注意を毎回返さない）")
    }

    @Test("送る文面の承認は、編集した本文で未受領の束に載り、登録した会話に届く。本文が書き換わると承認を待ち直す")
    func draftApproval() throws {
        let (store, task) = try makeStore()
        _ = try store.setPanel(task: task.number, PanelSetRequest(parts: [draft]), requesterSessionID: "sess-1")
        #expect(try store.panel(task: task.number)?.openDrafts.map(\.id) == ["notice"])
        let approved = try store.approvePanelDraft(task: task.number, partID: "notice", body: " 改定しました。本日付で反映します。 ")
        #expect(approved.openDrafts.isEmpty)
        #expect(approved.parts[0].answer?.edited == true && approved.parts[0].answer?.body == "改定しました。本日付で反映します。")
        _ = try store.approvePanelDraft(task: task.number, partID: "notice", body: "別の本文")

        #expect(try store.tasksWithUndeliveredFeedback() == [task.number])
        let peek = try store.peekUndeliveredFeedback(task: task.number)
        #expect(peek.bundle.drafts.count == 1, "2 回押しても 1 通")
        let feedback = try #require(peek.bundle.drafts.first)
        #expect(feedback.original == "改定しました。" && feedback.body == "改定しました。本日付で反映します。" && feedback.to == "フォーラムのスレッド")
        #expect(peek.requesters[.draft(feedback.answerID)] == "sess-1")
        let prompt = FeedbackText.forPrompt(peek.bundle).text
        #expect(prompt.contains("taskboard で送る文面を承認しました（#\(task.number)）。"))
        #expect(prompt.contains("利用者が編集した本文で承認した。送るのは次の本文:\n改定しました。本日付で反映します。"))
        _ = try store.markFeedbackDelivered(peek.items)
        #expect(try store.tasksWithUndeliveredFeedback().isEmpty)

        var edited = draft
        edited.content = .draft(PanelDraft(title: "告知", to: "フォーラムのスレッド", body: "改定しました（第 2 版）。"))
        let reset = try store.updatePanelPart(task: task.number, PanelUpdateRequest(part: edited), requesterSessionID: "sess-1").panel
        #expect(reset.openDrafts.map(\.id) == ["notice"])
        #expect(throws: StoreError.invalid("notice: body が空")) { try store.approvePanelDraft(task: task.number, partID: "notice", body: "  ") }
        #expect(throws: StoreError.refused(.notFound, ["kind": "panel_part"], "概況の部品 x が無い")) {
            try store.approvePanelDraft(task: task.number, partID: "x", body: "a")
        }
    }

    @Test("ターン数は概況のあるタスクだけ数える")
    func turnsOnlyWithPanel() throws {
        let (store, task) = try makeStore()
        try store.notePanelTurn(task: task.number)
        _ = try store.setPanel(task: task.number, PanelSetRequest(parts: [gauge("a", "1")]), requesterSessionID: nil)
        try store.notePanelTurn(task: task.number)
        #expect(try store.panel(task: task.number)?.turn == 1)
    }

    @Test("作業項目のまとまりと番号を保存し、空の文字列で外せる")
    func workGroupAndCode() throws {
        let (store, task) = try makeStore()
        let item = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "手順", group: "M3", code: "M3.6", source: "session"))
        #expect(item.group == "M3" && item.code == "M3.6")
        let renamed = try store.updateWorkItem(id: item.itemID, WorkItemUpdateRequest(code: "M3.7"))
        #expect(renamed.group == "M3" && renamed.code == "M3.7", "group を送らない更新はまとまりに触らない")
        let cleared = try store.updateWorkItem(id: item.itemID, WorkItemUpdateRequest(group: "", code: ""))
        #expect(cleared.group.isEmpty && cleared.code.isEmpty)
    }
}
