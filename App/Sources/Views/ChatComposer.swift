import SwiftUI
import TaskboardKit

/// 会話の入力欄。左端の操作（`leading`。会話の［ファイルを添付］、iPhone は＋のメニュー）、文の欄、送信。
/// 生成中の［生成を停止］のように画面ごとに足すボタンは `accessory` に渡す（送信の左に並ぶ）。
/// `stop` があれば、送れる文が無い間は送信の場所に［生成を停止］を出す（iPhone。送信と停止を 1 つの場所にして文の幅を取る）。
/// iPhone・iPad の画像は、文の欄の長押しの［ペースト］で受ける（`canAttach` の間）。
/// `tentative` は音声入力の確定前の文で、文の欄の下に薄い色で出す（入力欄の文には入れないので、送信や打鍵で混ざらない）
struct ChatComposer<Leading: View, Accessory: View>: View {
    @Binding var draft: String
    @Binding var selection: TextSelection?
    var focused: FocusState<Bool>.Binding
    let canAttach: Bool
    let canSend: Bool
    let addImages: @MainActor @Sendable ([Data]) -> Void
    let send: () -> Void
    /// `/` の候補が出ている間のキー（`SlashCommandKeys`）。使ったら true
    let commandKey: (KeyEquivalent, EventModifiers) -> Bool
    /// 長い貼り付けの受け口（会話だけ。nil なら入力欄に入れる）
    var pasteLong: ((String) -> Void)?
    var stop: ChatComposerStop?
    var tentative: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var accessory: Accessory

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ChatComposer")
        #endif
        let shape = RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
        HStack(alignment: .bottom, spacing: Space.inline) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                field
                    .frame(minHeight: HitTarget.size)
                    .focused(focused)
                if let tentative, !tentative.isEmpty {
                    Text(tentative)
                        .foregroundStyle(ChatPalette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, Space.inline / 2)
                        .accessibilityLabel(Text("聞き取り中：\(tentative)"))
                }
            }
            .padding(.horizontal, Space.inline / 2)
            accessory
            if let stop, !canSend {
                Button(action: stop.action) {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(stop.enabled ? ChatPalette.text : ChatPalette.fillStronger)
                .disabled(!stop.enabled)
                .hitTarget()
                .accessibilityLabel("生成を停止")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? ChatPalette.text : ChatPalette.fillStronger)
                .disabled(!canSend)
                .hitTarget()
                .accessibilityLabel("送信")
            }
        }
        .padding(Space.inline)
        .frame(minHeight: ChatMetrics.composerMinHeight)
        // 高さは文の行の数で決める。会話の画面の縦の並びはこの行に最小の高さだけを提案することがあり、受けると文が枠の上下にはみ出す
        .fixedSize(horizontal: false, vertical: true)
        .background(ChatPalette.raised, in: shape)
        .overlay(shape.strokeBorder(ChatPalette.border))
    }

    private var field: some View {
        MultilineTextField(
            label: String(localized: "メッセージ"), placeholder: String(localized: "メッセージ"), text: $draft, selection: $selection, lines: 1...6,
            submit: send, commandKey: commandKey, passesFileDrops: true, longPaste: pasteLong, imagePaste: canAttach ? addImages : nil)
    }
}

/// 送信の場所に出す［生成を停止］（`ChatComposer.stop`）
struct ChatComposerStop {
    let enabled: Bool
    let action: () -> Void
}

/// 入力欄の左端の［ファイルを添付］
struct ChatAttachButton: View {
    let action: () -> Void

    var body: some View {
        Button("ファイルを添付", systemImage: "plus", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title3)
            .foregroundStyle(ChatPalette.secondaryText)
            .hitTarget()
            .help("ファイルを添付")
    }
}

/// `/` の候補が出ている間だけ、↑↓・↩・Tab・Esc を候補に使う。修飾キー付きの ↩ は改行のまま
enum SlashCommandKeys {
    enum Action: Equatable {
        case moved(to: Int)
        case pick(Int)
        case dismiss
    }

    /// 候補が `count` 件、今の選択が `selection` のときに `key` を押した結果。候補に使わないキーは nil
    static func action(for key: KeyEquivalent, modifiers: EventModifiers, count: Int, selection: Int) -> Action? {
        guard count > 0 else { return nil }
        switch key {
        case .upArrow: return .moved(to: (selection - 1 + count) % count)
        case .downArrow: return .moved(to: (selection + 1) % count)
        case .return, .tab:
            guard modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else { return nil }
            return .pick(min(selection, count - 1))
        case .escape: return .dismiss
        default: return nil
        }
    }

    /// 入力欄のキーから呼ぶ形。`selection` を動かし、選んだら `pick`、Esc なら `dismiss`。候補に使ったら true
    static func handle(
        _ key: KeyEquivalent, modifiers: EventModifiers, count: Int, selection: Binding<Int>, pick: (Int) -> Void, dismiss: () -> Void
    ) -> Bool {
        guard let action = action(for: key, modifiers: modifiers, count: count, selection: selection.wrappedValue) else { return false }
        switch action {
        case .moved(let index): selection.wrappedValue = index
        case .pick(let index): pick(index)
        case .dismiss: dismiss()
        }
        return true
    }
}

