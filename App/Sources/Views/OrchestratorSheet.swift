import SwiftUI
import TaskboardKit

/// ⌘K の「オーケストレーターに指示…」。送り先のマシン（横並び）・本文・最後の返事・送った指示の直近 5 件。⌘↩ で送信。
/// 居なければ「起動」を出す（常駐がオンで起きていないときも）
struct OrchestratorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var machine: MachineID
    @State private var text = ""
    @State private var failure: UserFacingError?
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        let running = model.orchestratorConversation(on: machine) != nil
        let info = model.fleet.machineState(for: machine)?.orchestrator
        let row = model.orchestratorRow(on: machine)
        let history = model.orchestratorHistory[machine] ?? []
        let candidates = model.orchestratorCandidates
        SheetScaffold(title: String(localized: "オーケストレーターへのメッセージ"), subtitle: [model.machineName(machine), row?.statusLabel].compactMap { $0 }.joined(separator: "・"), error: failure?.text ?? row?.launchFailure, width: 560, onCancel: { dismiss() }) {
            if candidates.count > 1 {
                Section {
                    MachinePicker(label: String(localized: "送り先"), selection: Binding(get: { machine }, set: { select($0) }), machines: candidates)
                }
            }
            Section {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 120)
                    .focused($focused)
                    .accessibilityLabel("メッセージ")
            } header: {
                Text("メッセージ")
            } footer: {
                if row?.resident == false {
                    Text("送り先のMacでは、オーケストレーターの常駐がオフです。［設定］>［セッション］でオンにすると、停止しても自動で起動します。")
                } else {
                    Text("⌘↩で送信できます。応答は通知とオーケストレーターの画面に届きます。")
                }
            }
            if let reply = info?.lastReply {
                Section {
                    Text(reply.text)
                        .textRole(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                    if running {
                        Button("チャットを開く") {
                            dismiss()
                            model.navigate(to: .orchestrator(machine), from: .link)
                        }
                    }
                } header: {
                    HStack {
                        Text("最後の応答")
                        Spacer()
                        RelativeTime(date: reply.at)
                    }
                }
            }
            if !history.isEmpty {
                Section("送信したメッセージ") {
                    ForEach(history.suffix(5).reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Text(entry.sentAt, format: .dateTime.hour().minute()).textRole(.caption).monospacedDigit()
                            Text(entry.text).font(.callout).lineLimit(2)
                        }
                    }
                }
            }
        } actions: {
            if !running {
                // 居なければ、取れる操作は起動だけ。送信は起動した後
                Button("起動") { model.startOrchestrator(on: machine) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("送信", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!running || sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        #if os(macOS)
        .frame(minHeight: SheetMetrics.orchestratorHeight.lowerBound, maxHeight: SheetMetrics.orchestratorHeight.upperBound)
        #endif
        .onAppear { focused = true }
    }

    private func select(_ target: MachineID) {
        machine = target
        model.selectOrchestratorTarget(target)
        failure = nil
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        failure = nil
        Task {
            defer { sending = false }
            do {
                try await model.sendToOrchestrator(body, on: machine)
                dismiss()
            } catch {
                // 書いた指示は残す（docs/ui-copy.md「エラー」）
                failure = UserFacingError("メッセージを送信できませんでした", error: error)
            }
        }
    }
}
