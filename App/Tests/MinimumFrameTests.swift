#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Taskboard

/// 窓の根と分割の列の根の最小の大きさ（`MinimumFrame`）。窓と列の最小の大きさを求めるたびに中身を測り直さないことを見る
@MainActor
@Suite struct MinimumFrameTests {
    /// 大きさを聞かれた提案を数える中身
    private final class Probe: @unchecked Sendable {
        var proposals: [ProposedViewSize] = []
    }

    private struct ProbeLayout: Layout {
        let probe: Probe
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            probe.proposals.append(proposal)
            return CGSize(width: 900, height: 700)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
    }

    @Test("窓の最小の大きさは決めた値で、中身には 0 や未指定の提案で大きさを聞かない")
    func minimumWithoutMeasuringContent() {
        let probe = Probe()
        let view = NSHostingView(rootView: ProbeLayout(probe: probe) { Color.clear }.windowMinimum(CGSize(width: 640, height: 480)))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        view.layoutSubtreeIfNeeded()
        probe.proposals.removeAll()
        #expect(view.fittingSize == CGSize(width: 640, height: 480))
        view.invalidateIntrinsicContentSize()
        view.needsUpdateConstraints = true
        view.updateConstraintsForSubtreeIfNeeded()
        let measuredSmall = probe.proposals.filter { ($0.width ?? 0) < 640 || ($0.height ?? 0) < 480 }
        #expect(measuredSmall.isEmpty, "最小の大きさを求めるのに中身を測った: \(measuredSmall)")
    }

    @Test("中身は窓の大きさに合わせて置く")
    func placesContentInBounds() {
        let probe = Probe()
        let view = NSHostingView(rootView: ProbeLayout(probe: probe) { Color.clear }.windowMinimum(CGSize(width: 640, height: 480)))
        view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        view.layoutSubtreeIfNeeded()
        #expect(probe.proposals.contains { $0.width == 1000 && $0.height == 800 })
    }
}
#endif
