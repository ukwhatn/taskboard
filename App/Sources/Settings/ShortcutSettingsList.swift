import SwiftUI

// MARK: - ショートカット

/// 設定の［ショートカット］。⌘/ のオーバーレイと同じ一覧（`ShortcutList`）を、場面を問わず全部出す
struct ShortcutSettingsList: View {
    var body: some View {
        Form {
            ShortcutList(sections: ShortcutCatalog.sections(taskOpen: true, sessionOpen: true, conversationOpen: true))
        }
        .formStyle(.grouped)
    }
}
