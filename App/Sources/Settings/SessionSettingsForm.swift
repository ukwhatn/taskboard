import SwiftUI
import TaskboardKit

/// 設定の「セッション」。マシンごとに、オーケストレーターの常駐と、操作のないセッションを終了するまでの時間。変えたらすぐ送る
struct SessionSettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // 非表示にしたマシンも設定できるよう、全マシンから書き込めるものを選ぶ
        let machines = model.settingsMachines
        if machines.isEmpty {
            NoWritableMachine()
        } else {
            Form {
                ForEach(Array(machines.enumerated()), id: \.element.fleetID) { index, scope in
                    MachineSessionSection(
                        machine: scope.machine, name: model.machineName(fleetID: scope.fleetID, state: scope.state), state: scope.state,
                        showsName: machines.count > 1, isLast: index == machines.count - 1)
                }
            }
            .formStyle(.grouped)
            .settingsContentWidth()
        }
    }
}

private struct MachineSessionSection: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    let name: String
    let state: MachineState
    let showsName: Bool
    let isLast: Bool
    /// 押した値。daemon から同じ値が届くまで出しておき、失敗したら消して元の値に戻す
    @State private var pendingEnabled = PendingValue<Bool>()
    @State private var pendingIdle = PendingValue<Int>()
    @State private var pendingArgs = PendingValue<[String]>()

    var body: some View {
        if let settings = state.settings {
            Section {
                Toggle("オーケストレーターを常駐させる", isOn: .pending($pendingEnabled, current: settings.orchestrator.enabled) { value in
                    await model.saveSettings(on: machine, MachineSettingsUpdate(orchestratorEnabled: value))
                })
                if pendingEnabled.shown(settings.orchestrator.enabled) {
                    // 起動と同じ、モデルと effort の横並び。引数が形に合わなければ「カスタムの引数」として出し、選び直すまで変えない
                    let args = Binding<[String]>.pending($pendingArgs, current: settings.orchestrator.agentArgs) { args in
                        await model.saveSettings(on: machine, MachineSettingsUpdate(orchestratorAgentArgs: args))
                    }
                    LaunchChoiceFields(
                        choice: Binding(get: { LaunchChoice(kind: .claude, args: args.wrappedValue) }, set: { args.wrappedValue = $0.args }),
                        machine: machine, agents: [.claude])
                    let row = model.orchestratorRow(on: machine)
                    if let row { LabeledContent("状態", value: row.statusLabel) }
                    if let failure = row?.launchFailure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
                LabeledSegmentedPicker(String(localized: "操作のないセッションを終了するまで"), selection: .pending($pendingIdle, current: settings.idleStopMinutes) { value in
                    await model.saveSettings(on: machine, MachineSettingsUpdate(idleStopMinutes: value))
                }) {
                    ForEach(MachineSettings.idleStopChoices, id: \.self) { Text(Self.idleLabel($0)).tag($0) }
                }
            } header: {
                if showsName { Text(name) }
            } footer: {
                if isLast {
                    Text("終了したセッションは、タスクの［再開］で続けられます。Remote Controlを使うMacでは［終了しない］を選んでください。")
                }
            }
            .onChange(of: settings.orchestrator.enabled) { _, _ in pendingEnabled.settle() }
            .onChange(of: settings.orchestrator.agentArgs) { _, _ in pendingArgs.settle() }
            .onChange(of: settings.idleStopMinutes) { _, _ in pendingIdle.settle() }
        } else {
            Section {
                Text("接続先のMacのTaskboardが古いため、設定できません。Taskboardを更新してください。")
                    .foregroundStyle(.secondary)
            } header: {
                if showsName { Text(name) }
            }
        }
    }

    static func idleLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: String(localized: "終了しない")
        case let m where m % 60 == 0: String(localized: "\(m / 60)時間")
        default: String(localized: "\(minutes)分")
        }
    }
}
