import SwiftUI
import TaskboardKit

/// 会話の作業フォルダのシェルを、会話の画面の上に重ねて出す。閉じてもシェルは残る（もう一度開くと同じシェル）
struct ConversationTerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: TerminalKey

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.row) {
                Text("作業フォルダのシェル").font(.headline)
                Spacer(minLength: Space.row)
                Button("閉じる", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("閉じる")
            }
            .padding(.horizontal, Space.block)
            .padding(.vertical, Space.row)
            Divider()
            if let source = model.fleet.terminalSource(for: key.machine) {
                TerminalPane(key: key, source: source) { dismiss() }
            } else {
                EmptyState("ターミナルを表示できません", symbol: "terminal", message: "この接続先は表示用のデータです。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(macOS)
        .frame(
            minWidth: ConversationMetrics.terminalSheet.width, idealWidth: ConversationMetrics.terminalSheetIdeal.width,
            minHeight: ConversationMetrics.terminalSheet.height, idealHeight: ConversationMetrics.terminalSheetIdeal.height)
        #endif
    }
}
