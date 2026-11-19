import CoreGraphics
import Foundation
import Testing
@testable import Taskboard

/// タスク画面の右側の欄の組と並べ方
@Suite struct SidePanelTests {
    @Test("初めは差分だけを開く。人が選んだ組はそのまま（並びは状態・文書・作業項目・差分）")
    func shownPanels() {
        #expect(SidePanelSet().shown == [.changes])
        #expect(SidePanelSet(open: [.changes, .status]).shown == [.status, .changes])
        #expect(SidePanelSet(open: []).shown == [])
    }

    @Test("押すと開け閉めし、知らせは閉じていれば開くだけ")
    func toggleAndReveal() {
        var set = SidePanelSet()
        set.toggle(.status, current: [.changes])
        #expect(set.open == [.changes, .status])
        set.toggle(.changes, current: [.status, .changes])
        #expect(set.open == [.status])
        set.reveal(.status, current: [.status])
        #expect(set.open == [.status])
        set.reveal(.docs, current: [.status])
        #expect(set.open == [.status, .docs])
    }

    @Test("組は JSON でこの端末に残し、読めない値は初めの組に戻す")
    func storage() {
        var set = SidePanelSet(open: [.docs, .changes])
        set.column = 0.4
        set.weights[.docs] = 1.5
        #expect(SidePanelSet(json: set.json) == set)
        #expect(SidePanelSet(json: "") == SidePanelSet())
        #expect(SidePanelSet(json: "{\"open\":[\"info\"]}") == SidePanelSet())
        // 端末を欄にしていた版の組（端末の重みを持つ）も初めの組に戻す
        #expect(SidePanelSet(json: "{\"open\":[\"status\"],\"weights\":[\"terminal\",1],\"column\":0.5}") == SidePanelSet())
    }

    @Test("1 つなら全部、2 つなら上下、3 つ以上は幅があれば 2 列（左に多い方）、狭ければ 1 列")
    func arrangement() {
        let size = CGSize(width: 800, height: 601)
        let gap = SidePanelMetrics.divider
        #expect(SidePanelArrangement.frames(of: [.docs], in: size, set: SidePanelSet()) == [CGRect(x: 0, y: 0, width: 800, height: 601)])
        #expect(SidePanelArrangement.frames(of: [.docs, .work], in: size, set: SidePanelSet()) == [
            CGRect(x: 0, y: 0, width: 800, height: 300), CGRect(x: 0, y: 300 + gap, width: 800, height: 300),
        ])
        let three = SidePanelArrangement.frames(of: [.status, .docs, .work], in: size, set: SidePanelSet())
        let half = (800 - gap) / 2
        #expect(three == [
            CGRect(x: 0, y: 0, width: half, height: 300), CGRect(x: 0, y: 300 + gap, width: half, height: 300),
            CGRect(x: half + gap, y: 0, width: half, height: 601),
        ])
        let narrow = SidePanelArrangement.frames(of: [.status, .docs, .work], in: CGSize(width: 400, height: 602), set: SidePanelSet())
        #expect(narrow.map(\.width) == [400, 400, 400])
        #expect(narrow.map(\.height) == [200, 200, 200])
    }

    @Test("高さは重みで分け、列の幅は割合で分ける（列の最小の幅より狭くしない）")
    func weightsAndColumn() {
        var set = SidePanelSet()
        set.weights[.docs] = 3
        set.column = 0.4
        let size = CGSize(width: 801, height: 401)
        let frames = SidePanelArrangement.frames(of: [.docs, .work], in: size, set: set)
        #expect(frames.map(\.height) == [300, 100])
        let grid = SidePanelArrangement.frames(of: [.status, .docs, .work], in: CGSize(width: 801, height: 401), set: set)
        #expect(grid[0].width == 320)
        #expect(grid[2].minX == 321)
        #expect(grid[2].width == 480)
        // 狭い窓では列の最小の幅で止める
        set.column = 0.1
        #expect(SidePanelArrangement.frames(of: [.status, .docs, .work], in: CGSize(width: 801, height: 401), set: set)[0].width == SidePanelMetrics.minColumnWidth)
    }

    @Test("境目を動かすと、隣どうしの重みを高さに合わせて付け替え、最小の高さと幅で止める")
    func resizing() {
        let size = CGSize(width: 400, height: 601)
        var set = SidePanelSet()
        // 高さ 300 と 300 の境目を 100 下げる → 400 と 200
        set.resize(.docs, .work, panels: [.docs, .work], in: size, by: 100)
        #expect(set.weights[.docs] == 4.0 / 3)
        #expect(set.weights[.work] == 2.0 / 3)
        // 下の欄は最小の高さで止まる
        set.resize(.docs, .work, panels: [.docs, .work], in: size, by: 500)
        #expect(abs(SidePanelArrangement.frames(of: [.docs, .work], in: size, set: set)[1].height - SidePanelMetrics.minHeight) < 0.001)
        set.resizeColumn(panels: [.status, .docs, .work], in: CGSize(width: 801, height: 401), by: -1_000)
        // 左の列は最小の幅（300）で止まる。格子の幅 801 から境目の線を引いた 800 に対する割合
        #expect(set.column == 0.375)
    }

    @Test("ドラッグの間、動かし始めの組に始めからの移動量を当てると、境目は移動量の分だけ動く（カーソルより先へ走らない）")
    func draggingFollowsCursor() {
        let panels: [SidePanel] = [.status, .docs, .work]
        let tall = CGSize(width: 400, height: 1_202)
        let start = SidePanelSet()
        let startTop = SidePanelArrangement.frames(of: panels, in: tall, set: start)[0].height
        for delta in stride(from: CGFloat(10), through: 150, by: 10) {
            var next = start
            next.resize(.status, .docs, panels: panels, in: tall, by: delta)
            #expect(abs(SidePanelArrangement.frames(of: panels, in: tall, set: next)[0].height - (startTop + delta)) < 0.001)
        }
        let wide = CGSize(width: 1_001, height: 600)
        let startLeft = SidePanelArrangement.frames(of: panels, in: wide, set: start)[0].width
        for delta in stride(from: CGFloat(-60), through: 60, by: 20) {
            var next = start
            next.resizeColumn(panels: panels, in: wide, by: delta)
            #expect(abs(SidePanelArrangement.frames(of: panels, in: wide, set: next)[0].width - (startLeft + delta)) < 0.001)
        }
    }
}
