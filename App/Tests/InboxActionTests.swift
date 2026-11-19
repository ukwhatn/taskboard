import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 受信箱の項目の無視（タスク画面の［無視］・カードの右クリック）。fixtures の接続は書き込めないので、daemon が断ったときの戻り方を見る
@MainActor
@Suite struct InboxActionTests {
    private func loadedModel() async throws -> AppModel {
        let model = AppModel(options: LaunchOptions(scenario: "sessions-basic"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.inboxItems.isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func settle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.inboxPending.isEmpty {
            try #require(ContinuousClock.now < deadline, "送った操作が終わらない")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("無視は押したらすぐに消え、断られたら戻して帯で知らせる")
    func dismissRevertsOnFailure() async throws {
        let model = try await loadedModel()
        let item = try #require(model.inboxItems.first { $0.group == .waiting })
        let waiting = model.inboxWaitingCount
        model.dismiss([item])
        #expect(!model.inboxItems.contains { $0.id == item.id }, "応答を待たずに消す")
        #expect(model.inboxWaitingCount == waiting - 1, "無視した対応待ちはバッジの数から外す")
        try await settle(model)
        #expect(model.inboxItems.contains { $0.id == item.id })
        #expect(model.failure(in: .unattached)?.text.hasPrefix("非表示にできませんでした") == true)
    }

    @Test("タスク画面の［無視］は、そのタスクの対応待ちを全部消し、サイドバーの札とバッジから外す。お知らせとほかのタスクの項目は残す")
    func dismissTaskWaiting() async throws {
        AppDefaults.useScratch("test-inbox-task")
        let model = AppModel(options: LaunchOptions(scenario: "stress"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.inboxItems.filter({ $0.group == .waiting && $0.taskKey != nil }).isEmpty {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(20))
        }
        let key = try #require(model.inboxItems.first { $0.group == .waiting && $0.taskKey != nil }?.taskKey)
        let task = try #require(model.fleet.task(for: key))
        let items = model.waitingItems(for: key)
        let others = model.inboxItems.filter { !items.map(\.id).contains($0.id) }
        #expect(model.rowStatus(of: task, waiting: model.waitingItemsByTask[key] ?? [])?.isMine == true)
        model.dismiss(items)
        #expect(model.waitingItems(for: key).isEmpty)
        #expect(model.waitingItemsByTask[key] == nil)
        #expect(model.rowStatus(of: task, waiting: [])?.isMine != true)
        #expect(Set(model.inboxItems.map(\.id)) == Set(others.map(\.id)))
    }

    @Test("通知の「もう見た」は無視した項目も含める（項目が変わって出直したときに、同じ版を鳴り直さない）")
    func notifierKnowsDismissed() async throws {
        let model = try await loadedModel()
        let item = try #require(model.inboxItems.first { $0.group == .waiting })
        model.fleet.setInboxDismissals([InboxDismissal(itemID: item.localID, revision: item.revision, dismissedAt: Date())], for: item.machine)
        #expect(model.inboxItemsIncludingHidden.contains { $0.id == item.id })
    }
}
