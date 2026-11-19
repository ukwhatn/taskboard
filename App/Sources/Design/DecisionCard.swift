import SwiftUI

/// ［許可］に添えて選べる候補（メニュー）。選ぶと `decide(id)` で答える
struct DecisionAlways {
    struct Option: Identifiable {
        let id: String
        let label: String
    }

    let title: String
    let options: [Option]
    let decide: (String) async throws -> Void
}

/// 2 択で答えるカード（権限の確認・計画の承認）。題と中身、失敗の文、書き込めないときの文と［拒否］［許可］の並び。
/// 許可に「今後は聞かない」候補を添えられるときは、2 つのボタンの間にメニュー（［常に許可］）を置く。
/// 押している間はボタンを全部止め、失敗したらカードの中に出す
struct DecisionCard<Content: View>: View {
    struct Choice {
        let label: String
        /// 失敗したときの事象（「{操作}できませんでした」）
        let failure: LocalizedStringResource
    }

    let title: String
    let symbol: String
    let deny: Choice
    let allow: Choice
    /// 書き込めないときの文。あればボタンを押せない
    let blocked: UserFacingError?
    /// ［許可］に ⌘Y を付けるときの、ボタンのヘルプの文
    var allowShortcutHelp: String?
    var always: DecisionAlways?
    let decide: (Bool) async throws -> Void
    @ViewBuilder var content: Content

    @State private var sending = false
    @State private var failure: UserFacingError?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Label(title, systemImage: symbol).textRole(.sectionTitle).foregroundStyle(.orange)
            content
            if let failure { FailureText(failure) }
            if AppModel.isPhone {
                // 親指で押すので、ボタンを等幅で横いっぱいに並べ、書き込めないときの文は上の行に出す
                if let blocked { blockedText(blocked) }
                HStack(spacing: Space.row) { buttons(fill: true) }
                    .controlSize(.large)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    if let blocked { blockedText(blocked) }
                    Spacer(minLength: Space.row)
                    buttons(fill: false)
                }
            }
        }
        .attentionCard()
    }

    private func blockedText(_ blocked: UserFacingError) -> some View {
        Text(blocked.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func buttons(fill: Bool) -> some View {
        let denyButton = Button { send(allow: false) { try await decide(false) } } label: { label(deny.label, fill: fill) }
            .disabled(sending || blocked != nil)
        if fill { denyButton.buttonStyle(.bordered) } else { denyButton }
        if let always, !always.options.isEmpty {
            Menu {
                ForEach(always.options) { option in
                    Button(option.label) { send(allow: true) { try await always.decide(option.id) } }
                }
            } label: {
                label(always.title, fill: fill)
            }
            .menuIndicator(.visible)
            .fixedSize(horizontal: !fill, vertical: false)
            .disabled(sending || blocked != nil)
        }
        if let allowShortcutHelp {
            allowButton(fill: fill)
                .keyboardShortcut("y", modifiers: .command)
                .help(allowShortcutHelp)
        } else {
            allowButton(fill: fill)
        }
    }

    private func label(_ text: String, fill: Bool) -> some View {
        Text(text).frame(maxWidth: fill ? .infinity : nil)
    }

    private func allowButton(fill: Bool) -> some View {
        Button { send(allow: true) { try await decide(true) } } label: { label(allow.label, fill: fill) }
            .buttonStyle(.borderedProminent)
            .disabled(sending || blocked != nil)
    }

    private func send(allow allowed: Bool, _ action: @escaping () async throws -> Void) {
        sending = true
        failure = nil
        Task {
            do {
                try await action()
            } catch {
                failure = UserFacingError(allowed ? allow.failure : deny.failure, error: error)
            }
            sending = false
        }
    }
}
