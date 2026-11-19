import Foundation
import Testing
@testable import Taskboard

/// タスクのパネルの幅の判断
@Suite struct TaskPanelMetricsTests {
    @Test("ファイルの欄の場所: 詳細と並べたまま入らず、詳細を畳めば入る幅のときだけ畳む")
    func makesRoomForFile() {
        // 詳細 320 + セッション 480 に満たない幅は上下に重ねるので畳まない
        #expect(!TaskPanelMetrics.makesRoomForFile(width: 790))
        // 800: 詳細 320、セッション 480 では欄（360 + チャット 420）が入らず、全幅 800 なら入る
        #expect(TaskPanelMetrics.makesRoomForFile(width: 800))
        // 1,130: 詳細 406.8、セッション 723 では入らず、全幅なら入る
        #expect(TaskPanelMetrics.makesRoomForFile(width: 1_130))
        // 1,300: 詳細 440（上限）、セッション 860 で欄が入るので畳まない
        #expect(!TaskPanelMetrics.makesRoomForFile(width: 1_300))
    }

    @Test("右の欄のタブ: このタスクで選んだもの、前に選んだもの、文書 → 作業項目 → 状態の順")
    func sidePaneTab() {
        let all: (SidePanel) -> Bool = { _ in true }
        let none: (SidePanel) -> Bool = { $0 == .status }
        // このタスクで選んだタブは、中身が空でも出す
        #expect(SidePanel.shown(picked: .changes, preferred: .docs, filled: none) == .changes)
        // 前に選んだタブに中身があればそれ
        #expect(SidePanel.shown(picked: nil, preferred: .changes, filled: all) == .changes)
        #expect(SidePanel.shown(picked: nil, preferred: .status, filled: all) == .status)
        // 前に選んだタブが空なら、文書 → 作業項目 → 状態
        #expect(SidePanel.shown(picked: nil, preferred: .changes, filled: { $0 != .changes }) == .docs)
        #expect(SidePanel.shown(picked: nil, preferred: .docs, filled: { $0 == .work || $0 == .status }) == .work)
        #expect(SidePanel.shown(picked: nil, preferred: .work, filled: none) == .status)
    }
}
