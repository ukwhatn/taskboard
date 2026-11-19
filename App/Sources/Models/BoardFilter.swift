import SwiftUI
import TaskboardKit

enum BoardFilter: String, CaseIterable, Identifiable {
    case all, waiting, running, withPR
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: String(localized: "すべて")
        case .waiting: String(localized: "応答待ち")
        case .running: String(localized: "実行中")
        case .withPR: String(localized: "PRあり")
        }
    }
}

extension AppModel {
    /// 板の絞り込みに合うタスク。応答待ちと実行中はタスクのセッションの集まり（`activity(of:)`）で見る
    func tasks(_ tasks: [BoardTask], matching filter: BoardFilter) -> [BoardTask] {
        switch filter {
        case .all: tasks
        case .waiting: tasks.filter { activity(of: $0).contains(.waiting) }
        case .running: tasks.filter { activity(of: $0).contains(.running) }
        case .withPR: tasks.filter { !$0.pullRequestLinks.isEmpty }
        }
    }
}
