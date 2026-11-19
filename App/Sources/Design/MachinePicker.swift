import SwiftUI
import TaskboardKit

/// マシンの選択。5 台までは横並び、6 台からはメニュー、1 台なら名前だけを出す（docs/ui-system.md「選択の形」）
struct MachinePicker: View {
    @Environment(AppModel.self) private var model
    let label: String
    @Binding var selection: MachineID
    let machines: [MachineID]

    enum Form: Equatable { case name, segmented, menu }

    static func form(count: Int) -> Form {
        switch count {
        case ...1: .name
        case 2...5: .segmented
        default: .menu
        }
    }

    var body: some View {
        switch Self.form(count: machines.count) {
        case .menu: Picker(label, selection: $selection) { options }
        case .segmented: LabeledSegmentedPicker(label, selection: $selection) { options }
        case .name: LabeledContent(label) { MachineName(machine: selection) }
        }
    }

    private var options: some View {
        ForEach(machines, id: \.self) { Text(verbatim: model.machineName($0)).tag($0) }
    }
}
