import Foundation
import TaskboardKit

/// 終わっていない作業項目を依存（`dependsOn`）で段に分け、上の段から並べたもの。同じ段の項目は互いに依存しないので並行でき、
/// 段の中は作業中・待ち・未着手の順（同じ状態は計画順）。完了と見送りは段に入れず `closed` に計画順で持つ。
/// 依存の線は出元の項目ごとに 1 本の縦の筋（`Lane`）にし、行の範囲が重なる線は別の筋に置く。
/// 線は行ごとに自分の高さの分を引く（`Row.marks`）ので、画面に出ていない行は配置しなくてよい
struct WorkItemGraph {
    /// 1 つの行が受け持つ線の一部
    struct LaneMark: Equatable {
        enum Kind: Equatable {
            /// 印から筋へ出て、行の下まで
            case source
            /// 行の上から下まで通る
            case through
            /// 通りながら、印へ枝を出す（最後でない線の先）
            case branch
            /// 行の上から印まで来て止まる（最後の線の先）
            case target
        }

        let slot: Int
        let kind: Kind
    }

    struct Header: Equatable {
        /// 1 から数えた段
        let number: Int
        /// その段の項目の数
        let count: Int
    }

    struct Row: Identifiable {
        let item: WorkItem
        let state: WorkItem.EffectiveState
        let level: Int
        /// 段の最初の行に付ける見出し。段が 1 つなら付けない
        let header: Header?
        /// この行が引く線（筋の番号の順）
        var marks: [LaneMark] = []
        var id: Int64 { item.itemID }
    }

    struct Lane: Equatable {
        let source: Int64
        /// 線の先（行の順）
        let targets: [Int64]
        /// 筋の番号。0 が項目にいちばん近い
        let slot: Int
    }

    let rows: [Row]
    let lanes: [Lane]
    let slotCount: Int
    /// 完了と見送りの項目（計画順。線も段も持たない）
    let closed: [Row]

    init(items: [WorkItem]) {
        let states = WorkItem.effectiveStates(of: items)
        let isClosed: (WorkItem) -> Bool = { $0.state == .done || $0.state == .drop }
        let open = items.filter { !isClosed($0) }
        closed = items.filter(isClosed).map { Row(item: $0, state: states[$0.itemID] ?? .done, level: 0, header: nil) }
        let levels = Self.levels(of: open)
        let byLevel = Dictionary(grouping: open) { levels[$0.itemID] ?? 0 }
        let levelCount = (byLevel.keys.max() ?? -1) + 1

        var rows: [Row] = []
        for level in 0..<levelCount {
            let members = Self.activeFirst(byLevel[level, default: []], states: states)
            for (index, item) in members.enumerated() {
                let header = levelCount > 1 && index == 0 ? Header(number: level + 1, count: members.count) : nil
                rows.append(Row(item: item, state: states[item.itemID] ?? .todo, level: level, header: header))
            }
        }
        (lanes, slotCount) = Self.lanes(rows: rows)
        let index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        for lane in lanes {
            guard let start = index[lane.source] else { continue }
            let ends = Set(lane.targets.compactMap { index[$0] })
            guard let last = ends.max() else { continue }
            for row in start...last {
                let kind: LaneMark.Kind = row == start ? .source : row == last ? .target : ends.contains(row) ? .branch : .through
                rows[row].marks.append(LaneMark(slot: lane.slot, kind: kind))
            }
        }
        for row in rows.indices { rows[row].marks.sort { $0.slot < $1.slot } }
        self.rows = rows
    }

    /// 段の中の並び。作業中・待ちを先に出し、同じ順位の中は計画順のまま（安定）
    private static func activeFirst(_ members: [WorkItem], states: [Int64: WorkItem.EffectiveState]) -> [WorkItem] {
        func rank(_ item: WorkItem) -> Int {
            switch states[item.itemID] ?? .todo {
            case .doing: 0
            case .wait: 1
            default: 2
            }
        }
        return members.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// 依存の無い項目は 0、ほかは依存の段の最大 + 1。一覧に無い項目・自分・循環を作る依存は数えない
    private static func levels(of items: [WorkItem]) -> [Int64: Int] {
        let byID = Dictionary(items.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [Int64: Int] = [:]
        var visiting: Set<Int64> = []
        func level(_ id: Int64) -> Int {
            if let known = memo[id] { return known }
            visiting.insert(id)
            let deps = byID[id]?.dependsOn.filter { byID[$0] != nil && !visiting.contains($0) } ?? []
            let value = deps.map { level($0) + 1 }.max() ?? 0
            visiting.remove(id)
            memo[id] = value
            return value
        }
        for item in items { _ = level(item.itemID) }
        return memo
    }

    /// 出元ごとに、出元の行から最後の線の先の行までを 1 つの筋に置く。行の順に見て、前の線が終わった行より後から始まる筋を使い直す
    private static func lanes(rows: [Row]) -> ([Lane], Int) {
        let index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        var targets: [Int64: [Int64]] = [:]
        for row in rows {
            for dep in Set(row.item.dependsOn) where dep != row.id && (index[dep] ?? .max) < (index[row.id] ?? 0) {
                targets[dep, default: []].append(row.id)
            }
        }
        var slotEnds: [Int] = []
        var lanes: [Lane] = []
        for row in rows {
            guard let ends = targets[row.id], let start = index[row.id] else { continue }
            let end = ends.compactMap { index[$0] }.max() ?? start
            let slot = slotEnds.firstIndex { $0 < start } ?? slotEnds.count
            if slot == slotEnds.count { slotEnds.append(end) } else { slotEnds[slot] = end }
            lanes.append(Lane(source: row.id, targets: ends, slot: slot))
        }
        return (lanes, slotEnds.count)
    }
}
