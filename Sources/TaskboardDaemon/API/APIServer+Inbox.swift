import Foundation
import Hummingbird
import TaskboardKit

/// 受信箱で消した項目の記録（対応待ちの「無視」とお知らせの「既読にする」）。端末の token でも呼べる。
/// 記録を変えたら `inbox.dismissals_updated` で全部の端末に配る
extension APIServer {
    static func registerInboxRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("inbox/dismissals") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().inboxDismissals() }, encoder)
        }
        v1.post("inbox/dismiss") { request, context in
            let body = try await request.decode(as: InboxDismissRequest.self, context: context)
            let store = try dependencies.requireStore()
            let records = try await mapStoreError { try await state.updateInboxDismissals { try store.dismissInbox(body.items) } }
            return try json(records, encoder)
        }
        v1.post("inbox/restore") { request, context in
            let body = try await request.decode(as: InboxRestoreRequest.self, context: context)
            let store = try dependencies.requireStore()
            let records = try await mapStoreError { try await state.updateInboxDismissals { try store.restoreInbox(itemIDs: body.itemIDs) } }
            return try json(records, encoder)
        }
    }
}
