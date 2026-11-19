import SwiftUI
import TaskboardKit

/// 入力欄に打ったコマンドが会話では使えないときの案内
struct ConversationUnsupportedBanner: View {
    let command: ConversationUnsupportedCommand
    let close: () -> Void

    var body: some View {
        Banner(kind: .notice, message: String(localized: "「/\(command.name)」は会話では使えません。"), onClose: close)
    }
}
