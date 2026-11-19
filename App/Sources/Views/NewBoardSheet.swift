import SwiftUI
import TaskboardKit

/// 案件を追加する下書き。列は daemon の既定（列の編集は設定の案件の中）
struct NewBoardDraft: Identifiable, Hashable {
    var id = UUID()
    var machine: MachineID
    var name = ""
}

struct NewBoardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: NewBoardDraft
    /// 追加した案件を全体のボードで見せる。設定画面から追加するときは、設定に留まる（追加した案件を開く）
    var onCreated: ((Board) -> Void)?
    @State private var submitting = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let machines = machineChoices
        SheetScaffold(title: String(localized: "案件の追加"), error: error, onCancel: { dismiss() }) {
            Section {
                MachinePicker(label: String(localized: "Mac"), selection: $draft.machine, machines: machines)
                LabeledContentField(String(localized: "名前（必須）")) {
                    TextField("名前（必須）", text: $draft.name)
                        .focused($nameFocused)
                        .onSubmit(submit)
                }
            }
        } actions: {
            Button("追加", action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(submitting)
        }
        .onAppear { nameFocused = true }
        .onChange(of: draft.name) { _, _ in error = nil }
    }

    /// 書き込めるマシン（表示しているマシンと、開いたときのマシン）
    private var machineChoices: [MachineID] {
        var machines = model.writableMachines
        if !machines.contains(draft.machine) { machines.append(draft.machine) }
        return machines
    }

    private func submit() {
        guard !submitting else { return }
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = String(localized: "案件の名前を入力してください。")
            return
        }
        submitting = true
        error = nil
        Task {
            do {
                let board = try await model.createBoard(draft, reveal: onCreated == nil)
                onCreated?(board)
                dismiss()
            } catch {
                self.error = UserFacingError("案件を追加できませんでした", error: error)?.text
                submitting = false
            }
        }
    }
}
