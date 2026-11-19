import SwiftUI
import TaskboardKit

/// 作業フォルダの差分。比べる相手の切り替え、ファイルの一覧と、選んだファイルの diff。並べて入る幅では左右に並べ、狭い幅（iPhone）は一覧から diff へ移る。
/// diff の行に付けたコメントは入力欄の下書きの後ろに足す
struct ConversationDiffScreen: View {
    @Environment(\.dismiss) private var dismiss
    let feed: ConversationFeed
    /// タスク画面の右側の欄に置くか。題と［閉じる］は欄の頭にあるので出さない
    var inPanel = false
    @State private var selection: String?
    @State private var width: CGFloat = 0
    @AppStorage(AppPreferences.chatFontSizeKey) private var fontSize = SessionTextSize.chatDefault

    init(feed: ConversationFeed, inPanel: Bool = false, selection: String? = nil) {
        self.feed = feed
        self.inPanel = inPanel
        _selection = State(initialValue: selection)
    }

    var body: some View {
        let fonts = ChatFonts(size: SessionTextSize.clamp(fontSize))
        VStack(spacing: 0) {
            header
            scopePicker
            Divider()
            Group {
                switch feed.diff {
                case .idle, .loading:
                    ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let failure):
                    EmptyState(title: failure.event, symbol: "exclamationmark.triangle", message: failure.detail) {
                        Button("再読み込み") { feed.loadDiff() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let response) where response.scope == .branch && response.base == nil && response.summary.isRepo:
                    EmptyState(
                        "比べるブランチがありません", symbol: "arrow.triangle.branch",
                        message: "originの既定のブランチか、mainかmasterのブランチがあると比べられます。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let response) where !response.summary.isRepo:
                    EmptyState("差分はありません", symbol: "plusminus", message: "作業フォルダはGitのリポジトリではありません。")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let response) where response.files.isEmpty:
                    EmptyState("差分はありません", symbol: "plusminus").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded(let response):
                    content(response, fonts: fonts)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear { if feed.diff.value == nil { feed.loadDiff() } }
        .onChange(of: selection) { _, path in if let path { feed.loadFileDiff(path) } }
        // 範囲を替えて選んだファイルが無くなったら、選びを外す
        .onChange(of: feed.diff.value?.files.map(\.path)) { _, paths in
            if let paths, let path = selection, !paths.contains(path) { selection = nil }
        }
        .task { if let selection { feed.loadFileDiff(selection) } }
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }

    private var header: some View {
        HStack(spacing: Space.row) {
            if !sideBySide, selection != nil {
                Button("一覧に戻る", systemImage: "chevron.left") { selection = nil }
                    .labelStyle(.iconOnly)
                    .hitTarget()
                    .help("一覧に戻る")
            }
            VStack(alignment: .leading, spacing: 2) {
                if !inPanel {
                    Text("差分").font(.title3.weight(.semibold))
                }
                if let summary = feed.diff.value?.summary, summary.isRepo {
                    HStack(spacing: Space.inline) {
                        if let branch = summary.branch { Text(verbatim: branch).lineLimit(1).truncationMode(.middle) }
                        if let base = feed.diff.value?.base, feed.diff.value?.scope == .branch {
                            Text("\(base)との差分").lineLimit(1).truncationMode(.middle)
                        }
                        Text("\(summary.files)件")
                        DiffCounts(insertions: summary.insertions, deletions: summary.deletions)
                    }
                    .textRole(.caption)
                }
            }
            Spacer(minLength: Space.row)
            Button("再読み込み", systemImage: "arrow.clockwise") { feed.loadDiff() }
                .labelStyle(.iconOnly)
                .hitTarget()
                .help("再読み込み")
            if !inPanel {
                Button("閉じる", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .hitTarget()
                    .help("閉じる")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Space.block)
        .padding(.vertical, Space.row)
    }

    /// 比べる相手。横並びが入らない幅ではメニューにする
    private var scopePicker: some View {
        let selection = Binding(get: { feed.diffScope }, set: { feed.setDiffScope($0) })
        let options = ForEach(ConversationDiffScope.allCases, id: \.self) { Text($0.label).tag($0) }
        return ViewThatFits(in: .horizontal) {
            Picker("比べる相手", selection: selection) { options }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            Picker("比べる相手", selection: selection) { options }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.block)
        .padding(.bottom, Space.row)
    }

    private var sideBySide: Bool { width == 0 || width >= ConversationMetrics.diffSideBySideWidth }

    @ViewBuilder
    private func content(_ response: ConversationDiffResponse, fonts: ChatFonts) -> some View {
        if sideBySide {
            HStack(spacing: 0) {
                fileList(response.files, fonts: fonts)
                    .frame(width: ConversationMetrics.diffListWidth)
                Divider()
                detail(fonts: fonts)
            }
        } else if selection != nil {
            detail(fonts: fonts)
        } else {
            fileList(response.files, fonts: fonts)
        }
    }

    private func fileList(_ files: [ConversationDiffFile], fonts: ChatFonts) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files) { file in
                    Button {
                        selection = file.path
                    } label: {
                        ConversationDiffFileRow(file: file, fonts: fonts)
                            .background(selection == file.path ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == file.path ? .isSelected : [])
                }
            }
        }
        .contentMargins(.vertical, Space.inline, for: .scrollContent)
    }

    @ViewBuilder
    private func detail(fonts: ChatFonts) -> some View {
        if let selection {
            switch feed.fileDiffs[selection] ?? .idle {
            case .idle, .loading:
                // 読み直しと範囲の切り替えはファイルの diff を捨てるので、出たときに取り直す
                ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { feed.loadFileDiff(selection) }
            case .failed(let failure):
                EmptyState(failure.event, symbol: "exclamationmark.triangle", message: failure.detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let file):
                ConversationFileDiffView(file: file, fonts: fonts) { feed.restoredDrafts.append(RestoredDraft(text: $0, appends: true)) }
                    .id("\(feed.diffScope.rawValue):\(file.path)")
            }
        } else {
            EmptyState("ファイルを選んでください", symbol: "doc.text").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 一覧の 1 行。変更の印（A・D・R・M）、パス、足した行と消した行
struct ConversationDiffFileRow: View {
    let file: ConversationDiffFile
    let fonts: ChatFonts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            Text(verbatim: FileChangeKind(file.change).mark).font(fonts.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary)
                .help(FileChangeKind(file.change).name)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: file.path).font(fonts.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if let old = file.oldPath {
                    Text(verbatim: "← \(old)").font(fonts.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: Space.row)
            DiffCounts(insertions: file.insertions, deletions: file.deletions)
        }
        .padding(.horizontal, Space.block)
        .padding(.vertical, Space.inline)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(FileChangeKind(file.change).name)、\(file.path)")
    }
}

/// 1 ファイルの diff。等幅で、足した行と消した行を記号（+・−）と色で示し、行をまたいで選べる。`comment` があれば選んだ行にコメントを付けられ
/// （`ChatFileText.comment`。選んだ所に入力欄を重ねる）、付けた文（`DiffLineComment`）を渡す。付けた行は左端に印
struct ConversationFileDiffView: View {
    let file: ConversationFileDiffResponse
    let fonts: ChatFonts
    var comment: ((String) -> Void)?
    /// コメントを書いている選択と、付けた行（段落の番号）
    @State private var pending: ChatFileSelection?
    @State private var draft = ""
    @State private var commented: Set<Int>

    init(file: ConversationFileDiffResponse, fonts: ChatFonts, commented: Set<Int> = [], comment: ((String) -> Void)? = nil) {
        self.file = file
        self.fonts = fonts
        self.comment = comment
        _commented = State(initialValue: commented)
    }

    var body: some View {
        let document = Self.document(file, fontSize: fonts.size, marked: commented)
        VStack(alignment: .leading, spacing: 0) {
            if file.truncated {
                Text("1MBを超えたため、先頭だけを表示しています。").font(fonts.caption).foregroundStyle(.secondary).padding(Space.block)
            }
            if document.paragraphs.isEmpty {
                Text("表示できる差分がありません。バイナリのファイルか、中身の変わらない変更です。").font(fonts.caption).foregroundStyle(.secondary).padding(Space.block)
                Spacer(minLength: 0)
            } else {
                ChatFileText(document: document, comment: comment == nil ? nil : { selection in
                    draft = ""
                    pending = selection
                })
                .popover(item: $pending, attachmentAnchor: .rect(.rect(pending?.rect ?? .zero)), arrowEdge: .bottom) { selection in
                    DiffCommentEditor(quote: Self.quote(document, selection.lines), text: $draft, fonts: fonts) {
                        submit(document, selection.lines)
                    } cancel: {
                        pending = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func submit(_ document: ChatFileDocument, _ lines: [Int]) {
        guard let comment else { return }
        let picked = lines.compactMap { index -> DiffLineComment.Line? in
            guard case .line(let change, let old, let new, let text) = document.paragraphs[index] else { return nil }
            return DiffLineComment.Line(change: change, old: old, new: new, text: text)
        }
        comment(DiffLineComment.prompt(path: file.path, lines: picked, comment: draft))
        commented.formUnion(lines)
        pending = nil
    }

    /// 段落は diff の行と 1 対 1（畳んだ行は 1 つの帯）
    static func document(_ file: ConversationFileDiffResponse, fontSize: Double, marked: Set<Int>) -> ChatFileDocument {
        let rows = ChatDiffRow.rows(ChatDiffHunk.parse(unified: file.diff))
        let paragraphs = rows.map { row -> ChatFileDocument.Paragraph in
            switch row {
            case .line(_, let change, let old, let new, let text): .line(change: change, old: old, new: new, text: text)
            case .gap(let id, _, _, let count, _): .gap(id: id, label: String(localized: "変更のない\(count)行"), expandable: false)
            }
        }
        let digits = String(rows.compactMap { row -> Int? in
            if case .line(_, _, let old, let new, _) = row { return max(old ?? 0, new ?? 0) }
            return nil
        }.max() ?? 1).count
        return ChatFileDocument(paragraphs: paragraphs, diff: true, digits: digits, fontSize: fontSize, marked: marked)
    }

    /// 入力欄の上に引く行
    private static func quote(_ document: ChatFileDocument, _ lines: [Int]) -> String {
        lines.compactMap { index in
            guard case .line(_, _, _, let text) = document.paragraphs[index] else { return nil }
            return text
        }.joined(separator: "\n")
    }
}

/// 選んだ行に重ねるコメントの欄。［コメントを追加］で入力欄の下書きの後ろに足す
private struct DiffCommentEditor: View {
    let quote: String
    @Binding var text: String
    let fonts: ChatFonts
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            Quote(text: quote)
            MultilineTextField(label: String(localized: "コメント"), placeholder: String(localized: "コメント"), text: $text, lines: 2...8, style: .roundedBorder)
                .focused($focused)
            HStack(spacing: Space.row) {
                Spacer()
                Button("キャンセル", action: cancel)
                Button("コメントを追加", action: submit)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(empty)
                    .help("次のメッセージに入れます")
            }
            .controlSize(.small)
        }
        .font(fonts.caption)
        .padding(Space.card)
        #if os(macOS)
        .frame(width: ConversationMetrics.diffCommentWidth)
        .onExitCommand(perform: cancel)
        #else
        .presentationCompactAdaptation(.sheet)
        .presentationDetents([.medium])
        #endif
        .onAppear { focused = true }
    }
}

extension ConversationDiffScope {
    var label: LocalizedStringKey {
        switch self {
        case .all: "すべての変更"
        case .unstaged: "ステージ前"
        case .staged: "ステージ済み"
        case .branch: "ブランチ全体"
        }
    }
}
