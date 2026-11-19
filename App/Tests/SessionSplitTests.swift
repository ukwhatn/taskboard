import AppKit
import SwiftUI
import Testing
@testable import Taskboard

@MainActor
@Suite struct SessionSplitTests {
    /// 受けた大きさの提案を控える入れ物（セッションの欄の代わり）
    private final class Proposals {
        var seen: [ProposedViewSize] = []
    }

    private struct Recording: Layout {
        let proposals: Proposals

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposals.seen.append(proposal)
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }

    private func lay(_ view: some View, size: CGSize) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
    }

    @Test("セッションの欄には、置いた大きさの提案だけを渡す（幅 0 や無限で伸び方を調べない）。左右なら右の欄の幅と境目の残り、上下なら右の欄が残りの半分と上限の低い方まで")
    func proposesOnlyPlacedSize() {
        let sideBySide = Proposals()
        lay(
            SessionSplit(sideBySide: true, sideWidth: 300, stackedMaxHeight: nil) {
                Recording(proposals: sideBySide) { EmptyView() }
                SplitDivider(vertical: true)
                Color.clear
            }, size: CGSize(width: 1000, height: 600))
        #expect(!sideBySide.seen.isEmpty)
        #expect(sideBySide.seen.allSatisfy { $0 == ProposedViewSize(width: 699, height: 600) }, "\(sideBySide.seen)")

        let stacked = Proposals()
        lay(
            SessionSplit(sideBySide: false, sideWidth: 300, stackedMaxHeight: 200) {
                Recording(proposals: stacked) { EmptyView() }
                SplitDivider(vertical: false)
                Color.clear
            }, size: CGSize(width: 600, height: 801))
        // 右の欄（伸びる）は残りの半分 400 と上限 200 の低い方の 200、境目 1、セッションの欄は 600
        #expect(!stacked.seen.isEmpty)
        #expect(stacked.seen.allSatisfy { $0 == ProposedViewSize(width: 600, height: 600) }, "\(stacked.seen)")
    }
}
