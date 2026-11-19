import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// `import Markdown`（DocumentWebView）の `Markdown.Document` がモジュール全体の名前解決に漏れるので、ここで固定する
typealias Document = TaskboardKit.Document

extension DocKey: @retroactive Identifiable {}

/// 文書の画面の寸法
enum DocumentMetrics {
    /// 本文の欄の最小の幅。これとコメントの欄が並んで入らなければ、コメントは本文と切り替えて出す
    static let bodyMinWidth: CGFloat = 640
    /// コメントの欄の幅
    static let comments: ClosedRange<CGFloat> = 300...380
    static let commentsShare: CGFloat = 0.3
}

/// タスクの文書の一覧（詳細の欄の「文書」の節）。押すとパネルの帯の下を文書の画面にする（iPhone はシート）。
/// レビューを頼まれていれば、上に依頼の帯を出す
struct DocumentList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    let task: BoardTask
    let documents: [Document]

    var body: some View {
        let state = model.fleet.machineState(for: task.machine)
        VStack(alignment: .leading, spacing: Space.row) {
            DocumentJudgments(task: task, documents: documents)
            if let request = state?.reviewRequests[task.id] {
                Banner(kind: .waiting, message: String(localized: "レビューを頼まれています"), detail: request.note.isEmpty ? nil : request.note) {
                    if let first = documents.first {
                        Button("読む") { model.navigate(to: .doc(first.id), from: .link) }.controlSize(.small)
                    }
                }
            }
            if documents.isEmpty {
                Text("文書はありません").textRole(.secondary)
            } else {
                ForEach(documents) { doc in
                    DocumentRow(doc: doc, openAsk: state?.openAsk(forDoc: doc.docID), selected: model.openDoc == doc.id) {
                        model.navigate(to: .doc(doc.id), from: .link)
                    }
                    .contextMenu {
                        Button("開く") { model.navigate(to: .doc(doc.id), from: .link) }
                        if supportsMultipleWindows {
                            Button("別ウインドウで開く", systemImage: "macwindow.on.rectangle") { openWindow(value: doc.id) }
                        }
                    }
                }
            }
        }
    }
}

