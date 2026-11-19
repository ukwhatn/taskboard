import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// ［次の入力待ちへ移動］（⌥⌘A・パレット）。人の入力を待っているセッション・会話を、全マシンのうち待ちの古い順に開く
@MainActor
@Suite struct NextAttentionTests {
    private func loaded(_ scenario: String, layout: HomeLayout = .columns, until ready: (AppModel) -> Bool) async throws -> AppModel {
        AppDefaults.useScratch("test-next-attention-\(scenario)")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        model.homeLayout = layout
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(model) {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("行き先は応答待ち・回答待ち・計画の承認待ちだけで、待ちの古い順。レビュー依頼などは入れない")
    func candidates() async throws {
        let model = try await loaded("sessions-basic") { !$0.inboxItems.isEmpty }
        let items = model.attentionItems
        #expect(!items.isEmpty)
        let kinds: Set<TaskRowStatus> = [.blocked, .question, .planApproval]
        #expect(items.allSatisfy { TaskRowStatus($0).map(kinds.contains) == true })
        #expect(items.map(\.at) == items.map(\.at).sorted())
        let others = model.inboxItems.filter { $0.group == .waiting && !items.map(\.id).contains($0.id) }
        #expect(others.contains { TaskRowStatus($0) == .reviewRequested }, "fixtures のレビュー依頼は行き先に入らない")
    }

    @Test("押すたびに次の古いものを開き、最後の次は先頭に戻る")
    func cycles() async throws {
        let model = try await loaded("sessions-basic") { !$0.inboxItems.isEmpty }
        let items = model.attentionItems
        try #require(items.count >= 2)
        var opened: [String?] = []
        for _ in 0...items.count {
            model.openNextAttention()
            opened.append(model.lastAttentionItem)
        }
        #expect(opened == items.map(\.id) + [items[0].id])
        #expect(model.notice(in: model.activeWindow) == nil)
    }

    @Test("無ければどこにも移らず、知らせだけ出す")
    func nothingWaiting() async throws {
        let model = try await loaded("empty") { !$0.fleet.allMachines.isEmpty }
        try #require(model.attentionItems.isEmpty)
        let before = model.sidebar
        model.openNextAttention()
        #expect(model.notice(in: model.activeWindow)?.text == "入力待ちのセッションはありません")
        #expect(model.sidebar == before)
        #expect(model.selectedTask == nil)
    }

    @Test("ホームが会話の形なら、対応待ちの札を待ちの古い順に選び（開かない）、最後の次は先頭に戻る")
    func cyclesTiles() async throws {
        let model = try await loaded("demo", layout: .conversations) { !$0.fleet.conversationTiles.waiting.isEmpty }
        var chosen: [String?] = []
        for _ in 0..<4 {
            model.openNextAttention()
            chosen.append(model.cursorTile?.id)
        }
        #expect(chosen == ["d-rank", "d-search", "d-csv", "d-rank"])
        #expect(model.selectedTask == nil)
        #expect(model.sidebar == .overview)
    }

    @Test("会話の形で対応待ちの会話が無ければ、選ばずに知らせだけ出す")
    func nothingWaitingInTiles() async throws {
        let model = try await loaded("empty", layout: .conversations) { !$0.fleet.allMachines.isEmpty }
        model.openNextAttention()
        #expect(model.notice(in: model.activeWindow)?.text == "対応待ちの会話はありません")
        #expect(model.cursorTile == nil)
    }
}
