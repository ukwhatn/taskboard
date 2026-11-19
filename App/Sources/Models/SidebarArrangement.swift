import Foundation
import TaskboardKit

/// サイドバーの木の並べ方（右上のメニュー「並べ方」）。マシンの段は残し、その下の分け方とタスクの並び順を替える。
/// この端末に保存する（`DevicePrefs.sidebarArrangement`）
struct SidebarArrangement: Equatable {
    enum Grouping: String, CaseIterable {
        /// 案件 → 列 → タスク（今までの木）
        case boards
        /// 対応待ち・実行中・未読・待機の組
        case state
        /// マシンの下にタスクを並べるだけ
        case none

        var label: String {
            switch self {
            case .boards: String(localized: "案件と列")
            case .state: String(localized: "状態")
            case .none: String(localized: "なし")
            }
        }
    }

    enum Order: String, CaseIterable {
        case number, recent, created, title

        var label: String {
            switch self {
            case .number: String(localized: "番号")
            case .recent: String(localized: "最近の動き")
            case .created: String(localized: "追加日")
            case .title: String(localized: "タイトル")
            }
        }
    }

    var grouping: Grouping = .boards
    var order: Order = .number

    init(grouping: Grouping = .boards, order: Order = .number) {
        self.grouping = grouping
        self.order = order
    }

    /// 並び順に並べる。番号とタイトルは昇順、最近の動きと追加日は新しい順。同じなら番号の順
    func sorted(_ tasks: [BoardTask], lastActivity: (BoardTask) -> Date) -> [BoardTask] {
        switch order {
        case .number:
            return tasks.sorted { $0.number < $1.number }
        case .recent:
            return tasks.map { ($0, lastActivity($0)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.number < $1.0.number }
                .map(\.0)
        case .created:
            return tasks.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.number < $1.number }
        case .title:
            return tasks.sorted {
                let result = $0.title.localizedStandardCompare($1.title)
                return result != .orderedSame ? result == .orderedAscending : $0.number < $1.number
            }
        }
    }
}

/// 状態で分けたときの組（並びは case の順）。行の札から決める
enum SidebarStateGroup: CaseIterable {
    case waiting, running, unread, idle

    init(_ status: TaskRowStatus?) {
        switch status {
        case let status? where status.isMine: self = .waiting
        case .running: self = .running
        case .unread: self = .unread
        default: self = .idle
        }
    }

    var label: String {
        switch self {
        case .waiting: String(localized: "対応待ち")
        case .running: String(localized: "実行中")
        case .unread: String(localized: "未読")
        case .idle: String(localized: "待機")
        }
    }
}
