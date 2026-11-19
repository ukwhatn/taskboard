import Foundation
import Observation
import SwiftUI
import TaskboardKit

enum PhoneTab: String, Hashable {
    case tasks, settings
}

/// iPhone の「タスク」タブのスタックに積む画面。型の違う値を 1 つの path に積めないので、ボード・タスク・セッションを 1 つの型にまとめる
enum PhoneRoute: Hashable {
    case item(SidebarItem)
    case task(TaskKey)
    case conversation(ConversationKey)
}

/// サイドバーの選択先。全体のボード、マシンごとの案件・オーケストレーター・タスクなし、設定（iPad と iPhone）
enum SidebarItem: Hashable, Identifiable {
    /// 全マシンのボードを縦に並べた画面（Mac / iPad の既定）
    case overview
    case board(machine: MachineID, id: String)
    /// 設定（接続先・案件・列・起動・端末・チャット・通知・表示・ショートカット）。区分は `AppModel.settingsSection`
    case settings
    /// 1 マシンのオーケストレーターの画面（`OrchestratorScreen`）
    case orchestrator(machine: MachineID)
    /// 1 マシンの、どのタスクにも結ばれていないセッション・会話・定期起動・PR（`UnassignedScreen`）
    case unassigned(machine: MachineID)

    var id: String {
        switch self {
        case .overview: "overview"
        case .board(let machine, let id): "board/\(machine.rawValue)/\(id)"
        case .settings: "settings"
        case .orchestrator(let machine): "orchestrator/\(machine.rawValue)"
        case .unassigned(let machine): "unassigned/\(machine.rawValue)"
        }
    }
}

