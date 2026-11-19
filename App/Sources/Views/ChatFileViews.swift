import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - 札

/// 札と一覧の右の要約。+・− は記号のまま（読み上げは `ChatFileRef.summaryLabel`）
struct ChatFileSummary: View {
    let file: ChatFile
    var added: Int?
    var removed: Int?

    var body: some View {
        switch file.action {
        case .read:
            Text("読み取り済み").foregroundStyle(.secondary)
        case .image:
            if let bytes = file.bytes {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).foregroundStyle(.secondary)
            }
        case .created, .edited:
            HStack(spacing: Space.inline) {
                Text(verbatim: "+\(added ?? file.added)").foregroundStyle(DiffPalette.added)
                if file.action == .edited || (removed ?? 0) > 0 {
                    Text(verbatim: "−\(removed ?? file.removed)").foregroundStyle(DiffPalette.removed)
                }
            }
            .monospacedDigit()
        }
    }
}

// MARK: - ファイルの欄

/// 会話の右にファイルの欄を並べる。並べて入らない幅ではシートで出し、iPhone は全面に出す。幅を測る前と、
/// 親が詳細を畳んで欄の場所を空けてくれるとき（`chatFileRoom`。畳まれると並べて入る幅になる）はシートにしない
struct ChatFilePaneHost: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.chatFileRoom) private var fileRoom
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let feed: ConversationFeed
    @Binding var selection: ChatFileRef?
    let fontSize: Double
    @State private var width: CGFloat = 0
    /// 人の発言の画像を押して大きく開いたもの。行は送ると消えることがある（LazyVStack）ので、シートは行でなくここに置く
    @State private var openedImage: ChatSentImageRef?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if selection != nil, ChatFileMetrics.sideBySide(width: width) {
                Divider()
                ChatFilePane(feed: feed, selection: $selection, fonts: ChatFonts(size: fontSize))
                    .frame(width: ChatFileMetrics.paneWidth(in: width))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .preference(key: ChatFileOpenKey.self, value: selection != nil)
        .environment(\.chatSentImages, images)
        .sheet(item: $openedImage) { ref in
            ChatSentImageViewer(ref: ref, access: images) { openedImage = nil }
                .environment(model)
                .dismissOnOutsideClick { openedImage = nil }
                #if os(macOS)
                .frame(
                    minWidth: ChatFileMetrics.sheet.width, idealWidth: ChatFileMetrics.sheetIdeal.width, maxWidth: ChatFileMetrics.sheetMax.width,
                    minHeight: ChatFileMetrics.sheet.height, idealHeight: ChatFileMetrics.sheetIdeal.height, maxHeight: ChatFileMetrics.sheetMax.height)
                #endif
        }
        #if os(iOS)
        .sheet(item: sheet(compact: false)) { _ in sheetContent }
        .fullScreenCover(item: sheet(compact: true)) { _ in sheetContent }
        #else
        .sheet(item: sheet(compact: false)) { _ in
            sheetContent
                .dismissOnOutsideClick { selection = nil }
                .frame(
                    minWidth: ChatFileMetrics.sheet.width, idealWidth: ChatFileMetrics.sheetIdeal.width, maxWidth: ChatFileMetrics.sheetMax.width,
                    minHeight: ChatFileMetrics.sheet.height, idealHeight: ChatFileMetrics.sheetIdeal.height, maxHeight: ChatFileMetrics.sheetMax.height)
        }
        #endif
    }

    private func sheet(compact: Bool) -> Binding<ChatFileRef?> {
        #if os(iOS)
        let isCompact = sizeClass == .compact
        #else
        let isCompact = false
        #endif
        return Binding(
            get: { width > 0 && !ChatFileMetrics.sideBySide(width: width) && !fileRoom && isCompact == compact ? selection : nil },
            set: { if $0 == nil { selection = nil } })
    }

    private var images: ChatSentImageAccess {
        ChatSentImageAccess(feed: feed, fixtures: model.fixtureExtras.chatFiles) { openedImage = $0 }
    }

    private var sheetContent: some View {
        ChatFilePane(feed: feed, selection: $selection, fonts: ChatFonts(size: fontSize), inSheet: true)
            .environment(model)
    }
}