extension View {
    /// チャットと会話の画面の外枠。⌘F・⌘+・⌘-・⌘0 の受け口（`SessionViewActions`）を出ている間と、入力欄にフォーカスが来たときに置き、
    /// フォーカスの依頼（`AppModel.sessionFocusRequests`。相手が決まっていれば `item` のときだけ）で入力欄に移り、Mac は入力欄にいる間の ⌘V で画像を貼る
    /// （`addFiles` があれば、Finder でコピーした画像でないファイルとフォルダも受ける）
    func chatInput(
        item: ConversationKey, actions: SessionViewActions, composerFocused: FocusState<Bool>.Binding, addImages: @escaping ([Data]) -> Void,
        addFiles: (@MainActor ([URL]) async -> Void)? = nil
    ) -> some View {
        modifier(ChatInputModifier(item: item, actions: actions, composerFocused: composerFocused, addImages: addImages, addFiles: addFiles))
    }

    /// 入力欄のまとまり（帯・画像・候補・入力欄）の置き方。会話の列と同じ読める幅に置き、ファイルのドロップを受ける
    /// （Mac は画像を画像の添付に、ほかのファイルとフォルダを `addFiles` に。iPad は全部を `addFiles` に。`addFiles` が nil なら画像だけ）
    func chatInputColumn(inset: CGFloat, addImages: @escaping ([Data]) -> Void, addFiles: (@MainActor ([URL]) async -> Void)? = nil) -> some View {
        readableColumn(ReadableWidth.chat)
            .padding(.horizontal, inset)
            .padding(.vertical, Space.row)
            .background(ChatPalette.surface)
            #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                var images: [Data] = []
                var others: [URL] = []
                for url in urls where url.isFileURL {
                    if let data = ChatImageIntake.imageFile(url) { images.append(data) } else { others.append(url) }
                }
                if !images.isEmpty { addImages(images) }
                if !others.isEmpty, let addFiles { Task { await addFiles(others) } }
                return !images.isEmpty || (addFiles != nil && !others.isEmpty)
            }
            #else
            .modifier(ChatFileDrop(addFiles: addFiles))
            #endif
    }
}

private struct ChatInputModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let item: ConversationKey
    let actions: SessionViewActions
    var composerFocused: FocusState<Bool>.Binding
    let addImages: ([Data]) -> Void
    let addFiles: (@MainActor ([URL]) async -> Void)?
    #if os(macOS)
    @State private var pasteMonitor = ChatImagePasteMonitor()
    #endif

    func body(content: Content) -> some View {
        content
            .onAppear {
                model.present(sessionActions: actions)
                #if os(macOS)
                pasteMonitor.onPaste = addImages
                pasteMonitor.onFiles = addFiles.map { addFiles in { urls in Task { await addFiles(urls) } } }
                pasteMonitor.isActive = composerFocused.wrappedValue
                pasteMonitor.start()
                #endif
            }
            .onDisappear {
                model.withdraw(sessionActions: actions)
                #if os(macOS)
                pasteMonitor.stop()
                #endif
            }
            .onChange(of: model.sessionFocusRequests) { _, _ in
                if model.sessionFocusTarget.map({ $0 == item }) ?? true { composerFocused.wrappedValue = true }
            }
            .onChange(of: composerFocused.wrappedValue) { _, focused in
                // 2 つ並べているときは、⌘F・⌘+ などを打っている側の画面が受ける
                if focused { model.present(sessionActions: actions) }
                #if os(macOS)
                pasteMonitor.isActive = focused
                #endif
            }
    }
}

extension SessionViewActions {
    /// チャットと会話の受け口。⌘F で検索の欄を開いてフォーカスし、文字の大きさはチャットの大きさ（`AppPreferences.chatFontSizeKey`）を変える
    static func chat(owner: UUID, search: Binding<ChatSearch>, searchFocused: FocusState<Bool>.Binding, conversation: ConversationMenuActions? = nil) -> SessionViewActions {
        let key = AppPreferences.chatFontSizeKey, value = SessionTextSize.chatDefault
        return SessionViewActions(
            owner: owner,
            find: {
                search.wrappedValue.isOpen = true
                searchFocused.wrappedValue = true
            },
            zoomIn: { SessionTextSize.adjust(key, default: value, by: SessionTextSize.step) },
            zoomOut: { SessionTextSize.adjust(key, default: value, by: -SessionTextSize.step) },
            zoomReset: { SessionTextSize.adjust(key, default: value, by: nil) },
            conversation: conversation)
    }
}

#if os(iOS)
/// iPad の入力欄へのファイルのドロップ。ファイルアプリのファイルは URL でなくファイルの中身として届き、受けた場所は関数を出ると消えるので、名前を保って一時の場所に写してから渡す
private struct ChatFileDrop: ViewModifier {
    let addFiles: (@MainActor ([URL]) async -> Void)?

    func body(content: Content) -> some View {
        if let addFiles {
            content.dropDestination(for: DroppedFile.self) { items, _ in
                guard !items.isEmpty else { return false }
                Task {
                    await addFiles(items.map(\.url))
                    items.forEach { $0.discard() }
                }
                return true
            }
        } else {
            content
        }
    }
}

/// ドロップで受けたファイルの一時の写し
private struct DroppedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            // フォルダは iPad の会話には添付できない（`ChatFileIntake`）ので、中身は写さず同じ名前の空のフォルダにする
            if (try? received.file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
            } else {
                try FileManager.default.copyItem(at: received.file, to: copy)
            }
            return DroppedFile(url: copy)
        }
    }

    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
#endif