struct DocumentRow: View {
    let doc: Document
    let openAsk: Ask?
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Image(systemName: doc.format == .html ? "globe" : "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(doc.displayTitle).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    if let openAsk {
                        Label(String(localized: "質問\(openAsk.questions.count)件の回答待ち"), systemImage: "questionmark.bubble")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    MetaLine(items: Self.marks(doc), date: doc.updatedAt)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 選んだ印の背景は欄の余白まで広げ、文字の左端は他の節と揃える
            .padding(.vertical, Space.inline)
            .padding(.horizontal, Space.row)
            .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.horizontal, -Space.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static func marks(_ doc: Document) -> [String] {
        var marks = [String(localized: "第\(doc.latestRev)版")]
        if doc.openComments > 0 { marks.append(String(localized: "未解決のコメント\(doc.openComments)件")) }
        if doc.draftComments > 0 { marks.append(String(localized: "下書き\(doc.draftComments)件")) }
        return marks
    }
}

/// 文書の画面。本文は読める幅（`ReadableWidth.text`）で中央に置き、右にコメントの欄（質問・コメント・レビューの送信）。
/// 本文とコメントの欄が並んで入らない幅では、コメントの欄を本文と切り替えて出す。
/// パネル（会話の右の欄か、帯の下の全体）・別ウィンドウ・iPhone のシートで使う
struct DocumentScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.pageInset) private var inset
    @Environment(\.dismiss) private var dismiss
    /// 本文の文字の大きさ。チャットと同じ設定（⌘+ / ⌘- で変わる）に従う
    @AppStorage(AppPreferences.chatFontSizeKey) private var textSize = SessionTextSize.chatDefault
    /// OS の文字の大きさ（iOS の Dynamic Type）の倍率を百分率で。本文の CSS は px なので、アプリの設定にこれを掛ける（Mac は 100 のまま）
    @ScaledMetric(relativeTo: .body) private var dynamicScale = 100.0
    let key: DocKey
    /// iPhone のシートで出すとき。上の帯を出さず、操作はシートのバーに置く
    var inSheet = false
    /// 別ウィンドウで開いているとき。「戻る」を出さず、Esc で閉じない（閉じるのは ⌘W）
    var inWindow = false
    /// タスクのパネルで会話の右の欄に置いているとき。［戻る］の代わりに右端に閉じるボタンを出す
    var inPane = false
    /// 同じタスクの別の文書へ切り替える。nil はパネルとシートの既定（開いている文書を差し替える）。別ウィンドウはウィンドウの値を差し替える
    var switchTo: ((DocKey) -> Void)?

    /// 本文の文字の大きさ。アプリの設定（範囲内に収める）に OS の倍率を掛ける
    private var bodyTextSize: Double { (SessionTextSize.clamp(textSize) * dynamicScale / 100).rounded() }

    @State private var web: DocumentWebController?
    @State private var content: DocContent?
    @State private var contentFailure: UserFacingError?
    @State private var revisions: [DocRevision] = []
    @State private var selectedRev: Int?
    @State private var comments: [DocComment] = []
    @State private var asks: [Ask] = []
    @State private var sideFailure: UserFacingError?
    @State private var activeComment: Int64?
    @State private var composer: Composer?
    /// 選んだ所に重ねて書いているコメントと、その枠（web view の座標）
    @State private var floating: Composer?
    @State private var floatingRect: CGRect = .zero
    /// nil は既定（質問・コメント・レビュー依頼があれば開く）
    @State private var showsComments: Bool?
    @State private var confirmDelete = false
    @State private var exportedPDF: PDFFile?
    @State private var exportFailure: UserFacingError?
    @State private var width: CGFloat = 0
    /// 返信・質問の回答の書きかけがあるか（中の部品が `DocumentPendingInputKey` で知らせる）
    @State private var pendingInput = false
    /// 本文の欄で［承認］を押した送る文面（確認のダイアログを出す）
    @State private var approving: Approving?

    struct Approving: Identifiable {
        var draft: DocDraft
        var body: String
        var id: String { draft.id }
    }

    struct Composer: Identifiable {
        var id = UUID()
        var anchor: CommentAnchor?
        var text = ""
        var failure: UserFacingError?
    }

    var body: some View {
        if let doc = model.fleet.document(for: key) {
            screen(doc)
        } else {
            EmptyState(title: "この文書はありません", symbol: "doc.text", message: "削除されました。一覧から別の文書を開いてください。") {
                if inSheet || inWindow {
                    Button("閉じる") { close() }
                } else {
                    Button(inPane ? "閉じる" : "戻る") { model.closeDoc() }
                }
            }
        }
    }

    @ViewBuilder
    private func screen(_ doc: Document) -> some View {
        let task = TaskKey(machine: doc.machine, number: doc.taskNumber)
        let sideBySide = width >= DocumentMetrics.bodyMinWidth + DocumentMetrics.comments.lowerBound
        // 狭い幅は本文から読む（質問があれば本文の上に帯を出す）
        let commentsShown = showsComments ?? (sideBySide && defaultShowsComments(doc))
        VStack(spacing: 0) {
            if !inSheet {
                bar(doc, commentsShown: commentsShown, sideBySide: sideBySide)
                Divider()
            }
            HStack(spacing: 0) {
                if sideBySide || !commentsShown {
                    VStack(spacing: 0) {
                        if !sideBySide || !commentsShown, let ask = openAsk {
                            Banner(kind: .waiting, message: String(localized: "質問が\(ask.questions.count)件あります")) {
                                Button("回答する") { focusForm(AppModel.formSlot(for: ask)) }.controlSize(.small)
                            }
                            .padding(.horizontal, inset)
                            .padding(.vertical, Space.row)
                        }
                        reader(doc)
                    }
                }
                if commentsShown {
                    if sideBySide { Divider() }
                    commentsPane(doc, task: task)
                        .frame(width: sideBySide ? min(max(width * DocumentMetrics.commentsShare, DocumentMetrics.comments.lowerBound), DocumentMetrics.comments.upperBound) : nil)
                        .frame(maxWidth: sideBySide ? nil : .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onPreferenceChange(DocumentPendingInputKey.self) { pendingInput = $0 }
        // タスクのパネルも Esc の前に見る（フォーカスが帯にあると、Esc はパネルが受ける）
        .transformPreference(DocumentPendingInputKey.self) {
            $0 = $0 || web?.formsPendingInput == true
                || [composer, floating].contains { $0?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        }
        #if os(macOS)
        // パネルの中だけ。別ウィンドウの Esc は何もしない（iPhone のシートは下の見えないボタン）
        .onExitCommand(perform: inSheet || inWindow ? nil : { escape() })
        #else
        .background {
            if inSheet {
                // 外付けキーボードの Esc。ツールバーの［閉じる］に付けると、押したときも書きかけを見て止まってしまう
                Button("閉じる") { escape() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        #endif
        .navigationTitle(inSheet ? doc.displayTitle : "")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() } }
                ToolbarItem(placement: .principal) {
                    readerSwitch(commentsShown: commentsShown, doc: doc)
                }
                ToolbarItem(placement: .primaryAction) {
                    moreMenu(doc)
                }
                #if os(iOS)
                // 題は上のバーに出ない（本文とコメントの切り替えが中央にある）ので、切り替えは題と一緒に下のバーに置く
                if sequence.canSwitch {
                    ToolbarItemGroup(placement: .bottomBar) {
                        DocumentStepButtons(sequence: sequence) { switchDocument(to: $0) }
                        Spacer()
                        DocumentTitleMenu(sequence: sequence, switchTo: { switchDocument(to: $0) }) {
                            Text(doc.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                #endif
            }
        }
        .onAppear {
            guard web == nil else { return }
            let controller = DocumentWebController()
            controller.openInApp = { [model] url in model.open(url, from: .link) }
            controller.onFormAction = { action in handleForm(action, doc: doc) }
            web = controller
        }
        .onChange(of: formsInput(doc), initial: true) { pushForms(doc) }
        .onChange(of: web != nil) { pushForms(doc) }
        .onChange(of: model.docFormFocus, initial: true) { _, focus in
            guard let focus, focus.doc == key, web != nil else { return }
            focusForm(focus.slot)
            model.docFormFocus = nil
        }
        .confirmationDialog(
            "送る文面の承認", isPresented: Binding(get: { approving != nil }, set: { if !$0 { approving = nil } }), titleVisibility: .visible,
            presenting: approving
        ) { item in
            Button("承認") { approve(item) }
            Button("キャンセル", role: .cancel) {}
        } message: { item in
            Text("「\(item.draft.draft.to)」に送る文面を承認しますか？　承認すると、会話がこの本文で送信します。")
        }
        .task(id: "\(key)/\(doc.latestRev)/\(selectedRev ?? -1)/\(web != nil)") { await loadContent() }
        .task(id: "\(key)/\(doc.openComments)/\(doc.draftComments)/\(askSignature)") { await loadSide(task: task) }
        .onChange(of: comments) { _, _ in pushHighlights() }
        .onChange(of: activeComment) { _, _ in pushHighlights() }
        .onChange(of: bodyTextSize) { _, size in web?.setTextSize(size) }
        .confirmationDialog("文書の削除", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { delete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(doc.displayTitle)」を削除しますか？　コメントと質問も削除されます。この操作は元に戻せません。")
        }
        .fileExporter(isPresented: Binding(get: { exportedPDF != nil }, set: { if !$0 { exportedPDF = nil } }),
                      document: exportedPDF, contentType: .pdf, defaultFilename: doc.displayTitle) { _ in exportedPDF = nil }
        .alert(exportFailure?.text ?? "", isPresented: Binding(get: { exportFailure != nil }, set: { if !$0 { exportFailure = nil } })) {
            Button("閉じる", role: .cancel) {}
        }
    }

    private func copyContent() {
        guard let text = content?.content else { return }
        Pasteboard.copy(text)
    }

    private func exportPDF() async {
        guard let web else { return }
        do {
            exportedPDF = PDFFile(data: try await web.pdf())
        } catch {
            exportFailure = UserFacingError("PDFを保存できませんでした", error: error)
        }
    }

    /// 上の帯。戻る・前と次の文書・題（押すと同じタスクの文書を選べる）・版・コメントの追加・コメントの欄の開閉（狭い幅では本文とコメントの切り替え）・その他
    private func bar(_ doc: Document, commentsShown: Bool, sideBySide: Bool) -> some View {
        HStack(spacing: Space.row) {
            if !inWindow, !inPane {
                Button("戻る", systemImage: "chevron.left") { model.closeDoc() }
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("タスクに戻る")
            }
            if sequence.canSwitch {
                DocumentStepButtons(sequence: sequence) { switchDocument(to: $0) }
            }
            DocumentTitleMenu(sequence: sequence, switchTo: { switchDocument(to: $0) }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(doc.displayTitle).textRole(.sectionTitle).help(doc.displayTitle)
                    if doc.title?.isEmpty == false, doc.title != doc.name {
                        Text(doc.name).textRole(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if revisions.count > 1 {
                Picker("版", selection: Binding(get: { selectedRev ?? doc.latestRev }, set: { selectedRev = $0 == doc.latestRev ? nil : $0 })) {
                    ForEach(revisions, id: \.rev) { Text("第\($0.rev)版").tag($0.rev) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if model.canWrite(key.machine) {
                Button(web?.hasSelection == true ? "選択範囲にコメント" : "コメントを追加", systemImage: "plus.bubble") {
                    Task { await startComment() }
                }
                .disabled(content == nil)
                .controlSize(.small)
            }
            if sideBySide {
                commentToggle(commentsShown: commentsShown)
            } else {
                readerSwitch(commentsShown: commentsShown, doc: doc)
            }
            moreMenu(doc)
            if inPane {
                Button("閉じる", systemImage: "xmark") { model.closeDoc() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("閉じる（Esc）")
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.inline)
    }

    /// 狭い幅（とiPhone）の、本文とコメントの切り替え
    private func readerSwitch(commentsShown: Bool, doc: Document) -> some View {
        let count = comments.isEmpty ? doc.openComments + doc.draftComments : comments.count
        return Picker("表示", selection: Binding(get: { commentsShown }, set: { showsComments = $0 })) {
            Text("本文").tag(false)
            Text(count > 0 ? String(localized: "コメント\(count)") : String(localized: "コメント")).tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var openAsk: Ask? {
        asks.first { $0.status == .open } ?? model.fleet.machineState(for: key.machine)?.openAsk(forDoc: key.id)
    }

    // MARK: 本文の欄

    /// 欄の中身を決める値（変わったら描き直す）
    private func formsInput(_ doc: Document) -> String {
        let askPart = formAsks.map { "\($0.askID):\($0.status.rawValue):\($0.deliveredAt != nil)" }.joined(separator: ",")
        let draftPart = doc.drafts.map { "\($0.id):\($0.draft.body.hashValue):\($0.answer?.answerID ?? 0)" }.joined(separator: ",")
        return "\(askPart)|\(draftPart)|\(model.canWrite(key.machine))|\(bodyTextSize)"
    }

    /// 欄に出す質問の束。読み込んだ一覧に、接続していない（fixtures）ときは state の未回答の質問を足す
    private var formAsks: [Ask] {
        var all = asks
        if let open = model.fleet.machineState(for: key.machine)?.openAsk(forDoc: key.id), !all.contains(where: { $0.askID == open.askID }) { all.append(open) }
        return all
    }

    private func pushForms(_ doc: Document) {
        let blocked = model.writeBlock(key.machine, "送信できません")?.text
        web?.setForms(DocumentForms.payload(asks: formAsks, drafts: doc.drafts, canWrite: model.canWrite(key.machine), blocked: blocked, textSize: bodyTextSize))
    }

    /// 欄の位置まで送る（狭い幅でコメントを出していれば本文に切り替える）
    private func focusForm(_ slot: String?) {
        if width < DocumentMetrics.bodyMinWidth + DocumentMetrics.comments.lowerBound { showsComments = false }
        guard let slot else { return }
        web?.scroll(toForm: slot)
    }

    private func handleForm(_ action: DocumentFormAction, doc: Document) {
        switch action {
        case .answer(let id, let answers):
            guard let ask = formAsks.first(where: { $0.askID == id }) else { return }
            Task {
                do {
                    try await model.answer(ask, answers)
                    web?.formResult(kind: "ask", id: "\(id)", error: nil)
                    await loadSide(task: TaskKey(machine: doc.machine, number: doc.taskNumber))
                } catch {
                    web?.formResult(kind: "ask", id: "\(id)", error: UserFacingError("回答を送信できませんでした", error: error)?.text)
                }
            }
        case .cancel(let id):
            guard let ask = formAsks.first(where: { $0.askID == id }) else { return }
            Task {
                do {
                    try await model.cancelAsk(ask)
                    web?.formResult(kind: "ask", id: "\(id)", error: nil)
                    await loadSide(task: TaskKey(machine: doc.machine, number: doc.taskNumber))
                } catch {
                    web?.formResult(kind: "ask", id: "\(id)", error: UserFacingError("質問を閉じられませんでした", error: error)?.text)
                }
            }
        case .approve(let id, let body):
            guard let draft = model.fleet.document(for: key)?.drafts.first(where: { $0.id == id }) else { return }
            approving = Approving(draft: draft, body: body)
        }
    }

    private func approve(_ item: Approving) {
        Task {
            do {
                try await model.approveDocDraft(key, draft: item.draft.id, body: item.body)
            } catch {
                web?.formResult(kind: "draft", id: item.draft.id, error: UserFacingError("送る文面を承認できませんでした", error: error)?.text)
            }
        }
    }

    private func commentToggle(commentsShown: Bool) -> some View {
        Button {
            showsComments = !commentsShown
        } label: {
            Label("コメント", systemImage: "sidebar.trailing")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .hitTarget()
        .accessibilityValue(commentsShown ? "開いています" : "閉じています")
        .help(commentsShown ? "コメントを非表示" : "コメントを表示")
    }

    private func moreMenu(_ doc: Document) -> some View {
        Menu {
            if supportsMultipleWindows && !inWindow {
                Button("別ウインドウで開く", systemImage: "macwindow.on.rectangle") { openWindow(value: key) }
            }
            Button(content?.format == .html ? "HTMLをコピー" : "Markdownをコピー", systemImage: "doc.on.doc") { copyContent() }
                .disabled(content == nil)
            Button("PDFで保存…", systemImage: "arrow.down.doc") { Task { await exportPDF() } }
                .disabled(content == nil)
            if model.canWrite(key.machine) {
                Divider()
                Button("文書を削除…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
        } label: {
            Label("その他", systemImage: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("その他")
    }

    /// 質問・コメント・レビュー依頼があればコメントの欄を開いて出す
    private func defaultShowsComments(_ doc: Document) -> Bool {
        doc.openComments > 0 || doc.draftComments > 0
            || model.fleet.machineState(for: key.machine)?.reviewRequests[TaskKey(machine: doc.machine, number: doc.taskNumber)] != nil
            || composer != nil
    }

    @ViewBuilder
    private func reader(_ doc: Document) -> some View {
        Group {
            if let blocked = model.writeBlock(key.machine, "本文を表示できません") {
                EmptyState(blocked.event, symbol: "doc.text", message: blocked.detail)
            } else if let failure = web?.failure ?? contentFailure {
                EmptyState(title: "本文を表示できません", symbol: "exclamationmark.triangle", message: failure.detail) {
                    if web?.failure == nil { Button("再読み込み") { Task { await loadContent() } } }
                }
            } else if let web {
                DocumentWebView(controller: web)
                    .overlay { if content == nil { ProgressView("読み込み中…") } }
                    .overlay {
                        if model.canWrite(key.machine), content != nil, floating == nil {
                            FloatingCommentButton(web: web) { rect in Task { await startFloatingComment(at: rect) } }
                        }
                    }
                    .popover(item: $floating, attachmentAnchor: .rect(.rect(floatingRect)), arrowEdge: .bottom) { _ in
                        CommentComposer(composer: Binding(get: { floating ?? Composer() }, set: { floating = $0 }), submit: submitFloatingComment) {
                            floating = nil
                            web.clearSelection()
                        }
                        #if os(macOS)
                        .frame(width: DocumentMetrics.comments.upperBound)
                        #else
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium])
                        #endif
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func commentsPane(_ doc: Document, task: TaskKey) -> some View {
        let draftCount = comments.filter { $0.state == .draft }.count + comments.flatMap(\.replies).filter { $0.state == .draft }.count
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.section) {
                    if let sideFailure {
                        Banner(kind: .error, message: sideFailure.text) {
                            Button("再読み込み") { Task { await loadSide(task: task) } }.controlSize(.small)
                        }
                    }
                    // 答えるのは本文の欄。ここは回答の状況と、欄へ送る入口だけ
                    if let open = openAsk {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Label(String(localized: "質問\(open.questions.count)件の回答待ち"), systemImage: "questionmark.bubble")
                                .font(.callout).foregroundStyle(.orange)
                            Spacer(minLength: Space.row)
                            Button("質問へ移動") { focusForm(AppModel.formSlot(for: open)) }.controlSize(.small)
                        }
                    }
                    let answered = asks.filter { $0.status == .answered }
                    if !answered.isEmpty {
                        AnsweredAsks(asks: answered)
                    }
                    if composer != nil {
                        CommentComposer(composer: Binding(get: { composer ?? Composer() }, set: { composer = $0 }), submit: submitComment) {
                            composer = nil
                            web?.clearSelection()
                        }
                    }
                    CommentsSection(comments: $comments, machine: key.machine, active: $activeComment) { id in
                        // 引用を押したら本文へ（狭い幅では本文に切り替える）
                        activeComment = activeComment == id ? nil : id
                        if width < DocumentMetrics.bodyMinWidth + DocumentMetrics.comments.lowerBound { showsComments = false }
                    }
                }
                .padding(Space.block)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            ReviewComposer(task: task, draftCount: draftCount) { await loadSide(task: task) }
                .padding(Space.block)
        }
        .background(.background.secondary)
    }

    private func close() {
        if inSheet { model.closeDoc() }
        dismiss()
    }

    /// 同じタスクの文書の並び（`DocumentList` と同じ）
    private var sequence: DocumentSequence { DocumentSequence(model: model, current: key) }

    private func switchDocument(to next: DocKey) {
        if let switchTo { switchTo(next) } else { model.openDoc = next }
    }

    /// Esc。パネルでは文書だけを閉じてタスクの中身に戻り（パネルは開いたまま）、iPhone のシートはシートを閉じる。
    /// 切り替えで移ってきても、前の文書には戻らない
    private func escape() {
        switch DocumentEscape.action(composerText: composer?.text, pendingInput: pendingInput) {
        case .closeComposer:
            composer = nil
            web?.clearSelection()
        case .keep:
            break
        case .closeDocument:
            if inSheet { close() } else { model.closeDoc() }
        }
    }

    // MARK: 読み込み

    /// 未回答の質問が変わったら読み直す（回答すると状態が変わる）
    private var askSignature: String {
        let asks = model.fleet.machineState(for: key.machine)?.asks.values.filter { $0.docID == key.id } ?? []
        return asks.sorted { $0.askID < $1.askID }.map { "\($0.askID):\($0.status.rawValue)" }.joined(separator: ",")
    }

    /// 本文と版。失敗しても、コメントの欄はそのまま出す
    private func loadContent() async {
        guard let web, model.canWrite(key.machine) else { return }
        do {
            async let revisions = model.documentRevisions(key)
            let fetched = try await model.documentContent(key, rev: selectedRev)
            self.revisions = (try? await revisions) ?? self.revisions
            contentFailure = nil
            if content?.rev != fetched.rev || content?.content != fetched.content {
                content = fetched
                web.load(content: fetched, highlights: highlightItems(), textSize: bodyTextSize)
            } else {
                pushHighlights()
            }
        } catch {
            contentFailure = UserFacingError("本文を読み込めませんでした", error: error)
        }
    }

    /// コメントと質問。失敗しても本文は消さない
    private func loadSide(task: TaskKey) async {
        guard model.canWrite(key.machine) else { return }
        do {
            async let comments = model.comments(key)
            async let asks = model.asks(task: task)
            let loaded = (try await comments, try await asks)
            self.comments = loaded.0
            self.asks = loaded.1.filter { $0.docID == key.id }
            sideFailure = nil
        } catch {
            sideFailure = UserFacingError("コメントと質問を読み込めませんでした", error: error)
        }
    }

    private func highlightItems() -> [DocumentWebController.HighlightItem] {
        comments.compactMap { comment in
            guard let anchor = comment.anchor, comment.state != .resolved, comment.rev == (content?.rev ?? comment.rev) else { return nil }
            return DocumentWebController.HighlightItem(id: comment.id, anchor: anchor)
        }
    }

    private func pushHighlights() {
        web?.setHighlights(highlightItems(), active: activeComment)
        if let activeComment { web?.scroll(to: activeComment) }
    }

    // MARK: コメント

    private func startComment() async {
        let anchor = await web?.selection()
        composer = Composer(anchor: anchor)
        showsComments = true
    }

    /// 浮かせた［コメント］から、選んだ所に重ねて書く
    private func startFloatingComment(at rect: CGRect) async {
        guard let anchor = await web?.selection() else { return }
        floatingRect = rect
        floating = Composer(anchor: anchor)
    }

    /// 失敗したら書いた文を残し、入力欄の下に知らせる
    private func submitComment(_ draft: Composer) async {
        if let failure = await addComment(draft) { composer?.failure = failure } else { composer = nil }
    }

    private func submitFloatingComment(_ draft: Composer) async {
        if let failure = await addComment(draft) { floating?.failure = failure } else { floating = nil }
    }

    /// 足せたら一覧に入れて選択を外す。足せなければ知らせる文を返す
    private func addComment(_ draft: Composer) async -> UserFacingError? {
        guard let content, !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            let added = try await model.addComment(key, rev: content.rev, anchor: draft.anchor, body: draft.text)
            comments.append(added)
            web?.clearSelection()
            return nil
        } catch {
            return UserFacingError("コメントを追加できませんでした", error: error)
        }
    }

    private func delete() {
        Task {
            do {
                try await model.deleteDocument(key)
                if inSheet || inWindow { dismiss() }
            } catch {
                model.fail("文書を削除できませんでした", error, in: window)
            }
        }
    }
}

/// 文書の PDF の書き出し（`fileExporter` に渡す）
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
