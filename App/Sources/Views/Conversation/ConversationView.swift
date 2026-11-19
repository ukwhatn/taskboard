import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// host の会話の画面。会話の列・質問と権限のカード・画像の帯・入力欄に、
/// 生成中の返答・先に出した発言・停止・計画の承認・起こせなかった会話の帯を足す。
/// 上に端末・フォルダ・差分の帯、入力欄の下にモデル・effort・権限・コネクタ・コンテキストの欄、発言のメニューにフォークと巻き戻し、
/// シェルのコードの塊に［実行］を置く。画面が出ていて scene が裏に入っていない間だけ購読する
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    @Environment(\.scenePhase) private var scenePhase
    let key: ConversationKey
    let feed: ConversationFeed

    /// 入力欄の初めの文（snapshot 用）。打った文とカーソルは `ConversationComposerArea` が持つ（ここで持つと、1 打鍵ごとに会話の画面の全体と一覧が走った）
    private let initialDraft: String
    @State private var failure: UserFacingError?
    /// 打ったコマンドが会話では使えない案内（次に送るか、閉じると消える）
    @State private var unsupported: ConversationUnsupportedCommand?
    @State private var interrupting = false
    @State private var choosingFiles = false
    /// scene が裏に入って購読をやめている
    @State private var paused = false
    /// 発言のメニューのボタンを出しておく発言（snapshot 用）
    private let revealedMenu: String?
    /// 環境・コンテキスト・コネクタを置く詳細の欄が隣にある（タスクのパネル）。無ければ上の帯の［状態］から出す
    private let detailsBeside: Bool
    /// 会話の頭と入力欄の上に部品を描くタスク（タスクのパネルの左の会話だけ）
    private let partsTask: TaskKey?
    @AppStorage(AppPreferences.chatFontSizeKey) private var fontSize = SessionTextSize.chatDefault
    @FocusState private var composerFocused: Bool
    /// 入力欄の帯が出たらフォーカスを当てる（帯は画面より 1 回あとに組むので、画面の onAppear では欄がまだ無い）
    @State private var focusesComposer = false
    @State private var search = ChatSearch()
    @FocusState private var searchFocused: Bool
    @State private var actionsOwner = UUID()
    /// ⌥⌘↑・⌥⌘↓ で前・次の人の発言へ送る要求
    @State private var jump = ChatJumpRequest()
    /// ファイルの欄で開いているファイル（発言の札で選ぶ）
    @State private var openFile: ChatFileRef?
    /// 会話の欄の高さ。問いのカードの高さの上限（半分）に使う
    @State private var height: CGFloat = 0

    /// `draft`・`revealedMenu`・`openFile` は snapshot 用（入力欄の文、ボタンを出しておく発言、開いた状態で出すファイル）
    init(
        key: ConversationKey, feed: ConversationFeed, detailsBeside: Bool = false, partsTask: TaskKey? = nil, draft: String = "", revealedMenu: String? = nil,
        openFile: ChatFileRef? = nil
    ) {
        self.key = key
        self.feed = feed
        self.detailsBeside = detailsBeside
        self.partsTask = partsTask
        self.revealedMenu = revealedMenu
        initialDraft = draft
        _openFile = State(initialValue: openFile)
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ConversationView")
        #endif
        let size = SessionTextSize.clamp(fontSize)
        let conversation = model.fleet.conversation(for: key)
        // この版が操作の仕方を知らない engine の会話は、操作の帯と入力欄を出さずに案内だけを出す
        let openable = conversation.map { $0.engine != .unknown } ?? true
        VStack(spacing: 0) {
            if let conversation, feed.phase != .removed, openable, !AppModel.isPhone {
                topBar(conversation)
                Divider()
            }
            if let partsTask, feed.phase != .removed, openable {
                PanelHead(task: partsTask, maxHeight: height / 3)
            }
            if search.isOpen {
                ConversationSearchBar(feed: feed, search: $search, size: size, focused: $searchFocused)
                    .readableColumn(ReadableWidth.chat)
                    .padding(.horizontal, inset)
                Divider()
            }
            switch ConversationContent.of(
                removed: feed.phase == .removed || (conversation == nil && feed.phase != .fixture), openable: openable, isEmpty: feed.isEmpty,
                hasMessages: !feed.messages.isEmpty, historyState: feed.historyState, historyFailed: feed.historyFailure != nil)
            {
            case .missing:
                EmptyState("この会話はありません", symbol: "text.bubble", message: "記録が削除されたか、接続していないMacの会話です。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unopenable:
                EmptyState("この会話は開けません", symbol: "text.bubble", message: "このアプリが対応していない種類の会話です。アプリを更新してください。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loading:
                ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loadFailed:
                EmptyState(title: feed.historyFailure?.event ?? "", symbol: "exclamationmark.triangle", message: feed.historyFailure?.detail) {
                    Button("再読み込み") { feed.loadLatest() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                EmptyState("メッセージはありません", symbol: "text.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .transcript:
                ConversationTranscript(
                    feed: feed, fontSize: size, search: search.isOpen ? search : nil, messageActions: conversation.map(messageActions), codeRun: codeRun,
                    queuesMessages: conversation?.engine.queuesMessages ?? false, openedFile: openFile?.id, openFile: { openFile = $0 },
                    activity: ConversationActivity(conversation),
                    stopGenerating: interrupting || !model.canWrite(key.machine) ? nil : { interrupt() },
                    backgroundTasks: ChatBackgroundTasks(conversation: conversation), jump: jump)
                .equatable()
            }
            if let conversation, feed.phase != .removed, openable {
                // 会話の一覧より先に高さを取る（取らないと、狭いときに問いのカードが潰れる）
                DeferredMount {
                    bottom(conversation, size: size)
                        .onAppear {
                            guard focusesComposer else { return }
                            focusesComposer = false
                            composerFocused = true
                        }
                }
                .layoutPriority(1)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        #if os(iOS)
        // iPhone は題と上の帯の操作を戻るボタンの行に置き、タブバーを隠して会話に高さを回す。状態と欄はシートで開く
        .toolbar {
            if AppModel.isPhone, let conversation {
                ToolbarItem(placement: .principal) { PhoneConversationTitle(conversation: conversation) }
                if feed.phase != .removed, openable {
                    ToolbarItem(placement: .topBarTrailing) { topBar(conversation, inNavigationBar: true) }
                }
            }
        }
        .navigationBarTitleDisplayMode(AppModel.isPhone ? .inline : .automatic)
        .toolbar(AppModel.isPhone ? .hidden : .automatic, for: .tabBar)
        .modifier(PhoneConversationSheets(conversation: conversation, feed: feed, fail: { failure = $0 }))
        #endif
        .chatFilePane(feed, selection: $openFile, fontSize: size)
        .sheet(item: Binding(get: { feed.sheet }, set: { feed.sheet = $0 })) { sheet in
            sheetContent(sheet, conversation: conversation)
        }
        .chatInput(
            item: key, actions: .chat(owner: actionsOwner, search: $search, searchFocused: $searchFocused, conversation: menuActions), composerFocused: $composerFocused, addImages: addImages,
            addFiles: addDroppedFiles)
        .onAppear {
            feed.start()
            model.activeConversation = feed
            #if os(macOS)
            focusesComposer = true
            #endif
        }
        .onDisappear {
            if !paused { feed.stop() }
            paused = false
        }
        // 2 つ並べているときは、打っている側を今の会話にする
        .onChange(of: composerFocused) { _, focused in
            if focused { model.activeConversation = feed }
        }
        .onChange(of: model.chatSearchRequest, initial: true) { _, request in
            guard let request, request.key == key else { return }
            search = ChatSearch(isOpen: true, query: request.query)
            model.chatSearchRequest = nil
        }
        .onChange(of: scenePhase) { _, phase in
            // 裏に入ったら購読をやめ、戻ったら手元の seq から続きを読む
            if phase == .background, !paused {
                paused = true
                feed.stop()
            } else if phase == .active, paused {
                paused = false
                feed.start()
            }
        }
    }

    private func topBar(_ conversation: Conversation, inNavigationBar: Bool = false) -> ConversationTopBar {
        ConversationTopBar(
            conversation: conversation, generating: feed.isGenerating, perform: { perform($0, conversation) },
            terminalOpen: model.terminalDock(for: key) != nil, toggleTerminal: { toggleShell(conversation) },
            undoRewind: { undoRewind() }, redoRewind: { redoRewind() }, info: detailsBeside ? .sidePane { showInfo() } : .popover(feed),
            inNavigationBar: inNavigationBar)
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ConversationSheet, conversation: Conversation?) -> some View {
        switch sheet {
        case .diff:
            ConversationDiffScreen(feed: feed)
                .environment(model)
                .dismissOnOutsideClick { feed.sheet = nil }
                #if os(macOS)
                .frame(
                    minWidth: ChatFileMetrics.sheet.width, idealWidth: ChatFileMetrics.sheetIdeal.width, maxWidth: ChatFileMetrics.sheetMax.width,
                    minHeight: ChatFileMetrics.sheet.height, idealHeight: ChatFileMetrics.sheetIdeal.height, maxHeight: ChatFileMetrics.sheetMax.height)
                #endif
        case .rewind(let message):
            if let conversation {
                ConversationRewindSheet(message: message, conversation: conversation, feed: feed).environment(model)
            }
        case .terminal(let pane):
            ConversationTerminalSheet(key: TerminalKey(machine: key.machine, pane: pane)).environment(model)
        case .connectors:
            if let conversation {
                ConversationConnectorsSheet(conversation: conversation, feed: feed).environment(model)
            }
        case .context:
            if let conversation {
                ConversationContextSheet(conversation: conversation, feed: feed)
            }
        case .readout(let readout):
            if let conversation {
                ConversationReadoutSheet(readout: readout, conversation: conversation, feed: feed)
            }
        case .tasks:
            if let conversation {
                ConversationTasksSheet(conversation: conversation, feed: feed)
            }
        case .sideQuestion(let question):
            if let conversation {
                ConversationSideQuestionSheet(conversation: conversation, feed: feed, question: question)
            }
        case .folder(let action, let path):
            if let conversation {
                ConversationFolderSheet(action: action, conversation: conversation, feed: feed, path: path)
            }
        case .login:
            if let conversation {
                ConversationLoginSheet(
                    conversation: conversation, feed: feed, thisMac: model.isThisMac(conversation.machine), machineName: model.machineName(conversation.machine))
            }
        }
    }

    @ViewBuilder
    private func bottom(_ conversation: Conversation, size: Double) -> some View {
        let blocked = model.writeBlock(key.machine, "送信できません")
        VStack(spacing: Space.row) {
            // 問いのカードは会話の欄の半分まで（キーボードで狭まれば、入力欄を置いた残りまで）。長い質問はカードの中で送る
            if let request = conversation.requests.first, AppModel.isPhone, composerFocused {
                ConversationRequestStrip(request: request) { composerFocused = false }
            } else if let request = conversation.requests.first {
                ScrollView {
                    ConversationRequestPanel(
                        request: request, machine: key.machine, blocked: blocked,
                        fetchURL: { try await feed.elicitationURL($0) }
                    ) { answer in
                        try await feed.answer(answer)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .cappedHeight(height > 0 ? height / 2 : .infinity)
                .id(request.id)
            }
            if let resumeAt = conversation.limitResumeAt {
                let time = resumeAt.formatted(date: .omitted, time: .shortened)
                Banner(
                    kind: .pending,
                    message: conversation.limitPaused
                        ? String(localized: "利用枠が残り少ないため、\(time)まで待ちます。") : String(localized: "利用枠の上限に達しました。\(time)に続きを送ります。")
                ) {
                    Button("取り消す") { cancelLimitResume() }
                }
            } else if conversation.networkResume == true {
                Banner(kind: .pending, message: String(localized: "APIに接続できませんでした。ネットワークの接続が戻ったら続きを送ります。")) {
                    Button("取り消す") { cancelLimitResume() }
                }
            } else if let failure = conversation.stoppedFailure {
                Banner(kind: .error, message: failure.text)
            }
            if conversation.rewindIncomplete {
                Banner(kind: .error, message: String(localized: "巻き戻しでファイルを戻せたか確かめられませんでした。差分を確認してから送信してください。")) {
                    Button("差分を表示") { showDiff() }
                    if conversation.canUndoRewind { Button("元に戻す") { undoRewind() } }
                }
            } else if model.rewindNoticeDismissals.shows(for: conversation) {
                Banner(kind: .notice, message: rewindNotice, onClose: { model.rewindNoticeDismissals.dismiss(conversation) }) {
                    Button("元に戻す") { undoRewind() }
                }
            }
            if feed.phase == .disconnected {
                Banner(kind: .notice, message: UserFacingError.reconnecting)
            }
            if let historyFailure = feed.historyFailure, !feed.messages.isEmpty {
                Banner(kind: .error, message: historyFailure.text) {
                    Button("再読み込み") { feed.loadLatest() }
                }
            }
            if let failure {
                Banner(kind: .error, message: failure.text, onClose: { self.failure = nil })
            }
            if let unsupported {
                ConversationUnsupportedBanner(command: unsupported) { self.unsupported = nil }
            }
            if let plan = conversation.plan, ConversationPlanCard.shows(plan) {
                ConversationPlanCard(items: plan, fonts: ChatFonts(size: size))
            }
            let queued = conversation.engine.queuesMessages ? feed.outgoing.filter { $0.state == .queued } : []
            if !queued.isEmpty {
                ConversationQueueCard(
                    messages: queued, fonts: ChatFonts(size: size), sendNow: { try await feed.sendNow($0) },
                    detachesTools: (conversation.detachableTools ?? 0) > 0, cancel: { try await feed.cancelQueued($0, edit: $1) }, paused: conversation.queuePaused == true,
                    canSend: blocked == nil, failed: { failure = $0 })
            }
            if !images.isEmpty {
                ChatImageStrip(images: images) { removed in model.setChatImages(images.filter { $0.id != removed.id }, for: key) }
            }
            if !files.isEmpty {
                ChatDraftFileStrip(
                    files: files, fonts: ChatFonts(size: size),
                    remove: { removed in model.setChatFiles(files.filter { $0.id != removed.id }, for: key) },
                    restore: { restorePastedText($0) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let partsTask {
                PanelComposerDrafts(task: partsTask, maxHeight: height > 0 ? height / 3 : .infinity)
            }
            ConversationComposerArea(
                key: key, conversation: conversation, feed: feed, drafts: model.chatDrafts, initialDraft: initialDraft, size: size, writable: blocked == nil,
                focused: $composerFocused, interrupting: interrupting, interrupt: { interrupt() }, attach: { choosingFiles = true },
                addImages: { addImages($0) }, perform: { perform($0, conversation, argument: $1) }, failed: { failure = $0 },
                unsupported: { unsupported = $0 }, forkSend: conversation.engine.supports(ConversationOperation.fork) ? { await forkAndSend($0, images: $1, files: $2) } : nil)
            if !AppModel.isPhone {
                ConversationControlBar(conversation: conversation, feed: feed) { failure = $0 }
            }
        }
        .chatInputColumn(inset: inset, addImages: addImages, addFiles: addDroppedFiles)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: addFiles)
    }

    private var images: [ChatDraftImage] { model.chatImages(for: key) }
    private var files: [ChatDraftFile] { model.chatFiles(for: key) }

    private var rewindNotice: String {
        guard let skipped = feed.skippedLinks, skipped > 0 else { return String(localized: "会話を巻き戻しました。") }
        return String(localized: "会話を巻き戻しました。シンボリックリンクの\(skipped)件は戻していません。")
    }

    // MARK: taskboard の操作

    /// 端末で開いている会話は、会話の下（タスクの画面は会話と右の欄の下）の端末の欄に開く。iPhone は欄を置かないのでシート
    /// 上の帯の［ターミナル］。Mac と iPad は端末の欄を開け閉めし（開くと作業フォルダのシェルを起こし、閉じると止める）、iPhone はシートで開く
    private func toggleShell(_ conversation: Conversation) {
        if AppModel.isPhone {
            perform(.shell, conversation)
        } else {
            model.toggleTerminal(for: key)
        }
    }

    /// 差分と情報は、右の欄が隣にあれば（タスクの画面）その欄を切り替え、無ければシートとポップオーバー
    private func showDiff() {
        feed.loadDiff()
        if detailsBeside {
            model.showSidePane(.changes, for: key)
        } else {
            feed.sheet = .diff
        }
    }

    private func showInfo(section: String? = nil) {
        if detailsBeside {
            model.showSidePane(.status, for: key, section: section)
        } else {
            feed.showsInfo = true
        }
    }

    /// `argument` は `/btw 質問` のように打った引数（引数を取る操作だけが使う）
    func perform(_ action: ConversationTaskboardAction, _ conversation: Conversation, argument: String = "") {
        switch action {
        case .fork:
            fork(from: nil)
        case .rewind:
            guard let target = ChatRewindRange.last(in: feed.messages) else {
                failure = UserFacingError("巻き戻せませんでした", cause: String(localized: "巻き戻せるメッセージがありません"))
                return
            }
            feed.sheet = .rewind(target)
        case .shell:
            if AppModel.isPhone {
                run("シェルを開けませんでした") { feed.sheet = .terminal(try await feed.shell()) }
            } else {
                model.openTerminal(for: key)
            }
        case .diff:
            showDiff()
        case .status, .cost, .usage:
            showInfo()
        case .export:
            feed.sheet = .readout(.export)
        case .permissions:
            feed.sheet = .readout(.permissions)
        case .hooks:
            feed.sheet = .readout(.hooks)
        case .memory:
            feed.sheet = .readout(.memory)
        case .skills:
            feed.sheet = .readout(.skills)
        case .tasks:
            feed.sheet = .tasks
        case .btw:
            feed.sheet = .sideQuestion(argument)
        case .addDir:
            feed.sheet = .folder(.add, argument)
        case .cd:
            feed.sheet = .folder(.change, argument)
        case .login:
            feed.sheet = .login
        case .plugin:
            feed.sheet = .readout(.plugins)
        case .compact:
            run("会話を圧縮できませんでした") { try await feed.control(ConversationControlRequest(kind: .compact)) }
        case .rename:
            rename(argument)
        case .new:
            run("新しく始められませんでした") { try await feed.control(ConversationControlRequest(kind: .newThread)) }
        case .review:
            run("レビューを始められませんでした") { try await feed.control(ConversationControlRequest(kind: .review, value: argument)) }
        case .exit:
            model.close(conversation: conversation.key)
        }
    }

    /// `/rename <名前>`。MCP の `session_rename` と同じ制御で送る
    private func rename(_ argument: String) {
        let event: LocalizedStringResource = "名前を変更できませんでした"
        guard let title = ConversationInput.title(argument) else {
            failure = UserFacingError(event, cause: String(localized: "名前がありません"), remedy: String(localized: "「/rename」に続けて名前を書き、送信してください"))
            return
        }
        guard ConversationInput.acceptsTitle(title) else {
            failure = UserFacingError(
                event, cause: String(localized: "名前が長すぎるか、改行を含んでいます"),
                remedy: String(localized: "改行なしの\(ConversationInput.titleLimit)文字以内にしてください"))
            return
        }
        run(event) { try await feed.control(ConversationControlRequest(kind: .rename, value: title)) }
    }

    private func messageActions(_ conversation: Conversation) -> ChatMessageActions {
        let busy = conversation.phase == .running || conversation.phase == .starting || feed.isGenerating
        let blocked: String? =
            if busy { String(localized: "応答が終わると巻き戻せます") }
            else if !conversation.requests.isEmpty { String(localized: "質問か確認に答えると巻き戻せます") }
            else { nil }
        return ChatMessageActions(
            fork: { fork(from: $0.id) }, rewind: conversation.engine.supports(.rewind) ? { feed.sheet = .rewind($0) } : nil, rewindBlocked: blocked,
            revealed: revealedMenu,
            forkPoints: model.fleet.forks(of: conversation).compactMap(\.forkAt),
            showForks: { showInfo(section: ConversationInspector.forksAnchor) })
    }

    private var codeRun: CodeRunActions {
        CodeRunActions(
            entry: { feed.runs.latest(messageID: $0, code: $1) },
            start: { code, language, messageID in
                run("実行できませんでした") { try await feed.startRun(code: code, language: language, messageID: messageID) }
            },
            cancel: { id in run("実行を停止できませんでした") { try await feed.cancelRun(id) } },
            reset: { run("シェルを再起動できませんでした") { try await feed.resetRuns() } })
    }

    /// メニューの［会話］。項目は常に有効なので、engine に無い操作は何もしない
    private var menuActions: ConversationMenuActions {
        ConversationMenuActions(
            fork: {
                guard model.fleet.conversation(for: key)?.engine.supports(ConversationOperation.fork) == true else { return }
                fork(from: nil)
            },
            openField: { feed.openField = $0 },
            jump: { forward in
                jump.forward = forward
                jump.token += 1
            },
            end: {
                guard model.canWrite(key.machine) else { return }
                model.close(conversation: key)
            })
    }

    /// フォークした会話はすぐ起き、同じタスクのパネルで開く
    private func fork(from messageID: String?) {
        run("フォークできませんでした") {
            let forked = try await feed.fork(from: messageID)
            model.navigate(to: .conversation(forked.key), from: .app)
        }
    }

    /// 末尾からフォークした会話に送り、その会話を開く（⌥⌘↩）。フォークできなければ false（入力欄の文は残す）
    private func forkAndSend(_ text: String, images: [ChatDraftImage], files: [ChatDraftFile]) async -> Bool {
        failure = nil
        do {
            let forked = try await feed.fork(from: nil)
            model.conversationFeed(for: forked.key).send(text, images: images, files: files)
            Task { model.navigate(to: .conversation(forked.key), from: .app) }
            return true
        } catch {
            failure = UserFacingError("フォークできませんでした", error: error)
            return false
        }
    }

    private func cancelLimitResume() {
        run("続きを送る予定を取り消せませんでした") { try await feed.control(ConversationControlRequest(kind: .cancelLimitResume)) }
    }

    private func undoRewind() {
        guard let conversation = model.fleet.conversation(for: key) else { return }
        run("巻き戻しを元に戻せませんでした") { try await feed.undoRewind(agentSessionID: conversation.agentSessionID) }
    }

    private func redoRewind() {
        guard let conversation = model.fleet.conversation(for: key) else { return }
        run("巻き戻しをやり直せませんでした") { try await feed.redoRewind(agentSessionID: conversation.agentSessionID) }
    }

    private func run(_ event: LocalizedStringResource, _ operation: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do {
                try await operation()
            } catch {
                failure = UserFacingError(event, error: error)
            }
        }
    }

    private func interrupt() {
        interrupting = true
        Task {
            do {
                try await feed.interrupt()
            } catch {
                failure = UserFacingError("生成を停止できませんでした", error: error)
            }
            interrupting = false
        }
    }

    private func addFiles(_ result: Result<[URL], any Error>) {
        Task {
            switch result {
            case .success(let urls):
                if let problem = await model.addChatFiles(urls, for: key) { failure = problem }
            case .failure(let error):
                failure = UserFacingError("ファイルを添付できませんでした", error: error)
            }
        }
    }

    /// ドロップと ⌘V で受けたファイルとフォルダ（［ファイルを添付］と同じ下書きへ）
    private func addDroppedFiles(_ urls: [URL]) async {
        if let problem = await model.addChatFiles(urls, for: key) { failure = problem }
    }

    /// 添付にした貼り付けを入力欄に戻す（戻せる長さまで）。入力欄は今の文の前に足す（`restoredDrafts`）
    private func restorePastedText(_ file: ChatDraftFile) {
        guard let text = file.pastedText else { return }
        guard text.utf16.count <= ChatAttachment.pastedTextRestoreLimit else {
            failure = UserFacingError(
                "入力欄に戻せませんでした", cause: String(localized: "貼り付けた文が\(ChatAttachment.pastedTextRestoreLimit)字を超えています"))
            return
        }
        feed.restoredDrafts.append(RestoredDraft(text: text))
        model.setChatFiles(files.filter { $0.id != file.id }, for: key)
    }

    private func addImages(_ incoming: [Data]) {
        Task {
            if let problem = await model.addChatImages(incoming, for: key) { failure = problem }
        }
    }
}

/// `/` の候補に並べる taskboard の操作と欄の説明
enum ConversationSlashText {
    static func description(_ action: ConversationTaskboardAction) -> String {
        switch action {
        case .fork: String(localized: "会話の末尾までを新しい会話にフォークします")
        case .rewind: String(localized: "最後のメッセージの前まで巻き戻します")
        case .shell: String(localized: "作業フォルダのシェルを開きます")
        case .diff: String(localized: "作業フォルダの差分を表示します")
        case .status: String(localized: "会話ID・モデル・バージョン・利用枠を表示します")
        case .cost: String(localized: "会話の費用とトークンを表示します")
        case .usage: String(localized: "利用枠を表示します")
        case .export: String(localized: "会話をテキストで書き出します")
        case .tasks: String(localized: "バックグラウンドのタスクを表示します")
        case .permissions: String(localized: "権限の規則を表示します")
        case .hooks: String(localized: "フックを表示します")
        case .memory: String(localized: "読み込んでいるメモリのファイルを表示します")
        case .skills: String(localized: "スキルを表示します")
        case .btw: String(localized: "会話に残さずに質問します")
        case .addDir: String(localized: "作業フォルダを追加します")
        case .cd: String(localized: "作業フォルダを移動します")
        case .login: String(localized: "Claudeのアカウントにログインします")
        case .plugin: String(localized: "プラグインとマーケットプレイスを管理します")
        case .compact: String(localized: "会話を圧縮します")
        case .rename: String(localized: "会話の名前を変更します")
        case .new: String(localized: "履歴を引き継がずに、新しく始めます")
        case .review: String(localized: "未コミットの変更をレビューします")
        case .exit: String(localized: "会話を終了します")
        }
    }

    static func description(_ field: ConversationControlField) -> String {
        switch field {
        case .model: String(localized: "モデルを選びます")
        case .effort: String(localized: "エフォートを選びます")
        case .mcp: String(localized: "コネクタの一覧を表示します")
        case .context: String(localized: "コンテキストの内訳を表示します")
        }
    }
}

/// 会話の画面の真ん中に出すもの。最初の履歴を待っている間は、生成中の差分や先に出した発言が届いていても読み込み中を出す
/// （履歴の取得に 30 秒かかった回に、生成中の差分だけの列が出て、欄が白いままに見えた）
enum ConversationContent: Equatable {
    case missing, unopenable, loading, loadFailed, empty, transcript

    static func of(removed: Bool, openable: Bool, isEmpty: Bool, hasMessages: Bool, historyState: ConversationTimeline.HistoryState, historyFailed: Bool) -> Self {
        if removed { return .missing }
        if !openable { return .unopenable }
        if !hasMessages, historyState == .notLoaded { return historyFailed ? .loadFailed : .loading }
        return isEmpty ? .empty : .transcript
    }
}

enum ConversationMetrics {
    /// 計画の本文を出す高さの上限（それより長ければカードの中でスクロールする）
    static let planHeight: CGFloat = 240
    /// コードの塊の Run の出力を出す高さの上限
    static let runOutputHeight: CGFloat = 240
    /// 入力欄の下の欄の幅
    static let fieldWidth: ClosedRange<CGFloat> = 240...360
    /// コネクタのシートの高さ（Mac）。Form は中身の高さを小さく答えるので、十数行が並ぶ高さを取る
    static let connectorsSheetHeight: CGFloat = 560
    /// コンテキストの内訳のシートの高さ（Mac）。合計の 3 行と区分の 10 行ほど
    static let contextSheetHeight: CGFloat = 520
    /// 巻き戻しの確認で名前を並べるファイルの数。残りは「ほかN件」
    static let rewindFileLimit = 6
    /// 差分の画面で一覧と diff を並べる幅、一覧の幅
    static let diffSideBySideWidth: CGFloat = 640
    static let diffListWidth: CGFloat = 300
    /// コメントを付けた diff の行の左端の印の幅
    static let diffCommentMark: CGFloat = 3
    /// 選んだ行に重ねるコメントの欄の幅（Mac）
    static let diffCommentWidth: CGFloat = 380
    /// 端末のシート（Mac）の最小と普段の大きさ
    static let terminalSheet = CGSize(width: 640, height: 420)
    static let terminalSheetIdeal = CGSize(width: 960, height: 640)
}

