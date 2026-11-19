import SwiftUI
import TaskboardKit

/// 権限の確認の中身（ツール・説明・コマンドかパス）
struct ModPermissionSummary: View {
    let permission: RequestWaiting.Permission

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            Label(permission.tool, systemImage: "lock.shield").font(.callout.weight(.medium))
            if let detail = permission.detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(permission.summary)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 会話の権限の確認のカード
struct PermissionPanel: View {
    let permission: RequestWaiting.Permission
    let blocked: UserFacingError?
    /// host の会話の確認で、CLI が出した「今後は聞かない」候補。選ぶと許可に添えて答える
    var suggestions: [PermissionSuggestion] = []
    var decideRemembered: ((PermissionSuggestion) async throws -> Void)?
    let decide: (Bool) async throws -> Void

    var body: some View {
        DecisionCard(
            title: String(localized: "権限の確認"), symbol: "hand.raised",
            deny: .init(label: String(localized: "拒否"), failure: "拒否できませんでした"),
            allow: .init(label: String(localized: "許可"), failure: "許可できませんでした"),
            blocked: blocked, allowShortcutHelp: String(localized: "この確認を許可（⌘Y）"), always: always, decide: decide
        ) {
            ModPermissionSummary(permission: permission)
        }
    }

    private var always: DecisionAlways? {
        let shown = PermissionSuggestion.shown(suggestions)
        guard let decideRemembered, !shown.isEmpty else { return nil }
        return .init(
            title: String(localized: "常に許可"), options: shown.map { .init(id: $0.id, label: $0.menuLabel) },
            decide: { id in
                guard let chosen = shown.first(where: { $0.id == id }) else { return }
                try await decideRemembered(chosen)
            })
    }
}

extension PermissionSuggestion {
    /// メニューの 1 行。何を許可し、どこに残すか
    var menuLabel: String {
        let target: String
        switch kind {
        case .rule, .unknown: target = String(localized: "\(subject)を許可")
        case .directory: target = String(localized: "\(subject)へのアクセスを許可")
        case .mode: target = String(localized: "権限を「\(ConversationChoices.permissionLabel(subject))」に変更")
        }
        switch scope {
        case .session, .unknown: return String(localized: "\(target)（この会話の間）")
        case .folder: return String(localized: "\(target)（このフォルダの設定に保存）")
        case .project: return String(localized: "\(target)（プロジェクトの設定に保存）")
        case .user: return String(localized: "\(target)（すべてのプロジェクトで）")
        }
    }
}
