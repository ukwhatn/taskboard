import Testing
@testable import Taskboard

/// マシンの選び方（docs/ui-system.md「選択の形」）。案件の追加・定期起動のフォーム・オーケストレーターへの指示が同じ形にする
@Suite struct MachinePickerTests {
    @Test("1 台なら名前だけ、2〜5 台は横並び、6 台からはメニュー")
    func forms() {
        #expect(MachinePicker.form(count: 0) == .name)
        #expect(MachinePicker.form(count: 1) == .name)
        #expect(MachinePicker.form(count: 2) == .segmented)
        #expect(MachinePicker.form(count: 5) == .segmented)
        #expect(MachinePicker.form(count: 6) == .menu)
        #expect(MachinePicker.form(count: 12) == .menu)
    }
}