/// 画面全体が観測する状態。接続先の管理と、画面の選択を持つ。
@MainActor
@Observable
final class AppModel {
    let fleet = Fleet()
    var sidebar: SidebarItem = .overview
    /// 全体のボードでスクロールして見せるボード（`machine/boardID`）。サイドバーで選んだときだけ動かす
    var overviewScrollTarget: String?
    /// 全体のボードで開いた畳みの帯。案件（`<machine>/<board>`）ごとに、帯の先頭の列 id。
    /// 帯に Binding で渡すと、Binding は前と同じか比べられないので、帯がイベントのたびに作り直される
    var overviewExpandedColumns: [String: Set<String>] = [:]
    #if DEBUG
    /// 計測用: 全体のボードの縦の位置（DebugServer の /board/scroll が 1 フレームずつ動かす）
    var debugBoardScrollY: CGFloat?
    /// 計測用: 全体のボードの面と中身の大きさと位置（中身が面より広ければ横に送れる。DebugServer の /board/cards が返す）
    var debugBoardScrollSizes: (container: CGSize, content: CGSize, offset: CGPoint)?
    /// 計測用: 会話の入力欄の文とカーソル（DebugServer の /conversation/type が 1 字ずつ変える）
    var debugComposerInput: DebugComposerInput?
    /// 確認用: 会話の入力欄の［音声入力］の押し下げと離し（DebugServer の /conversation/dictation）と、入力欄が書き戻す今の段階
    var debugDictationPress: DebugDictationPress?
    var debugDictationPhase = "idle"
    #endif
    private let prefs = DevicePrefs()
    /// タスクの開き方。開いた後に切り替えると、次からもその開き方になる
    var taskPresentation: TaskPresentation = DevicePrefs().taskPresentation {
        didSet { prefs.taskPresentation = taskPresentation }
    }
    /// 開いているタスクがボードを隠しているか（中央・全面で開いている）
    var taskCoversBoard: Bool { selectedTask != nil && taskPresentation != .side }
    /// サイドバーと全体のボードで畳んでいるマシン（fleet の id）
    var collapsedMachines: Set<String> = DevicePrefs().collapsedMachines {
        didSet { prefs.collapsedMachines = collapsedMachines }
    }
    /// サイドバーの案件と列の節のうち、初めの開き方から切り替えたもの（`AppModel.isSidebarNodeExpanded`）
    var toggledSidebarNodes: Set<String> = DevicePrefs().toggledSidebarNodes {
        didSet { prefs.toggledSidebarNodes = toggledSidebarNodes }
    }
    /// サイドバーの分け方とタスクの並び順（右上のメニュー「並べ方」）
    var sidebarArrangement: SidebarArrangement = DevicePrefs().sidebarArrangement {
        didSet { prefs.sidebarArrangement = sidebarArrangement }
    }
    /// ピン留めしたタスク（この端末だけ）。マシンの段の頭の「ピン留め」の組に、動いていなくても出す
    var pinnedTasks: Set<TaskKey> = DevicePrefs().pinnedTasks {
        didSet { prefs.pinnedTasks = pinnedTasks }
    }
    /// ［次の入力待ちへ移動］で最後に開いた受信箱の項目（`AppModel.openNextAttention`）
    @ObservationIgnored var lastAttentionItem: String?
    /// 1 台だけ表示（⌃⌘1）。他のマシンを画面・通知・Dock のバッジから消す。接続は切らない
    var onlyMachineEnabled: Bool = DevicePrefs().onlyMachineEnabled {
        didSet {
            prefs.onlyMachineEnabled = onlyMachineEnabled
            applyOnlyMachine()
        }
    }
    /// 選んだ残すマシン。nil なら `onlyMachineID` が「この Mac」かサイドバーの先頭を使う
    var chosenOnlyMachineID: String? = DevicePrefs().onlyMachineID {
        didSet {
            prefs.onlyMachineID = chosenOnlyMachineID
            applyOnlyMachine()
        }
    }
    var machineOrder: [String] = DevicePrefs().machineOrder {
        didSet { prefs.machineOrder = machineOrder }
    }
    private var boardOrders: [String: [String]] = [:]
    /// iPhone のタブと、「タスク」タブのスタック（ボード・接続先）
    var phoneTab: PhoneTab = .tasks
    var phoneTaskPath: [SidebarItem] = []
    /// iPhone の「タスク」タブで、タスク・オーケストレーター・タスクなしの画面から開いた会話。開いているタスクが替わると閉じる
    var phoneTaskItem: ConversationKey?
    /// 画面を開いたときに札で選ぶ会話（サイドバー・通知から開いたもの、起動・再開した会話）。
    /// 画面が受けたら nil に戻す。iPhone は代わりに `phoneTaskItem` に積む（`AppModel.focus(_:in:)`）
    var sessionFocus: SessionFocus?
    /// PR の欄で出している PR（URL。タスク画面とタスクなしの画面）
    var selectedPR: String?
    /// タスクの見出しの PR のチップを押した・通知で PR を開いた知らせ（値は回数）。右の欄が PR に切り替わる
    var prFocusRequest = 0
    /// 右の欄を開く知らせ（`AppModel.showSidePane`）
    var sidePaneRequest: SidePaneRequest?
    /// 会話ごとの、画面の端末の欄（`AppModel.openTerminal`）
    var terminalDocks: [ConversationKey: TerminalDockState] = [:]
    /// 止まったセッションの会話の題（daemon が transcript から読む）。キーは「マシン/セッションID」
    var sessionHistories: [String: SessionHistory] = [:]
    var selectedTask: TaskKey? {
        didSet {
            if selectedTask != oldValue { phoneTaskItem = nil }
        }
    }
    /// 最近開いた会話の手元（新しく開いた順に 16 会話まで）
    @ObservationIgnored var conversationFeeds = RecentlyUsed<ConversationKey, ConversationFeed>(limit: 16)
    /// 開いている会話（DebugServer が中身を見る）
    weak var activeConversation: ConversationFeed?
    /// 全体のボードでキーで選んでいるカード（↑↓←→ / hjkl）。開いているタスク（`selectedTask`）とは別に持ち、↩ で開く
    var cursorTask: TaskKey?
    /// ホームの形（会話・列。⌘B）。この端末に残す
    var homeLayout: HomeLayout = DevicePrefs().homeLayout {
        didSet { prefs.homeLayout = homeLayout }
    }
    /// ホームの会話の形でキーで選んでいる会話（↑↓←→ / hjkl）。開いた後も残し、戻ったときに同じ会話を選んでおく
    var cursorTile: ConversationKey?
    /// Space で広げた会話と、取得した最後の発言
    var expandedTile: TileExpansion?
    /// ホームの会話から答えを送っている途中の会話と、送れなかった会話
    var tileSending: Set<ConversationKey> = []
    var tileFailures: [ConversationKey: UserFacingError] = [:]
    /// 待機の一覧を開いている
    var idleTilesExpanded = false
    /// 実行中の 1 行のうち「ほか n 件」を開いた組（`ConversationBoardLayout.BoardLines.groupID`。案件で分けていないときは `""`）
    var expandedRunningGroups: Set<String> = []
    /// ホームの会話の面の大きさ（view が測って書く）。キーで札を送るときの段の数え方に使う
    @ObservationIgnored var tileViewport: CGSize = .zero
    /// ⌘K のパレットと ⌘/ のショートカット一覧
    var paletteOpen = false
    /// パレットを開いている間の ⌘↩。メニューの［別ウィンドウで開く］が先に受けるので、増やしてパレットに選んだ行を開かせる
    var paletteOpenSeparatelyRequests = 0
    /// パレットで選んだ会話の検索の語。その会話の画面が受け取って検索の欄を開き、nil に戻す
    var chatSearchRequest: ChatSearchRequest?
    var shortcutsOpen = false
    /// ⌘L・⌃Tab の知らせ。開いているタスクのパネルとチャットが onChange で受ける（値は回数。中身は使わない）
    var sessionFocusRequests = 0
    /// 知らせを受ける入力欄か端末。nil なら見えているもの（⌘L）。2 つ並べた欄の間の移動（⌃] ⌃[）は相手を決めて送る
    @ObservationIgnored var sessionFocusTarget: ConversationKey?
    /// ⌘J・パネルを閉じたあと、全体のボードにキーのフォーカスを戻す知らせ
    var boardFocusRequests = 0
    var sessionCycleRequest = SessionCycleRequest()
    var newTaskSheet: NewTaskDraft?
    /// 案件を作るシート（作る先のマシン）
    var newBoardSheet: NewBoardDraft?
    /// 設定画面で開いている区分
    var settingsSection: SettingsSection = .connections
    /// Mac で設定ウィンドウを開く知らせ（値は回数）。`OpenSettingsAction` は view の環境にしか無いので、RootView が受けて開く
    var settingsWindowRequests = 0
    /// 別ウィンドウで開く知らせ（DebugServer の `/window/open` から）。RootView が `openWindow` で開いて nil に戻す
    var taskWindowRequest: TaskKey?
    var docWindowRequest: DocKey?
    /// 狭い幅（iPhone と狭い iPad）の設定で開いている区分（一覧から push した先）。`.settings` の行き先で区分を指定すると、そこまで進む
    var compactSettingsSection: SettingsSection?
    /// 設定の案件の区分で開いている案件（空なら一覧）
    var settingsBoardPath: [SettingsBoardKey] = []
    /// 設定に保存していない変更がある（案件の中身）。区分を移るときに確かめる
    var settingsDirty = false
    /// 未保存のまま移ろうとした先。`SettingsView` が確かめのダイアログを出す
    var settingsLeaveRequest: SettingsLeave?
    /// 設定の案件の、保存していない下書き（案件ごと）。設定の窓を閉じてもアプリを終えるまで残し、次に開くと続きから編集する。
    /// 開くときに読むだけなので追わない（追うと 1 字打つたびに案件の設定の画面が作り直される）
    @ObservationIgnored var settingsBoardDrafts: [SettingsBoardKey: BoardSettingsEdit] = [:]
    /// 外観。設定の「表示」で選び、再起動しても保つ
    /// fixtures（snapshot test）では保存した値を読まず、書かない
    var appearanceOverride: ColorScheme? {
        didSet {
            guard scenario == nil else { return }
            prefs.appearance = AppearanceChoice(appearanceOverride)
        }
    }
    /// 設定で非表示にしたマシン（接続設定の id）
    var hiddenMachines: Set<String> = DevicePrefs().hiddenMachines {
        didSet {
            prefs.hiddenMachines = hiddenMachines
            applyOnlyMachine()
        }
    }
    /// マシンの見出しに出す利用枠。設定で変えたら、見出しのバーがすぐ描き直されるよう model に持つ
    var usageWindows: Set<UsageWindowChoice> = DevicePrefs().usageWindows {
        didSet { prefs.usageWindows = usageWindows }
    }
    /// 今画面に出ている端末。DebugServer が入力と画面文字を取るために持つ。
    var activeTerminal: TerminalPaneController?
    /// 画面を離れて間もない端末（`AppModel+Terminals`）
    @ObservationIgnored let terminalShelf = TerminalShelf()
    /// 主スレッドの止まりなど、診断のイベントのログ
    @ObservationIgnored let eventLog = EventLog.standard()
    /// 主スレッドの止まりを書き出す。ユーザーのアプリだけで見張る（fixtures・test host・snapshot test は `EventLog.standard` と同じく外す。`--watchdog` なら見張る）
    @ObservationIgnored private var watchdog: MainThreadWatchdog?
    #if os(iOS)
    /// 止まりの記録を接続先の daemon へ送る（iPhone・iPad の手元の記録は Mac から読めない）
    @ObservationIgnored private(set) lazy var diagnostics = DiagnosticsReporter(defaults: AppDefaults.store)
    @ObservationIgnored private var hangReceiver: HangDiagnosticsReceiver?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    #endif
    /// 今見えている端末かチャットの操作（⌘F・⌘+ ⌘- ⌘0）
    @ObservationIgnored var sessionActions: SessionViewActions?

