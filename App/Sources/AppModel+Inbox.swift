import Foundation
import TaskboardKit

/// 受信箱の項目（daemon は持たず、アプリが state から導く）。画面は持たず、通知・Dock のバッジ・サイドバーの札・タスク画面の［無視］が使う。
/// 項目を押したとき（通知）の行き先もここで決める
extension AppModel {
    /// 項目の行き先。質問と文書はその文書、レビュー依頼はタスク（文書が 1 つならその文書）、手作業の依頼はタスク、応答待ちと会話の問いはその置き場の画面、
    /// PR は結んだタスクの PR の欄、PR の取得の失敗はタスクなしの画面
    func open(inbox item: InboxItem, from source: NavigationSource) {
        switch item.kind {
        case .question(let ask):
            openDocument(DocKey(machine: ask.machine, id: ask.docID), at: Self.formSlot(for: ask), from: source)
        case .docDraft(let doc, let draft):
            openDocument(doc.id, at: DocMarker(kind: .draft, id: draft.id).slot, from: source)
        case .document(let doc):
            navigate(to: .doc(doc.id), from: source)
        case .reviewRequest(let request):
            navigate(to: .task(request.id), from: source)
            let docs = fleet.documents(for: request.id)
            if docs.count == 1, let only = docs.first { openDoc = only.id }
        case .stalled(let task, _):
            navigate(to: .task(task.id), from: source)
        case .manualWork, .panelDraft:
            if let task = item.taskKey { navigate(to: .task(task), from: source) }
        case .conversationRequest(let conversation, _):
            navigate(to: .conversation(conversation.key), from: source)
        case .pullRequest(let notice):
            navigate(to: .pullRequest(url: notice.url), from: source)
        case .pullRequestTurn(let pr, _):
            navigate(to: .pullRequest(url: pr.url), from: source)
        case .prSync:
            navigate(to: .unassigned(item.machine), from: source)
        case .orchestratorReply:
            navigate(to: .orchestrator(item.machine), from: source)
        case .scheduleRun(let schedule, let run):
            navigate(to: Destination(TaskboardLink.scheduleRun(schedule, run, in: fleet.machineState(for: schedule.machine))), from: source)
        }
    }

    // MARK: 中身

    // 受信箱は `Fleet` が中身の変わったときに 1 回だけ組む（`Fleet.inbox`）。ここは組んだ結果を読むだけ

    /// shortcut: debug の口（`DebugServer+Inbox`）がこの名前で読むので残す。`now` は使わない。debug の口を直すときに外す
    func inbox(now _: Date) -> InboxContents { fleet.inbox }

    /// 受信箱に出す項目（無視・既読にしたものを除く）
    var inboxItems: [InboxItem] { fleet.inbox.items }

    /// 1 台だけ表示で隠したマシンの分と、無視・既読にした分も含める。通知が「もう見た」を覚えるためだけに使う
    /// （含めないと、戻したときや表示を戻したときに鳴り直す）
    var inboxItemsIncludingHidden: [InboxItem] { fleet.inboxIncludingHidden }

    /// Dock とアプリのバッジ、iPhone の「タスク」タブの数。無視した対応待ちは数えない。
    /// 会話の分は見張り盤の対応待ちの札（止まりの異常を含む）で数え、見張り盤の「対応待ち」の数と揃える
    var inboxWaitingCount: Int { fleet.conversationTiles.waitingCount(with: inboxItems) }

    /// タスクの対応待ちのうち、無視していないもの（タスク画面の［無視］とサイドバーの札）
    func waitingItems(for task: TaskKey) -> [InboxItem] {
        inboxItems.filter { $0.group == .waiting && $0.taskKey == task }
    }

    // MARK: 無視

    /// 対応待ちの「無視」。押したらすぐに消し、daemon が断ったら戻して帯で知らせる。項目が変わる（revision が替わる）とまた出る
    func dismiss(_ items: [InboxItem]) {
        send(items, mark: { $0.revision }, failure: "非表示にできませんでした") { source, request in
            try await source.dismissInbox(request.map(\.dismissRequestItem))
        }
    }

    /// 項目のマシンごとに送る（記録は項目のマシンの daemon にだけ置く）。応答の記録を入れてから途中の印を外すので、
    /// `inbox.dismissals_updated` が応答より後に届いても行が戻って見えない。後から同じ項目を押し直していたら、その印は外さない
    private func send(
        _ items: [InboxItem], mark: (InboxItem) -> String?, failure: LocalizedStringResource,
        _ call: @escaping @MainActor (any DaemonWriter, [InboxItem]) async throws -> [InboxDismissal]
    ) {
        let window = activeWindow
        guard !items.isEmpty else { return }
        var built: [String: String?] = [:]
        for item in items {
            // 戻す印は nil なので、添字で入れると key ごと消える
            built.updateValue(mark(item), forKey: item.id)
            inboxPending.updateValue(mark(item), forKey: item.id)
        }
        let marks = built
        for (machine, batches) in InboxDismissal.batches(items) {
            Task {
                do {
                    let source = try requireSource(machine)
                    for batch in batches {
                        let records = try await call(source, batch)
                        fleet.setInboxDismissals(records, for: machine)
                    }
                } catch {
                    fail(failure, error, in: window)
                }
                for item in batches.joined() where inboxPending[item.id] == marks[item.id] {
                    inboxPending.removeValue(forKey: item.id)
                }
            }
        }
    }

    /// 通知を押した。項目がまだあればその行き先へ、答え終えて消えていれば、通知に入れておいた URL へ
    func openNotification(itemID: String?, fallback: URL?) {
        if let itemID, let item = inboxItems.first(where: { $0.id == itemID }) {
            open(inbox: item, from: .notification)
        } else if let fallback {
            open(fallback, from: .notification)
        }
    }
}