extension View {
    func chatFilePane(_ feed: ConversationFeed, selection: Binding<ChatFileRef?>, fontSize: Double) -> some View {
        modifier(ChatFilePaneHost(feed: feed, selection: selection, fontSize: fontSize))
    }
}

/// ファイルの欄。上にこの会話で触ったファイルの一覧、下に選んだファイルの中身（diff・読んだ文・画像）。
/// 広い幅はチャットの右に並べ、入らない幅はシートで出す（`ChatFileMetrics`）。どちらも上の閉じるボタンで閉じる
struct ChatFilePane: View {
    @Environment(\.pageInset) private var inset
    let feed: ConversationFeed
    @Binding var selection: ChatFileRef?
    var fonts = ChatFonts(size: SessionTextSize.chatDefault)
    /// シートで出しているときだけ Esc で閉じる（右の欄では、Esc は入力欄の候補と検索の欄が使う）
    var inSheet = false

    var body: some View {
        let entries = ChatFileIndex.entries(in: feed.messages)
        VStack(spacing: 0) {
            if let ref = selection {
                header(ref)
                Divider()
                if entries.count > 1 {
                    ChatFileList(entries: entries, selection: $selection, fonts: fonts)
                    Divider()
                }
                ChatFileBody(ref: ref, feed: feed, fonts: fonts)
                    .id(ref.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ファイル")
    }

    private func header(_ ref: ChatFileRef) -> some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: ref.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ref.name).textRole(.sectionTitle)
                if let directory = ref.directory {
                    Text(verbatim: directory).textRole(.mono)
                }
                MetaLine(items: details(ref)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("閉じる", systemImage: "xmark") { selection = nil }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .keyboardShortcut(inSheet ? .cancelAction : nil)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.block)
        .help(ref.file.path ?? "")
    }

    /// 見出しの下の補足。読んだ範囲・画像の大きさ・変えた行の数
    private func details(_ ref: ChatFileRef) -> [String] {
        let file = ref.file
        switch file.action {
        case .read:
            guard let first = file.firstLine, let count = file.lineCount, count > 0 else { return [String(localized: "読み取り済み")] }
            if let total = file.totalLines, count < total {
                return [String(localized: "\(first)〜\(first + count - 1)行目を読み取り済み"), String(localized: "全\(total)行")]
            }
            return [String(localized: "読み取り済み"), String(localized: "全\(count)行")]
        case .image:
            return [
                file.width.flatMap { w in file.height.map { h in "\(w)×\(h)" } },
                file.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            ].compactMap { $0 }
        case .created:
            return [String(localized: "ファイルの追加"), String(localized: "\(file.added)行")]
        case .edited:
            return [ref.summaryLabel]
        }
    }
}

/// 欄の上の、この会話で触ったファイル（最後に触った順）。多ければ一覧の中で送る
struct ChatFileList: View {
    let entries: [ChatFileIndex.Entry]
    @Binding var selection: ChatFileRef?
    var fonts = ChatFonts(size: SessionTextSize.chatDefault)

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
        }
        .frame(maxHeight: ChatFileMetrics.listMaxHeight)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(entries) { entry in
                let selected = selection?.file.path == entry.path
                Button {
                    selection = entry.shown
                } label: {
                    HStack(spacing: Space.row) {
                        Image(systemName: entry.shown.symbol).foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(verbatim: entry.shown.name).lineLimit(1).truncationMode(.middle)
                        if let directory = entry.shown.directory {
                            Text(verbatim: directory).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: Space.row)
                        ChatFileSummary(file: entry.shown.file, added: entry.change == nil ? nil : entry.added, removed: entry.change == nil ? nil : entry.removed)
                    }
                    .font(fonts.caption)
                    .padding(.horizontal, Space.block)
                    .padding(.vertical, Space.inline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Color.accentColor.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.shown.name + "、" + summary(entry))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help(entry.path)
            }
        }
        .padding(.vertical, Space.inline)
    }

    private func summary(_ entry: ChatFileIndex.Entry) -> String {
        guard entry.change != nil else { return entry.shown.summaryLabel }
        return String(localized: "\(entry.added)行追加、\(entry.removed)行削除")
    }
}

// MARK: - 中身

