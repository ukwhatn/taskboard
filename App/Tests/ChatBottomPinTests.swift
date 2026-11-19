import Foundation
import Testing
@testable import Taskboard

/// チャットの下端への追従（`ChatBottomPin`）。表示の高さ 600、中身 2,000 で、下端は offset 1,400
@Suite struct ChatBottomPinTests {
    private func at(_ offset: CGFloat, content: CGFloat = 2000) -> ChatBottomPin.Position {
        ChatBottomPin.Position(offset: offset, contentHeight: content, viewportHeight: 600)
    }

    @Test("中身が一度に大きく伸びて下端から離れても、追従は外さない（ツールの行がまとめて届いたとき）")
    func contentGrowthKeepsPin() {
        #expect(ChatBottomPin.pinned(true, from: at(1400), to: at(1400, content: 3500), byUser: false))
        #expect(!ChatBottomPin.isAtBottom(at(1400, content: 3500), margin: ChatBottomPin.reattach))
    }

    @Test("人が上へ送ったら外し、下端まで戻したら付け直す（下端の手前では付けない）")
    func userScrollUnpinsAndBottomRepins() {
        #expect(!ChatBottomPin.pinned(true, from: at(1400), to: at(900), byUser: true))
        #expect(!ChatBottomPin.pinned(false, from: at(900), to: at(1200), byUser: true))
        #expect(!ChatBottomPin.pinned(false, from: at(1200), to: at(1290), byUser: true))
        #expect(ChatBottomPin.pinned(false, from: at(1290), to: at(1390), byUser: true))
        #expect(ChatBottomPin.pinned(false, from: at(1390), to: at(1400), byUser: true))
    }

    @Test("下端の近くで細かく上へ送っても、1 回目で外れ、続けて送る間も外れたまま（トラックパッドの細かい送りで下端へ引き戻されていた）")
    func smallScrollsNearBottomUnpin() {
        #expect(!ChatBottomPin.pinned(true, from: at(1400), to: at(1397), byUser: true))
        var pinned = false
        var offset: CGFloat = 1397
        for _ in 0..<20 {
            pinned = ChatBottomPin.pinned(pinned, from: at(offset), to: at(offset - 3), byUser: true)
            offset -= 3
        }
        #expect(!pinned)
    }

    @Test("人が動かしていない位置の変化では、下端の近くに来ても付け直さない（指を離した後に行の高さが直って位置が動いたとき）")
    func programmaticMoveNearBottomStaysUnpinned() {
        #expect(!ChatBottomPin.pinned(false, from: at(1340), to: at(1395), byUser: false))
        #expect(!ChatBottomPin.pinned(false, from: at(1340), to: at(1400), byUser: false))
    }

    @Test("下端の近くで中身が縮んで位置が上がっても、下端に居るなら付けたまま")
    func shrinkAtBottomKeepsPin() {
        #expect(ChatBottomPin.pinned(true, from: at(1400), to: at(1300, content: 1900), byUser: true))
    }

    @Test("中身の高さが変わると同時に位置が上がっても、人が動かしていなければ外さない（まとめて届いた行の高さの見積もりが直ったとき）")
    func estimateCorrectionKeepsPin() {
        #expect(ChatBottomPin.pinned(true, from: at(52_000, content: 60_000), to: at(48_000, content: 56_500), byUser: false))
    }

    @Test("中身の高さが変わらないまま位置が上がっても、人が動かしていなければ外さない（1,500 件を流し終えた後に SwiftUI が位置を 362 上げた）")
    func programmaticJumpKeepsPin() {
        let old = ChatBottomPin.Position(offset: 84_689, contentHeight: 85_195, viewportHeight: 494)
        let new = ChatBottomPin.Position(offset: 84_327, contentHeight: 85_195, viewportHeight: 494)
        #expect(ChatBottomPin.pinned(true, from: old, to: new, byUser: false))
    }

    @Test("人が動かしている間（スクロールの phase かホイール）は、中身の高さが変わっても上がれば外す")
    func userScrollWhileMeasuringUnpins() {
        #expect(!ChatBottomPin.pinned(true, from: at(1400), to: at(900, content: 2300), byUser: true))
    }

    @Test("下端に揃っているかは、下の余白の分までゆとりを見る（scrollTo(edge:) は余白の分だけ手前で止まる）")
    func atBottomAllowsMargin() {
        #expect(ChatBottomPin.isAtBottom(at(1400), margin: 12))
        #expect(ChatBottomPin.isAtBottom(at(1388), margin: 12))
        #expect(!ChatBottomPin.isAtBottom(at(1380), margin: 12))
    }

    @Test("外れている間に中身が伸びても、付け直さない")
    func growthWhileUnpinnedStaysUnpinned() {
        #expect(!ChatBottomPin.pinned(false, from: at(500), to: at(500, content: 4000), byUser: false))
    }

    @Test("UIKit の一覧の位置は、上下の inset（バー・キーボード・下の帯）を除いた見えている所で数える。下端に送った位置（中身 + 下の inset − 枠）で残りは 0")
    func scrollMetricsExcludeInsets() {
        // 枠 700、上のバー 100、キーボードと入力欄 300、中身 2,000。下端の contentOffset は 2,000 + 300 − 700 = 1,600
        let bottom = ChatBottomPin.Position(scrollOffset: 1600, contentHeight: 2000, boundsHeight: 700, insetTop: 100, insetBottom: 300)
        #expect(bottom.gap == 0)
        #expect(bottom.viewportHeight == 300)
        #expect(ChatBottomPin.isAtBottom(bottom, margin: 0))
        // 上端（contentOffset が −上の inset）は offset 0
        let top = ChatBottomPin.Position(scrollOffset: -100, contentHeight: 2000, boundsHeight: 700, insetTop: 100, insetBottom: 300)
        #expect(top.offset == 0)
        #expect(top.gap == 1700)
        // キーボードを閉じて下の inset が 34 に戻ると、同じ contentOffset は下端を越えた所（残り −266）。下端とみなす
        let closed = ChatBottomPin.Position(scrollOffset: 1600, contentHeight: 2000, boundsHeight: 700, insetTop: 100, insetBottom: 34)
        #expect(closed.gap == -266)
        #expect(ChatBottomPin.isAtBottom(closed, margin: 0))
    }

    @Test("UIKit の一覧の、下端に送る contentOffset。中身が枠より短いときは上端（−上の inset）")
    func bottomOffsetForScrollMetrics() {
        #expect(ChatBottomPin.bottomOffset(contentHeight: 2000, boundsHeight: 700, insetTop: 100, insetBottom: 300) == 1600)
        #expect(ChatBottomPin.bottomOffset(contentHeight: 200, boundsHeight: 700, insetTop: 100, insetBottom: 300) == -100)
    }
}