    func present(sessionActions actions: SessionViewActions) {
        sessionActions = actions
    }

    func withdraw(sessionActions actions: SessionViewActions) {
        if sessionActions?.owner == actions.owner { sessionActions = nil }
    }
    private(set) var scenario: String?
    private(set) var connectionNote: String?
    /// 窓ごとの直近の操作の失敗。操作した窓の帯（`FailureBanner`）に出し、閉じるか次の操作で消す。窓を閉じたら捨てる
    private(set) var failures: [WindowID: UserFacingError] = [:]
    /// 窓ごとの短い知らせ（「対応待ちはありません」など）。失敗と同じ帯の場所に出し、数秒で消える
    private(set) var notices: [WindowID: WindowNotice] = [:]
    /// 窓ごとに出している確認（`WindowRoot` のダイアログ）
    private(set) var confirmations: [WindowID: Confirmation] = [:]
    /// 開いている窓。開いたか前に出た順で、最後が前に出ている窓（`activeWindow`）
    @ObservationIgnored private(set) var windowOrder: [WindowID] = []
    /// 既存タスクに新しいセッションを起こすシート
    var launchSheet: LaunchDraft?
    /// 定期起動の追加・編集のシート（一覧の画面が出す。debug の `/schedules/form` も使う）
    var scheduleSheet: ScheduleDraft?
    /// マシンごとの作業ディレクトリの候補（`AppModel+Launch`）。起動の欄を開くたびに取り直す
    var workingDirectories: [MachineID: WorkingDirectories] = [:]
    /// オーケストレーターに送った指示（マシンごと。返事は daemon が `OrchestratorInfo.lastReply` で配る）
    private(set) var orchestratorHistory: [MachineID: [OrchestratorEntry]] = [:]
    private(set) var orchestratorBusy = false
    /// ⌘K の「オーケストレーターに指示…」のシート（Mac だけ）
    var orchestratorSheet: OrchestratorTarget?
    /// シートで選んだ送り先。選ぶまでは見ている画面のマシン（`orchestratorMachine`）
    var orchestratorTarget: MachineID?
    /// 設定の接続先の「iPhone・iPad を追加」の QR のシート
    var pairingSheet: PairingTarget?
    /// 読んだ QR・入れたコードの確認のシート
    var pairingOffer: PairingOffer?
    /// 「接続先を追加」のシートと、開いたときの画面（debug の `/connections/add` も開く）
    var addingConnection: AddConnectionSheet.Mode?
    /// 開いている文書。タスク画面の中央が端末から文書に切り替わる（iPhone はシート）
    var openDoc: DocKey?
    /// 送っている途中の無視（key は `InboxItem.id`、値は消した revision）。daemon が答えたら外す（`AppModel+Inbox`）。受信箱を組む `Fleet` が持つ
    var inboxPending: [String: String?] {
        get { fleet.inboxPending }
        set { fleet.inboxPending = newValue }
    }
    /// 最後に呼んだ事前起動（`prewarmConversation`）。同じ条件を続けて呼ばないため
    var lastPrewarm: PrewarmRecord?

