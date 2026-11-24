import SwiftUI
import TaskboardKit

/// 会話のコードブロックの［実行］の口。会話の画面が `ChatTranscript` に渡し、`MarkdownView` のコードの塊が読む
struct CodeRunActions {
    /// 発言の id とコードの本文から、最後に始めた Run
    let entry: (_ messageID: String, _ code: String) -> ConversationRunStore.Entry?
    let start: (_ code: String, _ language: String, _ messageID: String) -> Void
    let cancel: (_ runID: String) -> Void
    /// 会話の Run のシェルを起こし直す（変数と作業フォルダの移動を捨てる）
    let reset: () -> Void
}

extension EnvironmentValues {
    @Entry var codeRun: CodeRunActions?
    /// 描いている発言の id（コードの塊の Run を発言に結ぶ）
    @Entry var codeRunMessageID: String?
}

/// コードの塊の下の Run の出力。状態と、動いている間の［停止］、終わった後の［シェルを再起動］、出力（長ければ枠の中で送る）、上限で切った印
struct CodeRunOutput: View {
    let entry: ConversationRunStore.Entry
    let font: Font
    let cancel: () -> Void
    let reset: () -> Void

    var body: some View {
        ChatOutlineCard {
            HStack(spacing: Space.row) {
                Label(statusLabel, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.caption)
                Spacer(minLength: 0)
                if entry.status == .running {
                    Button("停止", systemImage: "stop.fill", action: cancel)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("実行を停止")
                } else {
                    Button("シェルを再起動", systemImage: "arrow.counterclockwise", action: reset)
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("変数と作業フォルダを元に戻す")
                }
            }
            VStack(alignment: .leading, spacing: Space.inline) {
                if entry.newShell {
                    Text("新しいシェルで実行しました。前の実行の変数と作業フォルダは引き継いでいません。").font(.caption).foregroundStyle(ChatPalette.mutedText)
                }
                if !entry.text.isEmpty {
                    ScrollView {
                        Text(verbatim: entry.text)
                            .font(font)
                            .foregroundStyle(ChatPalette.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: ConversationMetrics.runOutputHeight)
                    .fixedSize(horizontal: false, vertical: true)
                } else if entry.status != .running {
                    Text("（出力はありません）").font(.caption).foregroundStyle(ChatPalette.mutedText)
                }
                if entry.truncated {
                    Text("先頭の1MBだけを表示しています。").font(.caption2).foregroundStyle(ChatPalette.mutedText)
                }
            }
        }
        .background(ChatPalette.raised, in: RoundedRectangle(cornerRadius: Radius.box, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("実行の結果")
    }

    private var statusLabel: String {
        RunStatusText.label(entry.status, exitCode: entry.exitCode)
    }

    private var statusSymbol: String {
        switch entry.status {
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .timedOut: "clock.badge.exclamationmark"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .running: ChatPalette.generating
        case .failed, .timedOut: ChatPalette.danger
        case .succeeded, .cancelled: ChatPalette.mutedText
        }
    }
}
