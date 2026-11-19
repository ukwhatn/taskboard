import Testing
@testable import TaskboardKit

@Suite struct RowHeightsTests {
    /// 上の余白 10、下の余白 20、行の間 5。行 a・b・c の見積もりは 100・50・30
    private func sample() -> RowHeights {
        var heights = RowHeights(spacing: 5, topInset: 10, bottomInset: 20)
        heights.setRows(["a", "b", "c"], estimates: [100, 50, 30])
        return heights
    }

    @Test("位置は上の余白から行の高さと間を足した所で、全体は下の余白まで。測っていない行は見積もりで数える")
    func positions() {
        let heights = sample()
        #expect(heights.top(of: 0) == 10)
        #expect(heights.top(of: 1) == 115)
        #expect(heights.top(of: 2) == 170)
        #expect(heights.totalHeight == 220)
        #expect(!heights.isMeasured("b"))
    }

    @Test("測った高さで後ろの行の位置が動き、並びを替えても同じ id の測った高さは残る。幅が替わったら測った高さを捨てる")
    func measured() {
        var heights = sample()
        let moved = heights.setMeasured("b", 80)
        let again = heights.setMeasured("b", 80)
        #expect(moved)
        #expect(!again, "同じ高さなら変わらない")
        #expect(heights.top(of: 2) == 200)
        #expect(heights.totalHeight == 250)
        // 上に古いページが足された
        heights.setRows(["z", "a", "b", "c"], estimates: [40, 100, 50, 30])
        #expect(heights.isMeasured("b"))
        #expect(heights.height(of: 2) == 80)
        #expect(heights.top(of: 1) == 55)
        heights.forgetMeasured()
        #expect(!heights.isMeasured("b"))
        #expect(heights.height(of: 2) == 50)
    }

    @Test("範囲に掛かる行を返す（間だけに掛かる範囲は次の行から）。範囲が中身の外なら空")
    func rowsInRange() {
        let heights = sample()
        #expect(heights.rows(in: 0...12) == 0..<1)
        #expect(heights.rows(in: 111...112) == 1..<1)
        #expect(heights.rows(in: 100...120) == 0..<2)
        #expect(heights.rows(in: 160...400) == 1..<3)
        #expect(heights.rows(in: 300...400) == 3..<3)
        #expect(RowHeights(spacing: 5, topInset: 10, bottomInset: 20).rows(in: 0...100) == 0..<0)
    }

    @Test("表示の上端を、そこに掛かる行とその行の中の位置で控え、上の行の高さが変わったり上に行が足されても、同じ行の同じ所に戻す")
    func anchor() throws {
        var heights = sample()
        let anchor = try #require(heights.anchor(at: 130))
        #expect(anchor == RowHeights.Anchor(id: "b", offset: 15))
        heights.setMeasured("a", 160)
        #expect(heights.offset(for: anchor) == 190)
        heights.setRows(["z", "a", "b", "c"], estimates: [40, 100, 50, 30])
        #expect(heights.offset(for: anchor) == 235)
        // 行の間に掛かるときは次の行の上端からの負の位置
        #expect(heights.anchor(at: 52) == RowHeights.Anchor(id: "a", offset: -3))
        // 消えた行は戻せない
        heights.setRows(["c"], estimates: [30])
        #expect(heights.offset(for: anchor) == nil)
    }
}