    struct OrchestratorTarget: Identifiable, Hashable {
        let machine: MachineID
        var id: String { machine.rawValue }
    }

    struct OrchestratorEntry: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let sentAt: Date
    }

    init(options: LaunchOptions) {
        fleet.unreadConversations = unreadMarks.unread
        startWatchdog(force: options.watchdog)
        if let scenario = options.scenario {
            load(scenario: scenario)
        } else if options.offline {
            applyOnlyMachine()
            return
        } else if let url = options.daemonURL, let tokenFile = options.tokenFile {
            connect(url: url, tokenFile: URL(fileURLWithPath: NSString(string: tokenFile).expandingTildeInPath))
        } else {
            connectLocalDaemon()
        }
        if options.scenario == nil {
            appearanceOverride = prefs.appearance.colorScheme
            if !options.localOnly { connectSaved() }
        }
        applyOnlyMachine()
    }

    private func startWatchdog(force: Bool) {
        guard force || !AppDefaults.isScratch, let directory = EventLog.standardDirectory() else { return }
        let log = eventLog
        let newID: @Sendable () -> String = { String(UUID().uuidString.prefix(8)).lowercased() }
        let watchdog = MainThreadWatchdog(directory: directory) { [weak self] ms in
            Task { @MainActor in
                #if os(macOS)
                // 裏にいる間は App Nap が主スレッドの処理を遅らせ、人が待っていない遅れまで数えるので、前に出ているときだけ
                guard NSApplication.shared.isActive else { return }
                #endif
                log.record(AppEvent(at: Date(), type: "main.hitch", id: newID(), mode: self?.screenForDiagnostics, ms: ms))
            }
        } onStall: { [weak self] ms, file in
            Task { @MainActor in
                let id = newID()
                let screen = self?.screenForDiagnostics
                log.record(AppEvent(at: Date(), type: "main.stall", id: id, mode: screen, stage: file?.lastPathComponent, ms: ms))
                #if os(iOS)
                self?.recordDiagnostics([
                    AppDiagnosticReport(
                        id: "stall-\(id)", kind: .stall, at: Date(), durationMS: ms, screen: screen, appVersion: DiagnosticsReporter.appVersion,
                        osVersion: DiagnosticsReporter.osVersion)
                ])
                #endif
            }
        }
        watchdog.start()
        self.watchdog = watchdog
        #if os(iOS)
        // 背面ではプロセスごと止まるので、その間を止まりに数えない
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in watchdog.pause() },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                watchdog.resume()
                MainActor.assumeIsolated { self?.flushDiagnostics() }
            },
        ]
        hangReceiver = HangDiagnosticsReceiver { [weak self] reports in self?.recordDiagnostics(reports) }
        // 前の起動で送れなかった分。接続先は init の残りで足すので、init を終えてから送る
        Task { @MainActor [weak self] in self?.flushDiagnostics() }
        #endif
    }

    #if os(iOS)
    /// 止まりの記録を送る接続先（fixtures の接続は daemon でないので入らない）
    private var diagnosticsTargets: [String: DaemonEndpoint] {
        Dictionary(uniqueKeysWithValues: fleet.allMachines.keys.compactMap { id in
            (fleet.usageHistorySource(fleetID: id) as? DaemonClient).map { (id, $0.endpoint) }
        })
    }

    func recordDiagnostics(_ reports: [AppDiagnosticReport]) {
        diagnostics.record(reports, targets: diagnosticsTargets)
    }

    private func flushDiagnostics() {
        diagnostics.flush(targets: diagnosticsTargets)
    }
    #endif

    /// 引っかかりの記録に添える、今開いている画面（`board`、`task.side.chat` など）
    var screenForDiagnostics: String {
        guard selectedTask != nil else { return "board" }
        let view = activeTerminal != nil ? "terminal" : activeConversation != nil ? "chat" : "other"
        return "task.\(taskPresentation.rawValue).\(view)"
    }

    // MARK: 接続先

    /// Keychain に保存したリモートの daemon。中身（token・service token）は画面に出さない
    private(set) var connections: [SavedConnection] = []

    private func connectSaved() {
        connections = ConnectionStore.load()
        for connection in connections {
            fleet.add(id: connection.fleetID, source: DaemonClient(endpoint: connection.endpoint))
        }
    }

    /// 足すか差し替える。差し替えは繋ぎ直す
    func saveConnection(_ connection: SavedConnection) throws {
        try ConnectionStore.save(connection)
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        connections.sort { $0.name < $1.name }
        if scenario == nil {
            fleet.add(id: connection.fleetID, source: DaemonClient(endpoint: connection.endpoint))
        }
        applyOnlyMachine()
    }

    func deleteConnection(id: UUID) {
        ConnectionStore.delete(id: id)
        if let connection = connections.first(where: { $0.id == id }) { fleet.remove(id: connection.fleetID) }
        connections.removeAll { $0.id == id }
        applyOnlyMachine()
    }

    /// 起動引数で指定された daemon。token はファイルから読む（引数に平文で渡さない）。
    func connect(url: URL, tokenFile: URL) {
        do {
            let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            fleet.add(id: url.absoluteString, source: DaemonClient(endpoint: DaemonEndpoint(baseURL: url, token: token)))
            connectionNote = nil
        } catch {
            connectionNote = "token ファイルを読めない: \(error.localizedDescription)"  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
        }
    }

    /// 同一 Mac の daemon（token ファイルから）。iOS では daemon が無いので接続先無しのまま。
    func connectLocalDaemon() {
        #if os(macOS)
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let tokenFile = support.appending(path: "taskboard/token")
            let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            fleet.add(id: "local", source: DaemonClient(endpoint: .local(token: token)))
            connectionNote = nil
        } catch {
            connectionNote = "daemon の token を読めない: \(error.localizedDescription)"  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
        }
        #else
        connectionNote = "接続先が未設定"
        #endif
    }

    /// fixtures を読む。`stress+machine-second` のように `+` でつなぐと、1 つずつ別のマシンとして足す（オーケストレーターの送り先・設定の接続先と案件の確認用）
    func load(scenario name: String) {
        for id in fleet.allMachines.keys { fleet.remove(id: id) }
        do {
            var extras = FixtureExtras()
            for part in name.split(separator: "+").map(String.init) {
                let source = try FixtureSource.named(part)
                extras.conversations.merge(source.extras.conversations) { a, _ in a }
                extras.chatFiles.merge(source.extras.chatFiles) { a, _ in a }
                extras.codex = extras.codex ?? source.extras.codex
                fleet.add(id: "fixture:\(part)", source: source)
            }
            fixtureExtras = extras
            scenario = name
            connectionNote = nil
        } catch {
            connectionNote = "fixtures \(name) を読めない: \(error.localizedDescription)"  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
        }
    }

    /// 画面に出すマシン名（`machineName(fleetID:state:)`）。マシンが見つからなければ空
    func machineName(_ machine: MachineID) -> String {
        guard let fleetID = fleet.fleetID(for: machine) else { return "" }
        return machineName(fleetID: fleetID, fixtureName: fleet.identities[fleetID]?.name)
    }

    /// 接続先に付けた名前。同じ Mac は「このMac」。daemon のコンピュータ名（ホスト名）は出さない（docs/ui-copy.md）。
    /// 名前の無い接続は、debug の `--daemon-url` なら URL のホスト名。fixtures は、接続先に付ける名前の代わりにデータの中のマシンの名前
    /// （撮った画面を、実際の接続先と同じ見た目にするため）
    func machineName(fleetID: String, state: MachineState?) -> String {
        machineName(fleetID: fleetID, fixtureName: state?.machine?.name)
    }

    /// `fixtureName` は fixtures の接続先に出す、データの中のマシンの名前
    func machineName(fleetID: String, fixtureName: String?) -> String {
        if let saved = connections.first(where: { $0.fleetID == fleetID }) { return saved.name }
        if Self.isThisMac(fleetID: fleetID) { return String(localized: "このMac") }
        if fleetID.hasPrefix("fixture:") { return fixtureName ?? String(fleetID.dropFirst("fixture:".count)) }
        return URL(string: fleetID)?.host() ?? fleetID
    }

    /// 同じ Mac の daemon への接続か。同じ Mac の既定の接続（`local`）と、ループバックのアドレスの接続
    /// 同じ Mac の daemon のマシンか（`machineName(fleetID:state:)` が「このMac」とする接続）
    func isThisMac(_ machine: MachineID) -> Bool {
        guard let fleetID = fleet.fleetID(for: machine) else { return false }
        return Self.isThisMac(fleetID: fleetID)
    }

    static func isThisMac(fleetID: String) -> Bool {
        if fleetID == "local" { return true }
        guard let host = URL(string: fleetID)?.host() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    // MARK: 並び

    /// サイドバーと全体のボードに出すマシン（この端末で並べ替えた順）
    var orderedMachines: [(id: String, state: MachineState)] {
        let ids = SidebarOrder.arrange(fleet.machines.keys.sorted(), by: machineOrder)
        return ids.compactMap { id in fleet.machines[id].map { (id, $0) } }
    }

    func moveMachines(from source: IndexSet, to destination: Int) {
        machineOrder = SidebarOrder.move(orderedMachines.map(\.id), from: source, to: destination)
    }

    /// サイドバーの順。`includeArchived` は設定の案件の一覧だけ
    func orderedBoards(_ state: MachineState, fleetID: String, includeArchived: Bool = false) -> [Board] {
        let boards = includeArchived ? state.boards : state.activeBoards
        let byPosition = boards.values.sorted { ($0.position, $0.name) < ($1.position, $1.name) }
        let order = boardOrders[fleetID] ?? prefs.boardOrder(machine: fleetID)
        let ids = SidebarOrder.arrange(byPosition.map(\.id), by: order)
        return ids.compactMap { boards[$0] }
    }

    /// 1 マシンの案件（サイドバーの順）
    func orderedBoards(on machine: MachineID) -> [Board] {
        guard let (fleetID, state) = fleet.allMachines.first(where: { $0.value.machine?.id == machine }) else { return [] }
        return orderedBoards(state, fleetID: fleetID)
    }

    /// 表示しているマシン全部の案件。マシンもマシンの中もサイドバーの順（起票のシートの選択肢）
    var orderedBoardsAcrossMachines: [Board] {
        orderedMachines.flatMap { orderedBoards($0.state, fleetID: $0.id) }
    }

    func moveBoards(_ state: MachineState, fleetID: String, includeArchived: Bool = false, from source: IndexSet, to destination: Int) {
        let order = SidebarOrder.move(orderedBoards(state, fleetID: fleetID, includeArchived: includeArchived).map(\.id), from: source, to: destination)
        boardOrders[fleetID] = order
        prefs.setBoardOrder(order, machine: fleetID)
    }

    func toggleCollapsed(_ fleetID: String) {
        if collapsedMachines.contains(fleetID) { collapsedMachines.remove(fleetID) } else { collapsedMachines.insert(fleetID) }
    }

    // MARK: 操作の土台

    func source(for machine: MachineID) -> (any DaemonWriter)? {
        guard let source = fleet.terminalSource(for: machine) else {
            failures[activeWindow] = writeBlock(machine, "変更できませんでした") ?? UserFacingError("変更できませんでした", remedy: UserFacingError.retry)
            return nil
        }
        return source
    }

    func requireSource(_ machine: MachineID) throws -> any DaemonWriter {
        guard let source = fleet.terminalSource(for: machine) else { throw ActionError.notWritable(fleet.writeAccess(machine)) }
        return source
    }

    /// 画面の操作を出すか、押せるようにするか。理由の文は `writeBlock`
    func canWrite(_ machine: MachineID) -> Bool {
        fleet.writeAccess(machine) == .writable
    }

    /// 書き込めないときに操作の近くに出す文。event は「{操作}できません」。書き込めれば nil
    func writeBlock(_ machine: MachineID, _ event: LocalizedStringResource) -> UserFacingError? {
        let access = fleet.writeAccess(machine)
        guard access != .writable, let reason = UserFacingError.reason(access) else { return nil }
        return UserFacingError(event, cause: reason.cause, remedy: reason.remedy)
    }

    enum ActionError: Error {
        case notWritable(WriteAccess)
    }

    // MARK: 失敗と確認の出し先（窓ごと）

    /// 操作を始める。前に出ている窓の失敗を消し、その窓を返す。後から届く失敗はその窓に出す
    @discardableResult
    func beginAction() -> WindowID {
        failures[activeWindow] = nil
        return activeWindow
    }

    /// 操作の失敗を、その窓の帯に出す。event は「{操作}できませんでした」。取り消しなら出さない
    func fail(_ event: LocalizedStringResource, _ error: any Error, in window: WindowID) {
        if let failure = UserFacingError(event, error: error) { failures[window] = failure }
    }

    func failure(in window: WindowID) -> UserFacingError? {
        failures[window]
    }

    func clearFailure(in window: WindowID) {
        failures[window] = nil
    }

    /// 前に出ている窓に短い知らせを出す。失敗が出ていればそちらを残す（帯は 1 つ）
    func inform(_ text: String) {
        notices[activeWindow] = WindowNotice(text: text)
    }

    func notice(in window: WindowID) -> WindowNotice? {
        notices[window]
    }

    /// 出した知らせが替わっていなければ消す（数秒たった帯が、後から出た知らせを消さないよう id で比べる）
    func clearNotice(_ id: UUID, in window: WindowID) {
        if notices[window]?.id == id { notices[window] = nil }
    }

    /// 確認を前に出ている窓に出す。対象が無くなっていれば出さない
    func ask(_ confirmation: Confirmation) {
        guard exists(confirmation) else { return }
        confirmations[activeWindow] = confirmation
    }

    /// その窓で出している確認。出した後に対象が無くなっていれば nil（ダイアログを閉じる）
    func confirmation(in window: WindowID) -> Confirmation? {
        confirmations[window].flatMap { exists($0) ? $0 : nil }
    }

    func dismissConfirmation(in window: WindowID) {
        confirmations[window] = nil
    }

    /// 確認を通す。対象を照らし直し、無くなっていれば何もしない
    func confirm(in window: WindowID) {
        guard let confirmation = confirmations.removeValue(forKey: window), exists(confirmation) else { return }
        switch confirmation {
        case .restartOrchestrator(let machine):
            restartOrchestrator(on: machine)
        case .endTaskSessions(let key):
            if let task = fleet.task(for: key) { endAll(task) }
        }
    }

    /// 前に出ている窓。操作の始め（`beginAction`）と確認を出すときに捕まえ、失敗と確認の出し先にする。
    /// アプリが前面に来る前も、最後に開いた窓に出す（どこにも出ない失敗を作らない）
    var activeWindow: WindowID { windowOrder.last ?? .unattached }

    /// 窓を開いたときと前に出たとき
    func activate(_ window: WindowID) {
        windowOrder.removeAll { $0 == window }
        windowOrder.append(window)
    }

    /// 窓を閉じたら、その窓の失敗と確認を捨てる。前に出ている窓は、その前の窓に戻る
    func closeWindow(_ window: WindowID) {
        windowOrder.removeAll { $0 == window }
        failures[window] = nil
        notices[window] = nil
        confirmations[window] = nil
    }

    private func exists(_ confirmation: Confirmation) -> Bool {
        switch confirmation {
        case .restartOrchestrator(let machine): fleet.machineState(for: machine) != nil
        case .endTaskSessions(let key): fleet.task(for: key).map { !endTargets(of: $0).isEmpty } ?? false
        }
    }

    // MARK: 起動とオーケストレーター（private(set) の値を書くので本体に置く）

    /// 指示を送る。失敗は呼び手が出す（シートは自分の帯に、iPhone の帯は画面の帯に）
    func sendToOrchestrator(_ text: String, on machine: MachineID) async throws {
        guard let source = source(for: machine) else { throw ActionError.notWritable(fleet.writeAccess(machine)) }
        orchestratorBusy = true
        defer { orchestratorBusy = false }
        _ = try await source.promptOrchestrator(text)
        orchestratorHistory[machine, default: []].append(OrchestratorEntry(text: text, sentAt: Date()))
    }

    // MARK: 会話の入力欄と名前

    /// fixtures の会話（daemon に繋いでいるときは空）。snapshot test が値の無い形を描くときに書き換える
    var fixtureExtras = FixtureExtras()
    /// 名前を付け直している会話（`SessionRenameSheet`）
    var renaming: RenameTarget?
    /// 使っていないworktreeの削除のシート（`WorktreeCleanupSheet`）
    var worktreeCleanup: WorktreeCleanupTarget?
    /// 会話の入力欄に貼った、送る前の画像。画面を離れても、送るか外すまで残す
    var chatImageDrafts: [ConversationKey: [ChatDraftImage]] = [:]
    var chatFileDrafts: [ConversationKey: [ChatDraftFile]] = [:]
    /// 入力欄の書きかけの文とカーソル（観測しない）
    @ObservationIgnored let chatDrafts = ChatDraftTexts(store: AppDefaults.store)
    /// 巻き戻した会話の［元に戻す］のバーを消した・送った印。画面が作り直されても、アプリを開き直しても残る
    var rewindNoticeDismissals = RewindNoticeDismissals(store: AppDefaults.store)
    /// サイドバーのタスクの行の「未読」の印。この端末で見たかで決め、アプリを開き直しても残る。見張り盤の札の未読にも渡す
    var unreadMarks = UnreadMarks(store: AppDefaults.store) {
        didSet { fleet.unreadConversations = unreadMarks.unread }
    }
}