/// 選んだファイルの中身。diff を行に持っていればそのまま出し、それ以外は口から取る
struct ChatFileBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let ref: ChatFileRef
    let feed: ConversationFeed
    let fonts: ChatFonts

    var body: some View {
        if ref.file.action == .created && !ref.file.hunks.isEmpty {
            // codex の新規は札に diff を持つ（中身の口が無い）
            ChatDiffView(hunks: ref.file.hunks, ref: ref, feed: feed, fonts: fonts)
        } else if ref.file.action == .edited && !ref.file.hunksOmitted {
            if ref.file.hunks.isEmpty {
                Text("変更した行はありません").textRole(.secondary).padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ChatDiffView(hunks: ref.file.hunks, ref: ref, feed: feed, fonts: fonts)
            }
        } else {
            loaded.task(id: ref.id) { await feed.loadFile(ref, fixtures: model.fixtureExtras.chatFiles) }
        }
    }

    @ViewBuilder
    private var loaded: some View {
        switch feed.files.state(ref) {
        case .loading, nil:
            ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            ChatFileFailure(failure: failure) { Task { await feed.loadFile(ref, fixtures: model.fixtureExtras.chatFiles) } }
        case .loaded(let content):
            switch (ref.file.action, content) {
            case (.created, .text(let text)):
                ChatDiffView(hunks: [ChatDiffHunk.added(text)], ref: ref, feed: feed, fonts: fonts)
            case (_, .text(let text)):
                ChatFileText(document: .text(text, firstLine: ref.file.firstLine ?? 1, fontSize: fonts.size))
            case (_, .diff(let hunks)):
                ChatDiffView(hunks: hunks, ref: ref, feed: feed, fonts: fonts)
            case (_, .image(let data)):
                ChatFileImage(data: data, name: ref.name)
            }
        }
    }
}

/// 欄の中の失敗。狭い欄に空状態の大きな表示を置かず、帯で出す（docs/ui-system.md「使わない書き方」）
struct ChatFileFailure: View {
    @Environment(\.pageInset) private var inset
    let failure: UserFacingError
    var retry: (() -> Void)?

