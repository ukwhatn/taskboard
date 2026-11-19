import SwiftUI
import TaskboardKit

/// ［アカウント］の子メニュー。今のアカウントに印を付け、選ぶとそのアカウントに替える。アカウントが無いマシンでは出さない
struct ClaudeAccountMenu: View {
    let accounts: [String]
    /// nil はマシンのログイン
    let current: String?
    let select: (String) -> Void

    var body: some View {
        if !accounts.isEmpty {
            Menu("アカウント", systemImage: "person.crop.circle") {
                item(ClaudeAccountLabel.login, value: ClaudeAccount.login, selected: current == nil)
                ForEach(accounts, id: \.self) { item($0, value: $0, selected: current == $0) }
            }
        }
    }

    @ViewBuilder
    private func item(_ label: String, value: String, selected: Bool) -> some View {
        if selected {
            Button(label, systemImage: "checkmark") {}
        } else {
            Button(label) { select(value) }
        }
    }
}

enum ClaudeAccountLabel {
    static var login: String { String(localized: "ログイン中のアカウント") }

    /// セッションの情報に出す名前。nil はマシンのログイン
    static func name(_ account: String?) -> String { account ?? login }
}

/// タスクの行の［すべて終了］の確認（`AppModel.requestEndAll`）。作業の途中のものの名前を出す
struct TaskEndAllDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window

    func body(content: Content) -> some View {
        let task = model.confirmation(in: window).flatMap { if case .endTaskSessions(let key) = $0 { model.fleet.task(for: key) } else { nil } }
        content.confirmationDialog(
            "セッションの終了", isPresented: Binding(get: { task != nil }, set: { if !$0 { model.dismissConfirmation(in: window) } }),
            titleVisibility: .visible, presenting: task
        ) { _ in
            Button("すべて終了", role: .destructive) { model.confirm(in: window) }
            Button("キャンセル", role: .cancel) {}
        } message: { task in
            Text(model.endTargets(of: task).message(task: task))
        }
    }
}
