import SwiftUI
import TaskboardKit

/// 会話の入力欄と、その上の `/` の候補。打った文とカーソルは画面ではここだけが持つ（会話の画面が持つと、1 打鍵・カーソルの 1 移動ごとに画面の全体と発言の一覧が走った）。
/// 書きかけは会話ごとに `ChatDraftTexts` へ書き戻し、開き方を替えたり別のセッションへ移ったりして作り直されたら、そこから読む。
/// 候補で選んだ taskboard の操作と、送信の失敗と、会話では使えないコマンドの案内は会話の画面に渡す
struct ConversationComposerArea: View {
    @Environment(AppModel.self) private var model
    @Environment(\.splitFocus) private var splitFocus
    let key: ConversationKey
    let conversation: Conversation
    let feed: ConversationFeed
    let size: Double
    let writable: Bool
    var focused: FocusState<Bool>.Binding
    let interrupting: Bool
    let interrupt: () -> Void
    let attach: () -> Void
    let addImages: @MainActor @Sendable ([Data]) -> Void
    /// taskboard の操作（`/btw 質問` の引数つき）
    let perform: (ConversationTaskboardAction, String) -> Void
    let failed: (UserFacingError?) -> Void
    let unsupported: (ConversationUnsupportedCommand?) -> Void
    /// 末尾からフォークした会話に送る（⌥⌘↩）。フォークできたら true。フォークできない engine では nil
    let forkSend: ((String, [ChatDraftImage], [ChatDraftFile]) async -> Bool)?
    private let drafts: ChatDraftTexts

    @State private var input: ComposerInput
    /// `@` の打ちかけに合うファイル（打った文字ごとに daemon から引く）
    @State private var mentionFiles: [WorkFile] = []
    /// ↑↓ で呼び戻している発言（打ち直すと終わる）
    @State private var history = ComposerHistory()
    /// 候補を入力欄に入れた依頼と入れた文。送った文に文が残っていれば、送った後にその依頼を閉じる

    /// 音声入力（1 回押すとハンズフリー、押し続けると離すまで聞く）
    @State private var dictation = VoiceDictation()
    @AppStorage(AppPreferences.voiceInputKey) private var voiceInput = true
    #if os(macOS)
    @State private var voiceKeys = VoiceKeyMonitor()
    #endif

    /// `initialDraft` が空でなければそれを（snapshot 用）、空なら `drafts` の書きかけを出す
    init(
        key: ConversationKey, conversation: Conversation, feed: ConversationFeed, drafts: ChatDraftTexts, initialDraft: String, size: Double, writable: Bool,
        focused: FocusState<Bool>.Binding, interrupting: Bool, interrupt: @escaping () -> Void, attach: @escaping () -> Void,
        addImages: @escaping @MainActor @Sendable ([Data]) -> Void, perform: @escaping (ConversationTaskboardAction, String) -> Void, failed: @escaping (UserFacingError?) -> Void,
        unsupported: @escaping (ConversationUnsupportedCommand?) -> Void, forkSend: ((String, [ChatDraftImage], [ChatDraftFile]) async -> Bool)? = nil
    ) {
        self.key = key
        self.conversation = conversation
        self.feed = feed
        self.size = size
        self.writable = writable
        self.focused = focused
        self.interrupting = interrupting
        self.interrupt = interrupt
        self.attach = attach
        self.addImages = addImages
        self.perform = perform
        self.failed = failed
        self.unsupported = unsupported
        self.forkSend = forkSend
        self.drafts = drafts
        _input = State(initialValue: initialDraft.isEmpty ? ComposerInput(key, in: drafts) : ComposerInput(draft: initialDraft, selection: nil))
    }

    private var images: [ChatDraftImage] { model.chatImages(for: key) }
    private var files: [ChatDraftFile] { model.chatFiles(for: key) }

