import Foundation
import TaskboardKit

/// サイドバーのマシンとボードの並び。daemon には持たせず、この端末の表示の好みとして UserDefaults に置く。
enum SidebarOrder {
    /// `order` に載っている id をその順で先に、載っていない id を `ids` の順のまま後ろに並べる
    static func arrange(_ ids: [String], by order: [String]) -> [String] {
        let present = Set(ids)
        let saved = order.filter { present.contains($0) }
        let savedSet = Set(saved)
        return saved + ids.filter { !savedSet.contains($0) }
    }

    /// List の `onMove` の結果
    static func move(_ ids: [String], from source: IndexSet, to destination: Int) -> [String] {
        var ids = ids
        ids.move(fromOffsets: source, toOffset: destination)
        return ids
    }
}
