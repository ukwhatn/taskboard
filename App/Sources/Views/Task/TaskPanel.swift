import SwiftUI
import TaskboardKit

/// タスクを開いたときのパネル（サイドビュー・全面・中央モーダル・別ウィンドウで共通）。
/// 上の帯に番号と開き方、題と待ち理由の下に、中央に札（lead と委譲先の会話）と選んだ会話、右に欄（`TaskSideArea`）。
/// 会話のシェルは会話と右の欄の下に全幅で開く（`TaskTerminalArea`）。並べて入らない幅では右の欄を下に重ねる（`TaskPanelMetrics`）。文書を開くと、帯の下を文書の画面にする。
/// 別のタスクを開いても作り直さず、中の部品を使い回す。そのタスクの間だけ持つ値は `TaskState` で持つ
struct TaskPanel: View {
    let key: TaskKey
    /// 別ウィンドウで開いているか。開き方の切り替えと「別ウィンドウで開く」は出さない
    var inWindow = false

    var body: some View {
        TaskPanelBody(key: key, inWindow: inWindow).environment(\.taskScope, key)
    }
}

private struct TaskPanelBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: TaskKey
    let inWindow: Bool

    /// 札で選んだ会話（終了した会話を履歴から開いたものも）
    @TaskState private var currentConversation: ConversationKey?
    /// 右に 2 つ目として並べている会話（札を ⌘ を押しながら押すか、札のメニューの［右に並べる］か［並べる］）
    @TaskState private var second: ConversationKey?
    @State private var size: CGSize = .zero
    /// 別ウィンドウの起動シート（本体のパネルは DebugServer からも開けるよう `model.launchSheet` を使う）
    @State private var windowLaunch: LaunchDraft?
    /// 開いている文書に送っていない入力があるか（`DocumentPendingInputKey`）
    @State private var docPendingInput = false
    /// 出している編集のシート（札の帯の［セッションを紐づける…］から開く）
    @TaskState private var editing: TaskEditSheet?
    /// 右の欄を隠しているか（帯のボタン。この端末で覚える）
    @AppStorage(AppPreferences.taskPanelSidePaneHiddenKey) private var sidePaneHidden = false
    /// 右側の幅（境目を動かして残した幅。0 なら既定）
    @AppStorage(AppPreferences.taskSideWidthKey) private var sideWidth: Double = 0
    @State private var sideWidthDragStart: CGFloat?
    /// チャットでファイルを開いているか（`ChatFileOpenKey`）。並べて入らなければ、開いている間だけ右の欄を畳んで欄の場所を空ける
    @State private var chatFileOpen = false
    /// 右の欄を会話と入れ替える幅（`TaskPanelMetrics.swapsWhenStacked`）で、欄を出しているか
    @TaskState private var swapShowsDetails = false
    /// 画面のキーボードを出しているか（入れ替える幅では、出している間は見出しを畳んで会話の高さを空ける）
    @State private var keyboardShown = false

    var body: some View {
        let conversations = model.fleet.task(for: key).map { model.taskSessions(for: $0).conversations.map(\.key) } ?? []
        Group {
            if let task = model.fleet.task(for: key) {
                content(task)
            } else {
                EmptyState(title: "このタスクはありません", symbol: "questionmark.square.dashed", message: "削除されたか、接続していないMacのタスクです。") {
                    Button("閉じる") { close() }
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .onChange(of: model.sessionCycleRequest) { _, request in
            // ⌃Tab / ⌃⇧Tab は本体のパネルだけが受ける（別ウィンドウは同じタスクでも動かさない）
            guard !inWindow, let task = model.fleet.task(for: key) else { return }
            let sessions = model.taskSessions(for: task)
            let keys = sessions.conversations.map(\.key)
            guard !keys.isEmpty else { return }
            let current = keys.firstIndex { $0 == shownConversation(sessions)?.key } ?? 0
            let next = keys[(current + request.delta + keys.count) % keys.count]
            model.logConversationSelect(next, via: "key")
            currentConversation = next
        }
        // ⌘L と起動・並べた欄の移動で入力欄へ移るときは、欄と入れ替えていれば会話に戻す（隠れた入力欄にキーボードだけが出ないように）
        .onChange(of: model.sessionFocusRequests) { _, _ in swapShowsDetails = false }
        .onChange(of: model.sessionFocus, initial: true) { _, _ in takeFocus(conversations: conversations) }
        .onChange(of: conversations) { _, new in takeFocus(conversations: new) }
        .onPreferenceChange(DocumentPendingInputKey.self) { docPendingInput = $0 }
        #if os(iOS)
        // 外付けのキーボードでも候補の帯の分だけ通知が来るので、画面の下から一定より高く出たときだけ出しているとみなす
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            let screen = (note.object as? UIScreen)?.bounds ?? frame
            keyboardShown = frame.minY < screen.maxY && frame.height > KeyboardMetrics.softKeyboardMinHeight
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
        #endif
        #if os(macOS)
        // 端末にフォーカスがあると Esc は端末が受け取るので、ここには来ない。
        // 文書を開いていれば、文書の画面が先に受けて文書だけを閉じる。ここに来るのはフォーカスが上の帯にあるときで、同じく文書だけを閉じる
        .onExitCommand {
            if model.openDoc(in: key) == nil {
                close()
            } else if !docPendingInput {
                model.closeDoc()
            }
        }
        #endif
    }

    @ViewBuilder
    private func content(_ task: BoardTask) -> some View {
        let shownDoc = model.openDoc(in: key).flatMap { model.fleet.document(for: $0) }
        let canEdit = model.canWrite(task.machine)
        let sessions = model.taskSessions(for: task)
        VStack(spacing: 0) {
            TaskPanelBar(task: task, inWindow: inWindow, sidePaneHidden: $sidePaneHidden, close: close)
            if let shownDoc {
                Divider()
                DocumentScreen(key: shownDoc.id).id(shownDoc.id)
            } else {
                let sideBySide = TaskPanelMetrics.sideBySide(width: size.width)
                let swaps = !sideBySide && TaskPanelMetrics.swapsWhenStacked
                if !(swaps && keyboardShown) {
                    TaskHeader(task: task, signals: model.cardSignals(for: task), showsNote: false, editable: canEdit) {
                        sessionBar(task, sessions)
                    }
                    Divider()
                }
                // 幅が分かる前（size が 0）は上下に重ね、分かってから左右に並べる。if で分けると配置が替わるたびに端末の view が作り直され、
                // 接続と操作権の取得が 2 回走る（前の view の onDisappear より新しい view の onAppear が先に来る）ので、同じ子を `SessionSplit` の向きだけ替える
                // ファイルの欄が右の欄と並べて入らず、右の欄を畳めば入る幅なら、ファイルを開いている間だけ畳む（2 つ並べているときはチャットが半分なので畳まない）
                let fileRoom = TaskPanelMetrics.makesRoomForFile(width: size.width) && visibleSecond(sessions) == nil
                let showsSidePane = !sidePaneHidden && !(fileRoom && chatFileOpen)
                let detailsWidth = TaskPanelMetrics.detailsWidth(in: size.width, preferred: sideWidth > 0 ? CGFloat(sideWidth) : nil)
                SessionSplit(
                    sideBySide: sideBySide, sideWidth: detailsWidth,
                    stackedMaxHeight: size.height > 0 ? size.height * TaskPanelMetrics.stackedDetailsShare : nil,
                    swap: swaps && showsSidePane ? (swapShowsDetails ? .details : .conversation) : nil
                ) {
                    DeferredMount {
                        sessionArea(task, sessions, sidePaneShown: showsSidePane)
                            .environment(\.chatFileRoom, fileRoom)
                    }
                    .accessibilityHidden(swaps && showsSidePane && swapShowsDetails)
                    if showsSidePane {
                        SplitDivider(vertical: sideBySide)
                            .overlay {
                                if sideBySide { sideWidthHandle(detailsWidth) }
                            }
                        DeferredMount(lane: .later) {
                            TaskSideArea(
                                task: task, editable: canEdit, conversation: shownConversation(sessions)?.key,
                                single: !sideBySide, swap: swaps ? $swapShowsDetails : nil,
                                openConversation: {
                                    currentConversation = $0
                                    swapShowsDetails = false
                                }
                            )
                        }
                    }
                }
                .onPreferenceChange(ChatFileOpenKey.self) { chatFileOpen = $0 }
                // 出している会話のシェルは、会話と右の欄の下に全幅で出す（右に並べた 2 つ目の会話のシェルは、その欄の下）
                if let owner = shownConversation(sessions)?.key, let dock = model.terminalDock(for: owner) {
                    TaskTerminalArea(owner: owner, state: dock, panelHeight: size.height)
                }
            }
        }
        // 最小の高さを外へ伝えない。見出しの題とチップは折り返すので、幅 0 で測られると 1 字ずつ折り返して高くなり、
        // 主ウィンドウの NavigationSplitView がそれを自分の最小にして、窓を画面より高く伸ばすか中身を窓の上下にはみ出させた
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(.background)
        .taskSessionSheets(task: task, launch: launchSheet, editing: $editing)
    }

    private func close() {
        if inWindow { dismiss() } else { model.closeTask() }
    }

    /// 中央と右側の境目。ドラッグで右側の幅を変え、ダブルクリックで既定の幅に戻す
    private func sideWidthHandle(_ current: CGFloat) -> some View {
        SplitHandle(axis: .horizontal, label: String(localized: "サイドパネルの幅")) { delta in
            let start = sideWidthDragStart ?? current
            sideWidthDragStart = start
            sideWidth = Double(TaskPanelMetrics.detailsWidth(in: size.width, preferred: start - delta))
        } end: {
            sideWidthDragStart = nil
        }
        .frame(width: SidePanelMetrics.handle)
        .onTapGesture(count: 2) { sideWidth = 0 }
    }

    // MARK: 会話

    /// 右に並べているもの（左と同じなら無し）
    private func visibleSecond(_ sessions: TaskSessionSet) -> Conversation? {
        guard !AppModel.isPhone else { return nil }
        return TaskSplit.visible(second, primary: shownConversation(sessions)?.key, rows: sessions.rows)
    }

    /// 右に並べて、入力をそちらへ移す。出たばかりの欄は出たときに自分でフォーカスを取る
    private func placeBeside(_ item: ConversationKey, _ sessions: TaskSessionSet) {
        guard !AppModel.isPhone, item != shownConversation(sessions)?.key else { return }
        second = item
        model.requestSessionFocus(on: item)
    }

    /// ⌃] ⌃[。並べた欄の入力欄か端末にフォーカスを移す
    private func moveFocus(_ side: SplitSide, _ sessions: TaskSessionSet) {
        let target = side == .leading ? shownConversation(sessions)?.key : visibleSecond(sessions)?.key
        if let target { model.requestSessionFocus(on: target) }
    }

    /// 札を ⌘ を押しながら押したか（Mac）
    private static var wantsBeside: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    /// サイドバー・通知から開いた会話と、起動・再開した会話を札で選ぶ（`AppModel.sessionFocus`）。
    /// 開く先は state に届く前に決まるので、このタスクの札（終了した会話は履歴）に届いてから選ぶ
    private func takeFocus(conversations: [ConversationKey]) {
        guard let focus = model.sessionFocus, focus.scope == .task(key) else { return }
        if focus.beside {
            let rows = model.fleet.task(for: key).map { model.taskSessions(for: $0).rows } ?? []
            guard rows.contains(where: { $0.conversation.key == focus.item }) else { return }
            second = focus.item
            model.sessionFocus = nil
            return
        }
        let closed = model.fleet.task(for: key).map { model.taskSessions(for: $0).closed.map(\.key) } ?? []
        guard conversations.contains(focus.item) || closed.contains(focus.item) else { return }
        currentConversation = focus.item
        model.sessionFocus = nil
    }

    @ViewBuilder
    /// `sidePaneShown` は右の欄を今出しているか（隠したときと、ファイルの欄のために畳んでいる間は false。会話の［状態］［差分］の出し先が変わる）
    private func sessionArea(_ task: BoardTask, _ sessions: TaskSessionSet, sidePaneShown: Bool) -> some View {
        let canLaunch = model.canWrite(key.machine)
        let stopped = sessions.stopped
        let shownConversation = shownConversation(sessions)
        VStack(spacing: 0) {
            if sessions.rows.isEmpty, shownConversation == nil, let latest = stopped.first {
                let title = model.sessionHistory(latest, on: task.machine)?.title(taskTitle: task.title)
                EmptyState(
                    title: "セッションは終了しています", symbol: "stop.circle",
                    message: canLaunch ? title.map { "「\($0)」を再開するか、新しく起動してください。" } ?? "前の会話を再開するか、新しく起動してください。" : model.writeBlock(key.machine, "再開できません")?.text
                ) {
                    if canLaunch {
                        Button("再開", systemImage: "play.fill") { model.resumeSession(latest, task: task.id) }
                            .buttonStyle(.borderedProminent)
                        Button("起動") { startLaunch(task) }
                        Button("セッションを紐づける…") { editing = .sessions }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.rows.isEmpty, shownConversation == nil {
                EmptyState(title: "セッションはありません", symbol: "terminal", message: model.writeBlock(key.machine, "起動できません")?.text) {
                    if canLaunch {
                        Button("起動", systemImage: "play.fill") { startLaunch(task) }
                            .buttonStyle(.borderedProminent)
                        Button("セッションを紐づける…") { editing = .sessions }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = shownConversation
                let beside = visibleSecond(sessions)
                // 左は並べても並べなくても同じ所に置く（置き場が替わると会話の購読と端末の接続が作り直される。`ConversationView` の onAppear が古い方の onDisappear より先に来る）
                if let shown {
                    let move = beside == nil ? nil : { (side: SplitSide) in moveFocus(side, sessions) }
                    EvenSplit {
                        SessionColumn(conversation: shown, showsHeader: beside != nil, docksBelow: false, detailsBeside: sidePaneShown, close: nil)
                            .environment(\.splitFocus, move)
                        if let beside {
                            SplitDivider(vertical: true)
                            SessionColumn(conversation: beside, showsHeader: true, docksBelow: true, detailsBeside: false) { second = nil }
                                .environment(\.splitFocus, move)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 札で選んでいる会話（終了した会話を履歴から開いたものも。記録が無くなったら選んでいないのと同じ）。
    /// 選んでいなければ、開いたときに出す会話（`MachineState.openingConversation`）
    private func shownConversation(_ sessions: TaskSessionSet) -> Conversation? {
        currentConversation.flatMap { k in (sessions.conversations + sessions.closed).first { $0.key == k } } ?? sessions.opening
    }

    /// 会話の札の行（札・並べる・紐づける・起動）。見出しのチップの段の右に置く。会話が無いときは出さない（中央の空の画面に起動と再開がある）
    @ViewBuilder
    private func sessionBar(_ task: BoardTask, _ sessions: TaskSessionSet) -> some View {
        if !sessions.rows.isEmpty || shownConversation(sessions) != nil {
            let canLaunch = model.canWrite(key.machine)
            let shown = shownConversation(sessions)
            let beside = visibleSecond(sessions)
            let partner = TaskSplit.partner(of: shown?.key, rows: sessions.rows)
            HStack(spacing: Space.row) {
                LinkedSessionPills(
                    rows: sessions.rows, current: shown?.key, second: beside?.key,
                    select: { item in
                        if Self.wantsBeside {
                            model.logConversationSelect(item, via: "beside")
                            placeBeside(item, sessions)
                        } else {
                            model.logConversationSelect(item, via: "pill")
                            currentConversation = item
                        }
                    },
                    selectSecond: AppModel.isPhone
                        ? nil
                        : { item in
                            model.logConversationSelect(item, via: "beside")
                            placeBeside(item, sessions)
                        })
                if !AppModel.isPhone, beside != nil || partner != nil {
                    Button(beside == nil ? "並べる" : "1つに戻す", systemImage: beside == nil ? "rectangle.split.2x1" : "rectangle") {
                        if beside == nil, let partner { placeBeside(partner, sessions) } else { second = nil }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help(beside == nil ? "2つのセッションを並べる" : "1つに戻す")
                }
                if canLaunch {
                    Button("セッションを紐づける…", systemImage: "link") { editing = .sessions }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .hitTarget()
                        .help("セッションを紐づける")
                }
                Button("セッションを起動", systemImage: "play.fill") { startLaunch(task) }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .fixedSize()
                    .disabled(!canLaunch)
            }
            .environment(\.pageInset, 0)
        }
    }

    private var launchSheet: Binding<LaunchDraft?> {
        if inWindow { return $windowLaunch }
        return Binding(get: { model.launchSheet }, set: { model.launchSheet = $0 })
    }

    private func startLaunch(_ task: BoardTask) {
        launchSheet.wrappedValue = model.launchDraft(for: task)
    }
}

/// 会話の画面と、その下の端末の欄。オーケストレーター・タスクなしの画面で使う
struct ConversationStage: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation

    var body: some View {
        DockingStage(owner: conversation.key) {
            ConversationView(key: conversation.key, feed: model.conversationFeed(for: conversation.key)).id(conversation.key)
        }
    }
}

/// 会話と、その下の端末の欄（`AppModel.terminalDock`）。タスクのパネルの左の会話は、端末を会話と右の欄の下（`TaskTerminalArea`）に出し、ここには出さない
struct DockingStage<Content: View>: View {
    @Environment(AppModel.self) private var model
    let owner: ConversationKey
    var docksBelow = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            if docksBelow, let dock = model.terminalDock(for: owner) {
                Divider()
                TerminalDock(state: dock) { model.openTerminal(for: owner) } close: { model.closeTerminal(of: owner) }
                    .frame(height: TerminalDockMetrics.height)
            }
        }
    }
}

/// 端末の欄。題（作業フォルダのシェル）と閉じるボタン、端末。閉じると会話のシェルは止まる（`AppModel.closeTerminal`）
struct TerminalDock: View {
    let state: TerminalDockState
    let retry: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.row) {
                Image(systemName: "terminal").foregroundStyle(.secondary).accessibilityHidden(true)
                Text("作業フォルダのシェル").textRole(.caption).foregroundStyle(.primary)
                Spacer(minLength: Space.row)
                Button("閉じる", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("ターミナルパネルを閉じる")
            }
            .padding(.horizontal, Space.block)
            Divider()
            TerminalDockBody(state: state, retry: retry)
        }
    }
}

/// 端末の欄の中身。起こしている間は進み具合、起こせなければわけと［やり直す］
struct TerminalDockBody: View {
    @Environment(AppModel.self) private var model
    let state: TerminalDockState
    let retry: () -> Void

    var body: some View {
        switch state {
        case .starting:
            ProgressView("シェルを起動しています…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            Banner(kind: .error, message: failure.text) {
                Button("やり直す", action: retry)
            }
            .padding(Space.block)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .shown(let pane):
            if let source = model.fleet.terminalSource(for: pane.machine) {
                TerminalPane(key: pane, source: source) { model.dropEndedTerminal(pane) }
                    .id(pane)
            } else {
                EmptyState("ターミナルを表示できません", symbol: "terminal", message: "この接続先は表示用のデータです。")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 端末の欄の高さ。既定は端末で 20 行ほど
enum TerminalDockMetrics {
    static let height: CGFloat = 320
    /// タスクの画面で境目を動かして縮められる下限（頭と端末の 5 行ほど）
    static let minHeight: CGFloat = 120
    /// タスクの画面で端末に取れる高さの上限の割合（残りは会話と右の欄）
    static let maxShare: CGFloat = 0.7

    /// タスクの画面の端末の高さ。`preferred` は境目を動かして残した高さ（無ければ既定）
    static func height(in panelHeight: CGFloat, preferred: CGFloat?) -> CGFloat {
        let upper = max(panelHeight * maxShare, minHeight)
        return min(max(preferred ?? height, minHeight), upper)
    }
}

/// タスクの画面の下の端末の欄。会話と右の欄の下に全幅で置き、上の境目のドラッグで高さを変え（この端末に残す）、ダブルクリックで既定に戻す
struct TaskTerminalArea: View {
    @Environment(AppModel.self) private var model
    let owner: ConversationKey
    let state: TerminalDockState
    /// タスクのパネルの高さ（端末に取れる高さの上限を決める）
    let panelHeight: CGFloat

    @AppStorage(AppPreferences.taskTerminalHeightKey) private var storedHeight: Double = 0
    @State private var dragStart: CGFloat?

    var body: some View {
        let height = TerminalDockMetrics.height(in: panelHeight, preferred: storedHeight > 0 ? CGFloat(storedHeight) : nil)
        VStack(spacing: 0) {
            Divider()
                .overlay {
                    SplitHandle(axis: .vertical, label: String(localized: "ターミナルの高さ")) { delta in
                        let start = dragStart ?? height
                        dragStart = start
                        storedHeight = Double(TerminalDockMetrics.height(in: panelHeight, preferred: start - delta))
                    } end: {
                        dragStart = nil
                    }
                    .frame(height: SidePanelMetrics.handle)
                    .onTapGesture(count: 2) { storedHeight = 0 }
                }
            TerminalDock(state: state) { model.openTerminal(for: owner) } close: { model.closeTerminal(of: owner) }
                .frame(height: height)
        }
    }
}

/// パネルの上の帯。左に番号・マシン・案件、右端に右の欄の表示・開き方・別ウィンドウ・削除・閉じる（題の長さで押し出されない）。
/// 編集はここに置かない（題・メモ・リンクはその場、紐づけはセッションの帯）
struct TaskPanelBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.pageInset) private var inset
    let task: BoardTask
    let inWindow: Bool
    @Binding var sidePaneHidden: Bool
    let close: () -> Void
    @State private var deleting: BoardTask?

    var body: some View {
        let board = model.fleet.board(id: task.boardID, on: task.machine)
        HStack(spacing: Space.row) {
            MetaLine(items: ["#\(task.number)", model.machineName(task.machine)] + (board.map { [$0.name] } ?? []))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(sidePaneHidden ? "サイドパネルを表示" : "サイドパネルを非表示", systemImage: "sidebar.trailing") { sidePaneHidden.toggle() }
                .symbolVariant(sidePaneHidden ? .none : .fill)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .help(sidePaneHidden ? "サイドパネルを表示" : "サイドパネルを非表示")
            if !inWindow {
                // segmented の Picker にしない（Mac の NSSegmentedControl は作るのが重く、パネルを開く手間の 4 割だった）
                ForEach(Array(TaskPresentation.allCases.enumerated()), id: \.element) { index, mode in
                    let selected = model.taskPresentation == mode
                    Button(mode.label, systemImage: mode.symbol) { model.taskPresentation = mode }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .symbolVariant(selected ? .fill : .none)
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .hitTarget()
                        .help("\(mode.label)（⌥⌘\(index + 1)）")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
                if supportsMultipleWindows {
                    Button("別ウインドウで開く", systemImage: "macwindow.on.rectangle") {
                        openWindow(value: task.id)
                        model.closeTask()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("別ウインドウで開く")
                }
            }
            TaskDeleteButton(task: task, target: $deleting)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .help("削除")
            Button("閉じる", systemImage: "xmark") { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .hitTarget()
                .help(inWindow ? "閉じる" : "閉じる（Esc）")
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.inline)
        .taskDeleteDialog($deleting)
    }
}

/// 札で選んだ会話の欄と、その下の端末の欄。2 つ並べている間は上に名前（右側は閉じるボタン付き）
struct SessionColumn: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    var showsHeader = true
    /// 端末の欄をこの欄の下に出す（左の欄は、右の欄が隣にある間はそちらに出す）
    var docksBelow = true
    /// 会話の［状態］［差分］を右の欄で開く（左の欄だけ。右に並べた会話はポップオーバーとシート）
    var detailsBeside = false
    let close: (() -> Void)?

    var body: some View {
        DockingStage(owner: conversation.key, docksBelow: docksBelow) {
            VStack(spacing: 0) {
                if showsHeader {
                    header
                    Divider()
                }
                ConversationView(key: conversation.key, feed: model.conversationFeed(for: conversation.key), detailsBeside: detailsBeside).id(conversation.key)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: Space.inline) {
            StatusGlyph(conversation: conversation)
            Text(conversation.displayTitle).textRole(.caption).foregroundStyle(.primary)
            Spacer(minLength: 0)
            if let close {
                Button("閉じる", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("1つに戻す")
            }
        }
        // 閉じるボタンの無い左の帯も右と同じ高さにし、下の会話の上の帯を左右で揃える
        .frame(minHeight: HitTarget.size)
        .padding(.horizontal, Space.block)
    }
}