    var body: some View {
        let suggestions = commandSuggestions
        let files = mentionSuggestions
        if !suggestions.isEmpty {
            SlashCommandSuggestions(
                commands: suggestions.map(suggestion), selection: input.commandSelection, fonts: ChatFonts(size: size),
                pick: { picked in suggestions.first { $0.name == picked.name }.map(pick) },
                hover: { input.commandSelection = $0 })
        } else if !files.isEmpty {
            SlashCommandSuggestions(
                commands: files.map { SlashSuggestion($0) }, selection: input.commandSelection, fonts: ChatFonts(size: size),
                pick: { picked in files.first { $0.path == picked.id }.map(pick) },
                hover: { input.commandSelection = $0 })
        } else {
            ConversationOpenAsks(feed: feed, machine: key.machine)
            ConversationManualWork(key: key)
        }
        dictationNotices
        composer
            .task(id: mentionTyping?.query) { await loadMentionFiles() }
            .onChange(of: feed.restoredDrafts, initial: true) { _, restored in restore(restored) }
            .composerDraftSync($input, to: key, in: drafts) { history.edited(to: $0) }
            #if DEBUG
            .modifier(DebugComposerFeed(draft: $input.draft, selection: $input.selection))
            .modifier(
                DebugDictationFeed(
                    dictation: dictation, press: { startDictation() }, release: { dictation.release() },
                    file: { url in dictation.transcribeFile(url, vocabulary: dictationVocabulary, handlers: dictationHandlers()) }))
            #endif
            #if os(macOS)
            .onAppear {
                voiceKeys.onPress = { startDictation() }
                voiceKeys.onRelease = { dictation.release() }
                voiceKeys.isActive = voiceInput && focused.wrappedValue
                voiceKeys.start()
            }
            .onChange(of: focused.wrappedValue) { _, now in voiceKeys.isActive = voiceInput && now }
            .onChange(of: voiceInput) { _, now in voiceKeys.isActive = now && focused.wrappedValue }
            #endif
            .onAppear { if voiceInput { dictation.prewarm() } }
            .onDisappear {
                #if os(macOS)
                voiceKeys.stop()
                #endif
                dictation.cancel()
            }
    }

    private var generating: Bool { conversation.phase == .running || feed.isGenerating }

