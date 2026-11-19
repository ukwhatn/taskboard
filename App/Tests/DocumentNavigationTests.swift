import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 文書の画面の、同じタスクの文書の前後と Esc の判断。fixtures `sessions-basic`: #120 に文書 1（新しい）と 2、#137 に文書 3 だけ
@MainActor
@Suite struct DocumentNavigationTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func doc(_ id: Int64, task: Int = 1) -> Document {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        return Document(machine: machine, docID: id, taskNumber: task, name: "\(id).md", format: .markdown, latestRev: 1, createdAt: date, updatedAt: date)
    }

    private func key(_ id: Int64) -> DocKey { DocKey(machine: machine, id: id) }

    // MARK: 前と次

    @Test("前は一覧で 1 つ上、次は 1 つ下")
    func middle() {
        let sequence = DocumentSequence(documents: [doc(5), doc(3), doc(9)], current: key(3))
        #expect(sequence.canSwitch)
        #expect(sequence.previous == key(5))
        #expect(sequence.next == key(9))
    }

    @Test("一覧の先頭では前が無く、末尾では次が無い")
    func edges() {
        let documents = [doc(5), doc(3), doc(9)]
        let first = DocumentSequence(documents: documents, current: key(5))
        #expect(first.previous == nil)
        #expect(first.next == key(3))
        let last = DocumentSequence(documents: documents, current: key(9))
        #expect(last.previous == key(3))
        #expect(last.next == nil)
    }

    @Test("文書が 1 つだけなら切り替えられない")
    func single() {
        let sequence = DocumentSequence(documents: [doc(5)], current: key(5))
        #expect(!sequence.canSwitch)
        #expect(sequence.previous == nil)
        #expect(sequence.next == nil)
    }

    @Test("今の文書が一覧に無い（削除された）ときは、前にも次にも移らない")
    func removed() {
        let sequence = DocumentSequence(documents: [doc(5), doc(3)], current: key(7))
        #expect(sequence.canSwitch)
        #expect(sequence.previous == nil)
        #expect(sequence.next == nil)
    }

    @Test("並びはタスクの文書の一覧と同じ（新しい順）で、同じタスクの文書だけ")
    func fixtureOrder() async throws {
        AppDefaults.useScratch("test-document-navigation")
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.document(for: key(3)) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        let task120 = DocumentSequence(model: model, current: key(2))
        #expect(task120.documents.map(\.docID) == [1, 2])
        #expect(task120.documents.map(\.docID) == model.fleet.documents(for: TaskKey(machine: machine, number: 120)).map(\.docID))
        #expect(task120.previous == key(1))
        #expect(task120.next == nil)
        let task137 = DocumentSequence(model: model, current: key(3))
        #expect(!task137.canSwitch)
    }

    // MARK: Esc

    @Test("書きかけが無ければ、文書を閉じる")
    func escapeCloses() {
        #expect(DocumentEscape.action(composerText: nil, pendingInput: false) == .closeDocument)
    }

    @Test("空のコメントの入力欄を開いていれば、入力欄だけを閉じる")
    func escapeClosesEmptyComposer() {
        #expect(DocumentEscape.action(composerText: "", pendingInput: false) == .closeComposer)
        #expect(DocumentEscape.action(composerText: " \n", pendingInput: true) == .closeComposer)
    }

    @Test("コメント・返信・回答の書きかけがあれば、何も閉じない")
    func escapeKeepsDraft() {
        #expect(DocumentEscape.action(composerText: "ここは表にしたい", pendingInput: false) == .keep)
        #expect(DocumentEscape.action(composerText: nil, pendingInput: true) == .keep)
    }
}
