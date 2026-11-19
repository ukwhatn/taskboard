import SwiftUI
import TaskboardKit

/// 入力欄の上に出す、生成中に送って待機中の発言（待ち行列を持つ engine だけ）。見出しに件数と次に渡る発言の 1 行目、
/// 開くと発言ごとに［取り消す］［編集］（文を入力欄に戻す）［今すぐ送信］
struct ConversationQueueCard: View {
    let messages: [ConversationTimeline.Outgoing]
    let fonts: ChatFonts
    let sendNow: (String) async throws -> ConversationSendNow
    /// 押すと実行中のツールを裏に回して渡す（`Conversation.detachableTools`）。無ければ生成を止めて渡す
    let detachesTools: Bool
    /// 待ち行列から外す。`edit` なら文を入力欄に戻す。外せなかった（もう渡っていた）ら false
    let cancel: (_ id: String, _ edit: Bool) async throws -> Bool
    /// 生成を停止した後で engine が待ち行列を始めない（`Conversation.queuePaused`）。［送信を再開］で先頭を送る
    var paused = false
    /// 書き込めない接続先では押せない
    let canSend: Bool
    let failed: (UserFacingError) -> Void
    @State private var open = true
    /// ［今すぐ送信］を押して応答を待っている発言と、区切りで渡すと返った発言
    @State private var requested: [String: ConversationSendNow?] = [:]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ChatRowHeader(open: open, fonts: fonts, toggle: { open.toggle() }) { hovering in
                Text("待機中のメッセージ（\(messages.count)件）").font(fonts.subheadline.weight(.medium))
                if !open, let next = messages.first {
                    Text("次：\(Self.firstLine(next.text))").font(fonts.subheadline)
                        .foregroundStyle(hovering ? ChatPalette.secondaryText : ChatPalette.mutedText).lineLimit(1)
                }
            }
            .padding(.horizontal, ChatMetrics.bubblePadding.width)
            .frame(minHeight: ChatMetrics.queueHeader)
            if paused, let next = messages.first {
                Rectangle().fill(ChatPalette.border).frame(height: 1)
                pausedRow(next)
            }
            if open {
                ForEach(messages) { message in
                    Rectangle().fill(ChatPalette.border).frame(height: 1)
                    row(message)
                }
            }
        }
        .background(ChatPalette.fill, in: shape)
        .onChange(of: messages.map(\.id)) { _, ids in requested = requested.filter { ids.contains($0.key) } }
    }

    private func row(_ message: ConversationTimeline.Outgoing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            VStack(alignment: .leading, spacing: 0) {
                Text(message.text.isEmpty ? String(localized: "画像\(message.attachmentCount)枚") : message.text)
                    .font(fonts.body).foregroundStyle(ChatPalette.text).lineLimit(2)
                if message.later {
                    Text("応答が終わってから送信").font(fonts.caption).foregroundStyle(ChatPalette.mutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch requested[message.id] {
            case .some(.some(let result)) where result.outcome != .nothingWaiting:
                Text(Self.sentNote(result)).font(fonts.caption).foregroundStyle(ChatPalette.mutedText)
            case .some(.some), .some(.none):
                ProgressView().controlSize(.small)
            case .none where AppModel.isPhone:
                // 小さい印を 3 つ並べると指で押し分けられないので、文字のメニューにまとめる
                Menu {
                    Button("今すぐ送信", systemImage: "arrow.turn.down.left") { send(message.id) }
                    Button("入力欄に戻して編集", systemImage: "pencil") { cancel(message.id, edit: true) }
                    Button("取り消す", systemImage: "xmark", role: .destructive) { cancel(message.id, edit: false) }
                } label: {
                    Image(systemName: "ellipsis").hitTarget()
                }
                .accessibilityLabel("待機中のメッセージの操作")
                .foregroundStyle(ChatPalette.secondaryText)
                .disabled(!canSend)
            case .none:
                HStack(spacing: Space.row) {
                    Button("取り消す", systemImage: "xmark") { cancel(message.id, edit: false) }
                        .labelStyle(.iconOnly)
                        .help("取り消す")
                    Button("編集", systemImage: "pencil") { cancel(message.id, edit: true) }
                        .labelStyle(.iconOnly)
                        .help("入力欄に戻して編集")
                    Button("今すぐ送信", systemImage: "arrow.turn.down.left") { send(message.id) }
                        .labelStyle(.titleAndIcon)
                        .help(
                            detachesTools
                                ? String(localized: "実行中のツールをバックグラウンドに移動して、すぐに送信します") : String(localized: "生成を停止して、すぐに送信します"))
                }
                .buttonStyle(.borderless)
                .font(fonts.caption)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, ChatMetrics.bubblePadding.width)
        .padding(.vertical, ChatMetrics.bubblePadding.height)
    }

    private func pausedRow(_ next: ConversationTimeline.Outgoing) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            Text("生成を停止したため、自動では送信しません。").font(fonts.caption).foregroundStyle(ChatPalette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("送信を再開", systemImage: "play") { send(next.id) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderless)
                .font(fonts.caption)
                .help("先頭のメッセージを送信します")
                .disabled(!canSend || requested[next.id] != nil)
        }
        .padding(.horizontal, ChatMetrics.bubblePadding.width)
        .padding(.vertical, ChatMetrics.bubblePadding.height)
    }

    private func send(_ id: String) {
        requested[id] = .some(nil)
        Task {
            do {
                requested[id] = .some(try await sendNow(id))
            } catch {
                requested[id] = nil
                if let failure = UserFacingError("今すぐ送信できませんでした", error: error) { failed(failure) }
            }
        }
    }

    private func cancel(_ id: String, edit: Bool) {
        requested[id] = .some(nil)
        Task {
            do {
                if !(try await cancel(id, edit)) {
                    failed(edit ? UserFacingError("編集できませんでした", cause: String(localized: "もう送信されています")) : UserFacingError("取り消せませんでした", cause: String(localized: "もう送信されています")))
                }
            } catch {
                if let failure = UserFacingError(edit ? "編集できませんでした" : "取り消せませんでした", error: error) { failed(failure) }
            }
            requested[id] = nil
        }
    }

    private static func sentNote(_ result: ConversationSendNow) -> LocalizedStringKey {
        if result.backgrounded == true { return "ツールをバックグラウンドに移動しました" }
        return result.outcome == .stopped ? "生成を停止しました" : "まもなく送信します"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