    private var composer: some View {
        let canSend = (!input.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty) && writable
        let generating = generating
        let canAttach = images.count < ChatAttachment.maxCount
        // iPhone は送信の場所に停止を出し、添付と制御を＋のメニューにまとめる（文を打てる幅を取る）
        let phone = AppModel.isPhone
        return ChatComposer(
            draft: $input.draft, selection: $input.selection, focused: focused, canAttach: canAttach,
            canSend: canSend, addImages: addImages, send: { send() }, commandKey: { handleCommandKey($0, $1) },
            pasteLong: writable ? { takePastedText($0) } : nil,
            stop: phone && generating ? ChatComposerStop(enabled: writable && !interrupting, action: interrupt) : nil
        ) {
            #if os(iOS)
            if phone {
                ConversationPhoneMenu(conversation: conversation, feed: feed, writable: writable, canAttach: canAttach, attach: attach, addImages: addImages)
            } else if writable {
                ChatAttachButton(action: attach)
            }
            #else
            if writable { ChatAttachButton(action: attach) }
            #endif
        } accessory: {
            if voiceInput {
                ComposerVoiceButton(phase: dictation.phase, polishing: dictation.polishing, press: { startDictation() }, release: { dictation.release() })
            }
            if generating, !phone {
                Button {
                    interrupt()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(writable && !interrupting ? Color.primary : Color.secondary)
                .disabled(!writable || interrupting)
                .hitTarget()
                .accessibilityLabel("生成を停止")
                .help("生成を停止")
            }
        }
    }

    // MARK: 音声入力

    /// マイクを断られたときの理由と設定を開く操作、日本語のモデルの取得中。どちらも入力欄のすぐ上に、解決するまで出す
    @ViewBuilder
    private var dictationNotices: some View {
        if dictation.microphoneDenied {
            Banner(
                kind: .error, message: String(localized: "音声入力を開始できませんでした。マイクへのアクセスが許可されていません。"),
                onClose: { dictation.microphoneDenied = false }
            ) {
                Button(VoiceDictationSettings.openLabel) { VoiceDictationSettings.open() }
            }
        }
        if case .downloading(let fraction) = dictation.phase {
            Banner(
                kind: .pending, message: String(localized: "音声認識のモデルを取得しています…"),
                detail: fraction.map { String(localized: "\(Int(($0 * 100).rounded()))%") })
        }
        if dictation.phase == .loading {
            Banner(kind: .pending, message: String(localized: "音声認識のモデルを準備しています…"))
        }
    }

    /// 押した。止まっていれば、今のカーソル（選んでいればその範囲）に聞き取った文を入れる準備をして聞き始める（ハンズフリーで聞いていれば終える）
    private func startDictation() {
        dictation.press(vocabulary: dictationVocabulary, handlers: dictationHandlers())
    }

    /// 聞き取った文を、聞き始めたときのカーソルに入れる。校正した文は、入力欄が校正の前の文を入れたときのままなら置き換える（打ち直していれば捨てる）
    private func dictationHandlers() -> VoiceDictation.Handlers {
        let insertion = DictationDraft(draft: input.draft, selection: selectedRange)
        var task: BoardTask?
        if case .task(let taskKey) = model.conversationScope(for: key) { task = model.fleet.task(for: taskKey) }
        let title = task?.title
        let number = task?.number
        let messages = Array(feed.messages.suffix(80))
        var polish: (@Sendable (String) async throws -> String)?
        if let source = feed.source as? any DictationSource {
            polish = { text in
                try await source.polishDictation(DictationPolishRequest(text: text, taskTitle: title, taskNumber: number, messages: messages)).text
            }
        }
        return VoiceDictation.Handlers(
            transcribed: { spoken in
                input.replace(insertion.inserting(spoken))
                focused.wrappedValue = true
            },
            polished: { original, polished in
                guard input.draft == insertion.inserting(original).text else { return }
                input.replace(insertion.inserting(polished))
            },
            failed: { failed($0) }, polish: polish)
    }

    /// 欄で選んでいる範囲（カーソルだけなら空の範囲）。分からなければ nil（末尾に足す）
    private var selectedRange: Range<String.Index>? {
        guard let selection = input.selection, case .selection(let range) = selection.indices,
            let lower = SlashTyping.cursor(range.lowerBound, in: input.draft), let upper = SlashTyping.cursor(range.upperBound, in: input.draft)
        else { return nil }
        return lower..<upper
    }

    /// 会話のタスクの題と番号、最近の発言に出た番号のような語
    private var dictationVocabulary: [String] {
        var task: BoardTask?
        if case .task(let taskKey) = model.conversationScope(for: key) { task = model.fleet.task(for: taskKey) }
        return DictationVocabulary.phrases(taskTitle: task?.title, taskNumber: task?.number, messages: Array(feed.messages.suffix(80)))
    }

    /// 取り消された待機中の発言と巻き戻した指示を、今の下書きの前に戻す。画像とファイルも前に戻し、上限を超えた分は外す
    private func restore(_ restored: [RestoredDraft]) {
        guard !restored.isEmpty else { return }
        let texts = { (appends: Bool) in restored.filter { $0.appends == appends }.map(\.text).filter { !$0.isEmpty } }
        input.draft = (texts(false) + (input.draft.isEmpty ? [] : [input.draft]) + texts(true)).joined(separator: "\n")
        let images = restored.flatMap(\.images) + self.images
        let files = restored.flatMap(\.files) + self.files
        model.setChatImages(Array(images.prefix(ChatAttachment.maxCount)), for: key)
        model.setChatFiles(Array(files.prefix(ChatAttachment.maxFiles)), for: key)
        if images.count > ChatAttachment.maxCount {
            failed(ChatImageIntake.failure(.tooMany([])))
        } else if files.count > ChatAttachment.maxFiles {
            failed(ChatFileIntake.failure(.tooMany))
        }
        feed.restoredDrafts = []
        focused.wrappedValue = true
    }

    // MARK: / の候補

    private var commandSuggestions: [ConversationSlashItem] {
        guard let typing = input.slashTyping else { return [] }
        return ConversationSlashItem.matching(
            typing.name, commands: feed.commands, engine: conversation.engine, unavailableFields: model.unavailableFields(for: conversation), leading: typing.leading)
    }

    private func suggestion(_ item: ConversationSlashItem) -> SlashSuggestion {
        switch item.action {
        case .send:
            SlashSuggestion(name: item.name, description: item.description ?? "", badge: item.builtin ? String(localized: "組み込み") : nil, alias: item.matchedAlias)
        case .control(let field):
            SlashSuggestion(name: item.name, description: ConversationSlashText.description(field), badge: String(localized: "Taskboard"))
        case .taskboard(let action):
            SlashSuggestion(name: item.name, description: ConversationSlashText.description(action), badge: String(localized: "Taskboard"))
        }
    }

    /// CLI のコマンドは打ちかけの語を名前と空白に替え（続けて引数や文を書ける）、欄と taskboard の操作は送らずにその場で開く（文の頭でだけ出す）
    private func pick(_ item: ConversationSlashItem) {
        switch item.action {
        case .send(let name):
            complete(name)
        // 名前を入れるシートは持たず、続けて名前を書けるように入力欄に入れる
        case .taskboard(.rename):
            complete(item.name)
        case .control(let field):
            input.draft = ""
            feed.open(field)
        case .taskboard(let action):
            input.draft = ""
            perform(action, "")
        }
    }

    private func complete(_ name: String) {
        input.complete(name)
        focused.wrappedValue = true
    }

    private func handleCommandKey(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> Bool {
        if SplitFocusKeys.handle(key, modifiers: modifiers, move: splitFocus) { return true }
        let suggestions = commandSuggestions
        let files = suggestions.isEmpty ? mentionSuggestions : []
        let used = SlashCommandKeys.handle(
            key, modifiers: modifiers, count: suggestions.isEmpty ? files.count : suggestions.count, selection: $input.commandSelection,
            pick: { suggestions.isEmpty ? pick(files[$0]) : pick(suggestions[$0]) }, dismiss: { input.dismissSuggestions() })
        return used || recallHistory(key, modifiers) || sendKey(key, modifiers)
    }

    /// 生成中の Esc で生成を停止、⌘↩ で応答が終わってから送信（生成中でなければふつうに送る）、⌥⌘↩ で末尾からフォークした会話に送る。
    /// Esc は生成中でなければ外（パネルを閉じる）に渡す。⌘↩ は欄にいる間はメニューの［別ウインドウで開く］に渡さない
    private func sendKey(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> Bool {
        switch (key, modifiers) {
        case (.escape, []):
            guard generating, writable else { return false }
            if !interrupting { interrupt() }
            return true
        case (.return, [.command]):
            send(later: generating && conversation.engine.supports(ConversationOperation.sendLater))
            return true
        case (.return, [.option, .command]):
            forkAndSend()
            return true
        default:
            return false
        }
    }

    // MARK: ↑↓ の履歴

    /// 欄が空かカーソルが 1 行目の頭にあるときの ↑ で、前の人の発言を呼び戻す。呼び戻している間は、カーソルが最後の行にある ↓ で新しい方へ戻る。
    /// 使わない場面は false を返し、欄の ↑↓（カーソルの移動）に任せる
    private func recallHistory(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> Bool {
        guard modifiers.isDisjoint(with: [.shift, .option, .command, .control]) else { return false }
        let cursor = caret
        switch key {
        case .upArrow:
            guard input.draft.isEmpty || cursor == input.draft.startIndex else { return false }
            guard let text = history.previous(in: ComposerHistory.entries(from: feed.messages), current: input.draft) else { return false }
            show(text, caretAtStart: true)
        case .downArrow:
            guard history.isRecalling, cursor.map({ !input.draft[$0...].contains("\n") }) ?? true else { return false }
            guard let text = history.next(in: ComposerHistory.entries(from: feed.messages)) else { return false }
            show(text, caretAtStart: history.isRecalling)
        default:
            return false
        }
        return true
    }

    /// 欄のカーソルの位置。範囲を選んでいるときと、分からないときは nil
    private var caret: String.Index? {
        guard let selection = input.selection, case .selection(let range) = selection.indices, range.isEmpty else { return nil }
        return SlashTyping.cursor(range.lowerBound, in: input.draft)
    }

    /// 呼び戻した発言は、続けて ↑ を押せるようカーソルを頭に置く。辿り始める前の文に戻すときは終わりに置く
    private func show(_ text: String, caretAtStart: Bool) {
        input.replace((text, caretAtStart ? text.startIndex : text.endIndex))
    }

    // MARK: @ の候補

    private var mentionTyping: MentionTyping? {
        guard !input.isDismissed else { return nil }
        return MentionTyping.find(in: input.draft, selection: input.selection)
    }

    private var mentionSuggestions: [WorkFile] { mentionTyping == nil ? [] : mentionFiles }

    /// 打ち終わるのを少し待ってから引く（1 字ごとに daemon を呼ばない）。打ちかけが無くなったら候補を空にする
    private func loadMentionFiles() async {
        guard let query = mentionTyping?.query else {
            mentionFiles = []
            return
        }
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        let files = await feed.workFiles(matching: query) ?? []
        guard !Task.isCancelled else { return }
        mentionFiles = files
    }

    /// 選んだパスを `@パス` にして入れる（送る文はそのまま。CLI がパスの文字を読む）
    private func pick(_ file: WorkFile) {
        guard let typing = mentionTyping else { return }
        input.replace(typing.completing(file, in: input.draft))
        focused.wrappedValue = true
    }

    // MARK: 長い貼り付け

    /// 長い貼り付けは入力欄に入れず、`pasted-text.txt` の添付にする（入れると全文を組み版して入力が止まる）
    private func takePastedText(_ text: String) {
        let current = model.chatFiles(for: key)
        guard current.count < ChatAttachment.maxFiles else {
            failed(ChatFileIntake.failure(.tooMany))
            return
        }
        let file = ChatDraftFile.pasted(text)
        guard case .data(let data) = file.content, data.count <= ChatAttachment.maxFileBytes else {
            failed(ChatFileIntake.failure(.tooLarge(String(localized: "貼り付けた文"))))
            return
        }
        model.setChatFiles(current + [file], for: key)
        failed(nil)
    }

    // MARK: 送信

    /// 先に出してから送る。送れなかった発言は列に印と［再送信］を出す（下書きは空にする）。`later` は応答が終わってから送る
    private func send(later: Bool = false) {
        let text = input.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !images.isEmpty || !files.isEmpty), model.canWrite(key.machine) else { return }
        // taskboard の操作（`/btw 質問` など）と、Codex の欄（`/model` など）は CLI に送らずに開く（headless の CLI では動かない）。
        // 会話では動かない組み込みのコマンドは、送らずに帯で案内する
        if images.isEmpty, files.isEmpty {
            let commands = feed.commands
            if let typed = ConversationSlashItem.intercepted(
                text, engine: conversation.engine, commands: commands, unavailableFields: model.unavailableFields(for: conversation))
            {
                input.draft = ""
                failed(nil)
                unsupported(nil)
                switch typed.action {
                case .taskboard(let action): perform(action, typed.argument)
                case .control(let field): feed.open(field)
                case .send: break
                }
                return
            }
            if let command = ConversationSlashItem.unsupported(
                text, engine: conversation.engine, commands: commands, unavailableFields: model.unavailableFields(for: conversation))
            {
                input.draft = ""
                failed(nil)
                unsupported(command)
                return
            }
        }
        if conversation.pending.contains(where: { $0.kind == .question }) {
            failed(.awaitingAnswer)
            return
        }
        feed.send(text, images: images, files: files, later: later)
        clear()
    }

    private func clear() {
        input.draft = ""
        // フォークした会話へ移ると、この欄は onChange を待たずに消える
        drafts.set("", selection: nil, for: key)
        model.setChatImages([], for: key)
        model.setChatFiles([], for: key)
        failed(nil)
        unsupported(nil)
    }

    /// 入力欄の文と添付を、末尾からフォークした会話に送る。`/` のコマンドは送らない（フォーク先で打ち直す）。フォークできたら欄を空にする
    private func forkAndSend() {
        let text = input.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let forkSend, (!text.isEmpty || !images.isEmpty || !files.isEmpty), model.canWrite(key.machine), !text.hasPrefix("/") else { return }
        let sent = input.draft, images = images, files = files
        Task {
            guard await forkSend(text, images, files), input.draft == sent else { return }
            clear()
        }
    }
}
