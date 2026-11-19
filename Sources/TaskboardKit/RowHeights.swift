import Foundation

/// 自前の一覧（Mac の会話の一覧）の行の高さと位置。測った高さを行の id ごとに控え、測っていない行は見積もりで数える。
/// 位置は上の余白から、行の高さと行の間を足していった所
public struct RowHeights: Sendable {
    public let spacing: Double
    public let topInset: Double
    public let bottomInset: Double
    public private(set) var ids: [String] = []
    private var estimates: [Double] = []
    private var measured: [String: Double] = [:]
    private var heights: [Double] = []
    /// 行の上端
    private var tops: [Double] = []
    private var indexes: [String: Int] = [:]

    public init(spacing: Double, topInset: Double, bottomInset: Double) {
        self.spacing = spacing
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    /// 並びを替える。同じ id の測った高さは残し、並びから消えた行の高さは捨てる
    public mutating func setRows(_ ids: [String], estimates: [Double]) {
        self.ids = ids
        self.estimates = estimates
        indexes = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        measured = measured.filter { indexes[$0.key] != nil }
        heights = ids.enumerated().map { measured[$1] ?? estimates[$0] }
        recompute(from: 0)
    }

    /// 測った高さを捨てる（列の幅が替わった）
    public mutating func forgetMeasured() {
        measured = [:]
        heights = estimates
        recompute(from: 0)
    }

    /// 測った高さを控える。位置が変わったら true
    @discardableResult
    public mutating func setMeasured(_ id: String, _ height: Double) -> Bool {
        guard let index = indexes[id] else { return false }
        measured[id] = height
        guard heights[index] != height else { return false }
        heights[index] = height
        recompute(from: index)
        return true
    }

    public func isMeasured(_ id: String) -> Bool { measured[id] != nil }
    public func index(of id: String) -> Int? { indexes[id] }
    public func top(of index: Int) -> Double { tops[index] }
    public func height(of index: Int) -> Double { heights[index] }

    public var totalHeight: Double {
        guard let last = tops.last, let height = heights.last else { return topInset + bottomInset }
        return last + height + bottomInset
    }

    /// `range` に掛かる行。行の間だけに掛かる範囲は空
    public func rows(in range: ClosedRange<Double>) -> Range<Int> {
        let start = firstRow { tops[$0] + heights[$0] > range.lowerBound }
        let end = firstRow { tops[$0] > range.upperBound }
        return start..<max(start, end)
    }

    /// 表示の上端を控える形。`y` に掛かる行（行の間なら次の行）と、その行の上端からの位置
    public struct Anchor: Equatable, Sendable {
        public var id: String
        public var offset: Double

        public init(id: String, offset: Double) {
            self.id = id
            self.offset = offset
        }
    }

    public func anchor(at y: Double) -> Anchor? {
        let index = firstRow { tops[$0] + heights[$0] > y }
        guard index < ids.count else { return nil }
        return Anchor(id: ids[index], offset: y - tops[index])
    }

    /// 控えた行の今の位置に戻した上端。行が並びから消えていれば nil
    public func offset(for anchor: Anchor) -> Double? {
        indexes[anchor.id].map { tops[$0] + anchor.offset }
    }

    /// 条件を満たす最初の行（条件は行の順に偽から真へ一度だけ替わる）。無ければ行の数
    private func firstRow(where condition: (Int) -> Bool) -> Int {
        var low = 0
        var high = ids.count
        while low < high {
            let middle = (low + high) / 2
            if condition(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    private mutating func recompute(from index: Int) {
        if tops.count != heights.count { tops = Array(repeating: 0, count: heights.count) }
        var y = index == 0 ? topInset : tops[index - 1] + heights[index - 1] + spacing
        for position in index..<heights.count {
            tops[position] = y
            y += heights[position] + spacing
        }
    }
}