    var body: some View {
        Banner(kind: .error, message: failure.event, detail: failure.detail) {
            if let retry { Button("再読み込み", action: retry).controlSize(.small) }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.block)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// diff を行に並べる。左に変える前と後の行番号、+ は追加・− は削除の色。変わっていない行は hunk の間で畳み、押すと開く。
/// 全部の行を 1 つの文にし、行をまたいで選べる（`ChatFileText`）
struct ChatDiffView: View {
    @Environment(AppModel.self) private var model
    let hunks: [ChatDiffHunk]
    let ref: ChatFileRef
    let feed: ConversationFeed
    let fonts: ChatFonts
    @State private var expanded: Set<Int> = []

    var body: some View {
        ChatFileText(document: document) { id in
            expanded.insert(id)
            Task { await feed.loadFile(ref, part: .original, fixtures: model.fixtureExtras.chatFiles) }
        }
    }

    private var document: ChatFileDocument {
        let rows = ChatDiffRow.rows(hunks, original: original)
        var paragraphs: [ChatFileDocument.Paragraph] = []
        for row in rows {
            switch row {
            case .line(_, let change, let old, let new, let text):
                paragraphs.append(.line(change: change, old: old, new: new, text: text))
            case .gap(let id, let oldStart, let newStart, let count, let lines):
                if expanded.contains(id), let lines {
                    paragraphs += lines.enumerated().map { .line(change: .context, old: oldStart + $0.offset, new: newStart + $0.offset, text: $0.element) }
                } else {
                    paragraphs.append(gap(id: id, count: count))
                }
            }
        }
        return ChatFileDocument(
            paragraphs: paragraphs, diff: true, digits: String(rows.compactMap(\.lastNumber).max() ?? 1).count, fontSize: fonts.size)
    }

    /// 変える前の全文の行（取れていれば）
    private var original: [String]? {
        guard case .loaded(.text(let text)) = feed.files.state(ref, .original) else { return nil }
        return ChatTextLines.lines(text)
    }

    private func gap(id: Int, count: Int) -> ChatFileDocument.Paragraph {
        let state = feed.files.state(ref, .original)
        if expanded.contains(id), case .failed(let failure) = state {
            return .gap(id: id, label: failure.text, expandable: false)
        }
        if expanded.contains(id), case .loading = state {
            return .gap(id: id, label: String(localized: "読み込み中…"), expandable: false)
        }
        if ref.hasOriginal && feed.keepsOriginals(in: model) {
            return .gap(id: id, label: String(localized: "変更のない\(count)行を表示"), expandable: true)
        }
        return .gap(id: id, label: String(localized: "変更のない\(count)行"), expandable: false)
    }
}

/// diff の 1 行。行番号は等幅の数字を桁で右に揃える（幅を数値で固定しない）
struct ChatDiffLine: View {
    let change: ChatDiffRow.Change
    let old: Int?
    let new: Int?
    let text: String
    let digits: Int
    let fonts: ChatFonts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            Text(verbatim: ChatTextLines.pad(old, digits)).foregroundStyle(.tertiary)
            Text(verbatim: ChatTextLines.pad(new, digits)).foregroundStyle(.tertiary)
            Text(verbatim: sign).foregroundStyle(color)
            Text(verbatim: text.isEmpty ? " " : text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(fonts.caption.monospaced())
        .padding(.horizontal, Space.block)
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var sign: String {
        switch change {
        case .context: " "
        case .removed: "−"
        case .added: "+"
        }
    }

    private var color: Color {
        switch change {
        case .context: .secondary
        case .removed: DiffPalette.removed
        case .added: DiffPalette.added
        }
    }

    private var background: Color {
        switch change {
        case .context: .clear
        case .removed: DiffPalette.removedBackground
        case .added: DiffPalette.addedBackground
        }
    }

    private var label: String {
        switch change {
        case .context: String(localized: "\(new ?? 0)行目、\(text)")
        case .removed: String(localized: "削除、\(old ?? 0)行目、\(text)")
        case .added: String(localized: "追加、\(new ?? 0)行目、\(text)")
        }
    }
}

/// 読んだ文の行の分け方と、行番号の桁揃え
enum ChatTextLines {
    /// 改行で分ける。末尾の改行の後ろは行にしない
    static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// 行番号を桁に揃える（無ければ空白）
    static func pad(_ number: Int?, _ digits: Int) -> String {
        let text = number.map(String.init) ?? ""
        return String(repeating: " ", count: max(digits - text.count, 0)) + text
    }
}

/// 読んだ画像。欄の幅に収めて出す。右クリック（長押し）でコピーと保存
struct ChatFileImage: View {
    @Environment(\.pageInset) private var inset
    let data: Data
    let name: String
    @State private var saving: ImageFile?

    var body: some View {
        if let image {
            ScrollView {
                image.resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .padding(inset)
                    .accessibilityLabel(name)
                    .contextMenu {
                        ImageCopyButton(data: data)
                        Button("画像を保存…", systemImage: "square.and.arrow.down") { saving = ImageFile(data: data) }
                    }
            }
            .fileExporter(
                isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }), document: saving,
                contentType: Pasteboard.imageType(data) ?? .png, defaultFilename: name
            ) { _ in saving = nil }
        } else {
            ChatFileFailure(failure: UserFacingError("画像を表示できませんでした", cause: String(localized: "この形式の画像は表示できません")))
        }
    }

    private var image: Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

/// 画像の［画像をコピー］（右クリック・長押しのメニューの項目）
struct ImageCopyButton: View {
    let data: Data

    var body: some View {
        Button("画像をコピー", systemImage: "doc.on.doc") { Pasteboard.copy(image: data) }
    }
}

/// 画像の書き出し（`fileExporter` に渡す）。中身は元の形式のまま
struct ImageFile: FileDocument {
    static let readableContentTypes: [UTType] = [.image]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension ChatDiffRow {
    /// 行番号の桁を決める、この行のいちばん大きい番号
    var lastNumber: Int? {
        switch self {
        case .line(_, _, let old, let new, _): max(old ?? 0, new ?? 0)
        case .gap(_, let oldStart, let newStart, let count, _): max(oldStart, newStart) + count - 1
        }
    }
}

extension ChatDiffHunk {
    /// 新しく書いたファイルを、全部の行を足した diff にする
    static func added(_ text: String) -> ChatDiffHunk {
        let lines = ChatTextLines.lines(text)
        return ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count, lines: lines.map { "+" + $0 })
    }
}
