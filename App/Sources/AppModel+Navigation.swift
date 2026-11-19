import Foundation
import TaskboardKit
#if os(iOS)
import UIKit
#endif

/// 画面の行き先。サイドバー・パレット・メニュー・通知・`taskboard://` の URL・debug の口が、どれも `AppModel.navigate(to:)` を通る
enum Destination: Hashable {
    /// すべての案件
    case overview
    case board(machine: MachineID, id: String)
    /// タスクを開く。`doc` はその文書も開き、`focus` は札（iPhone は積む画面）で選ぶ。
    /// `revealBoard` なら全体のボードをその案件までスクロールする（カードを押したときは、見ている位置のままにする）
    case task(TaskKey, doc: DocKey? = nil, focus: ConversationKey? = nil, revealBoard: Bool = true)
    /// 文書を開く（そのタスクの画面に移ってから）
    case doc(DocKey)
    /// 会話を開く。置き場の画面でその会話を選ぶ
    case conversation(ConversationKey)
    /// PR を開く。結んだタスクがあればその画面の PR の欄、無ければ PR を取ったマシンのタスクなしの画面
    case pullRequest(url: String)
    /// オーケストレーターの画面。マシンが無ければ送り先のマシン（`orchestratorMachine`）
    case orchestrator(MachineID?, focus: ConversationKey? = nil)
    /// マシンのタスクなしの画面
    case unassigned(MachineID, focus: ConversationKey? = nil)
    /// 設定。Mac は ⌘, の設定ウィンドウ、iPad はサイドバーの「設定」、iPhone は「設定」タブ
    case settings(SettingsSection)

    init(_ link: TaskboardLink) {
        switch link {
        case .pullRequest(let url): self = .pullRequest(url: url)
        case .orchestrator(let machine): self = .orchestrator(machine)
        case .conversation(let key): self = .conversation(key)
        case .boards: self = .overview
        case .board(let machine, let id): self = .board(machine: machine, id: id)
        case .task(let key, let doc): self = .task(key, doc: doc.map { DocKey(machine: key.machine, id: $0) })
        case .unassigned(let machine): self = .unassigned(machine)
        }
    }
}

extension Destination {
    /// `nav.open` の記録に書く行き先の種類
    var logName: String {
        switch self {
        case .overview: "overview"
        case .board: "board"
        case .task: "task"
        case .doc: "doc"
        case .conversation: "conversation"
        case .pullRequest: "pull_request"
        case .orchestrator: "orchestrator"
        case .unassigned: "unassigned"
        case .settings: "settings"
        }
    }

    var logMachine: MachineID? {
        switch self {
        case .overview, .pullRequest, .settings: nil
        case .board(let machine, _), .unassigned(let machine, _): machine
        case .task(let key, _, _, _): key.machine
        case .doc(let key): key.machine
        case .conversation(let key): key.machine
        case .orchestrator(let machine, _): machine
        }
    }
}

/// 画面を開いた経路。`nav.open` の記録に残し、経路ごとの手数を数える
enum NavigationSource: String {
    case sidebar
    case board
    case palette
    /// キーボードのショートカットとメニュー
    case key
    case notification
    /// 受信箱と［次の入力待ちへ移動］
    case attention
    /// 画面の中のボタンとリンク
    case link
    /// 起票・fork・紐づけなどの操作の後に、アプリが移る
    case app
    /// 外から開いた `taskboard://` の URL
    case url
    case debug
}

/// 会話を並べる画面（札の並びを持つ画面）
enum SessionScope: Hashable {
    case task(TaskKey)
    case orchestrator(MachineID)
    case unassigned(MachineID)

    var machine: MachineID {
        switch self {
        case .task(let key): key.machine
        case .orchestrator(let machine), .unassigned(let machine): machine
        }
    }

    var home: SessionHome {
        switch self {
        case .task(let key): .task(key.number)
        case .orchestrator: .orchestrator
        case .unassigned: .unassigned
        }
    }

    init(_ home: SessionHome, on machine: MachineID) {
        switch home {
        case .task(let number): self = .task(TaskKey(machine: machine, number: number))
        case .orchestrator: self = .orchestrator(machine)
        case .unassigned: self = .unassigned(machine)
        }
    }
}

/// 画面を開いたときに札で選ぶもの（`AppModel.sessionFocus`）。`beside` ならタスク画面の右に 2 つ目として並べる
struct SessionFocus: Hashable {
    let scope: SessionScope
    let item: ConversationKey
    var beside = false
}

/// 画面の移り方（サイドバー・iPhone のタブとスタック・`taskboard://` の URL）
extension AppModel {
    /// iPhone の殻（タブ）を使う端末か。札で選ぶか画面に積むかもこれで分ける（`RootView`）
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// 行き先へ移る。行き先ごとに、開いていたタスク（と文書）のどれを閉じるかはこの中で決める
    func navigate(to destination: Destination, from source: NavigationSource) {
        logNavigation(destination, from: source)
        route(to: destination)
    }

    func logNavigation(_ destination: Destination, from source: NavigationSource) {
        eventLog.record(AppEvent(at: Date(), type: "nav.open", id: String(UUID().uuidString.prefix(8)).lowercased(), machine: destination.logMachine?.rawValue, mode: source.rawValue, stage: destination.logName))
    }

    /// 画面の中で会話を選び替えた（札・⌃Tab）。`via` は `pill`・`beside`（右に並べる）・`key`
    func logConversationSelect(_ key: ConversationKey, via: String) {
        eventLog.record(AppEvent(
            at: Date(), type: "conversation.select", id: String(UUID().uuidString.prefix(8)).lowercased(), machine: key.machine.rawValue, pane: key.id, mode: via))
    }

    private func route(to destination: Destination) {
        switch destination {
        case .overview:
            closeTask()
            sidebar = .overview
            showPhone(.overview)
        case .board(let machine, let id):
            // 案件を選び直したのにパネルが前のタスクのまま残らないよう、開いていたタスクは閉じる
            closeTask()
            sidebar = .board(machine: machine, id: id)
            showPhone(sidebar)
        case .task(let key, let doc, let focus, let revealBoard):
            openTask(key, revealBoard: revealBoard)
            if let doc { openDoc = doc }
            if let focus { self.focus(focus, in: .task(key)) }
        case .doc(let key):
            if let doc = fleet.document(for: key) { openTask(TaskKey(machine: doc.machine, number: doc.taskNumber), revealBoard: true) }
            openDoc = key
        case .conversation(let key):
            open(key, in: conversationScope(for: key))
        case .pullRequest(let url):
            if let task = tasks(linkedTo: url).first {
                route(to: .task(task.id))
            } else if let machine = (fleet.machinesFetching(url: url) + fleet.machines.values.compactMap { $0.machine?.id }).first {
                route(to: .unassigned(machine))
            } else {
                return
            }
            show(pr: url)
        case .orchestrator(let machine, let focus):
            // 動いていても止まっていても同じ画面で、止まっていれば画面の［起動］から起こす。iPhone は「タスク」タブに積む
            guard let machine = machine ?? orchestratorMachine else { return }
            closeTask()
            sidebar = .orchestrator(machine: machine)
            showPhone(sidebar)
            if let focus { self.focus(focus, in: .orchestrator(machine)) }
        case .unassigned(let machine, let focus):
            closeTask()
            sidebar = .unassigned(machine: machine)
            showPhone(sidebar)
            if let focus { self.focus(focus, in: .unassigned(machine)) }
        case .settings(let section):
            settingsSection = section
            #if os(macOS)
            settingsWindowRequests += 1
            #else
            closeTask()
            sidebar = .settings
            if Self.isPhone { showPhone(.settings) }
            // 狭い幅の設定は区分の一覧から押して開くので、開く区分を積む（iPhone と、狭い iPad）。`showPhone` が外すので後に入れる
            compactSettingsSection = section
            #endif
        }
    }

    private func open(_ item: ConversationKey, in scope: SessionScope) {
        switch scope {
        case .task(let task): route(to: .task(task, focus: item))
        case .orchestrator(let machine): route(to: .orchestrator(machine, focus: item))
        case .unassigned(let machine): route(to: .unassigned(machine, focus: item))
        }
    }

    /// `taskboard://…` の遷移（通知・DebugServer）。開いていた起票と起動のシートは閉じる
    func open(_ url: URL, from source: NavigationSource) {
        guard let link = TaskboardLink(url: url) else { return }
        newTaskSheet = nil
        launchSheet = nil
        navigate(to: Destination(link), from: source)
    }

    /// 画面の中で選ぶ会話。iPhone は画面の上に積み、Mac と iPad は札で選ぶ
    func focus(_ item: ConversationKey, in scope: SessionScope) {
        if Self.isPhone {
            phoneTaskItem = item
        } else {
            sessionFocus = SessionFocus(scope: scope, item: item)
        }
    }

    /// タスクを開く。サイドビューならそのボードをサイドバーで選び、詳細にタスクを出す。別のタスクなら開いていた文書は閉じる
    private func openTask(_ key: TaskKey, revealBoard: Bool) {
        cursorTask = key
        if let task = fleet.task(for: key) {
            markRead(task)
            let item = SidebarItem.board(machine: key.machine, id: task.boardID)
            // 中央・全面ではボードがタスクに隠れるので、裏の画面は替えない。閉じると開く前の画面に戻る
            if taskPresentation == .side {
                // 「すべての案件」を見ているときは、全部を出したままその案件まで送る（開いたカードの案件だけに絞らない）。
                // 案件を選んでいるときはその案件だけを出し、送らない（選び直した直後の面は、描き終わる前に送るとサイドバーの分を数えずに止まった）
                if sidebar == .overview {
                    if revealBoard { overviewScrollTarget = "\(key.machine.rawValue)/\(task.boardID)" }
                } else if sidebar != item {
                    sidebar = item
                }
            }
            showPhone(item)
        }
        if selectedTask != key { openDoc = nil }
        selectedTask = key
    }

    func closeTask() {
        selectedTask = nil
        openDoc = nil
    }

    func closeDoc() {
        openDoc = nil
    }

    /// 会話の画面の［タスクを開く］。タスクの画面だけを積み直す（スタックはタスク → 会話の順にしか積めない）
    func openTaskFromPhoneConversation(_ conversation: Conversation) {
        guard let task = taskKey(of: conversation) else { return }
        phoneTaskRoutes = [.task(task)]
    }

    /// 会話が結ばれた、今あるタスク
    func taskKey(of conversation: Conversation) -> TaskKey? {
        guard let number = conversation.taskNumber else { return nil }
        let key = TaskKey(machine: conversation.machine, number: number)
        return fleet.task(for: key) == nil ? nil : key
    }

    /// 「タスク」タブのスタックの中身。ボード・オーケストレーター・タスクなし、開いているタスク、そこから開いた会話の順に積む
    var phoneTaskRoutes: [PhoneRoute] {
        get {
            var routes = phoneTaskPath.map(PhoneRoute.item)
            if let selectedTask { routes.append(.task(selectedTask)) }
            if let phoneTaskItem { routes.append(.conversation(phoneTaskItem)) }
            return routes
        }
        set {
            phoneTaskPath = newValue.compactMap { if case .item(let item) = $0 { item } else { nil } }
            let task = newValue.lazy.compactMap { if case .task(let key) = $0 { key } else { nil } }.last
            if selectedTask != task {
                if task == nil { closeTask() } else { selectedTask = task }
            }
            // 開いているタスクが替わると `selectedTask` が積んだ画面を外すので、その後に入れる
            phoneTaskItem = newValue.lazy.compactMap { if case .conversation(let key) = $0 { key } else { nil } }.last
        }
    }

    /// iPhone でその項目のタブを開く
    func showPhone(_ item: SidebarItem) {
        compactSettingsSection = nil
        switch item {
        case .settings:
            phoneTab = .settings
        case .overview:
            phoneTab = .tasks
            phoneTaskPath = []
        case .board, .orchestrator, .unassigned:
            phoneTab = .tasks
            phoneTaskPath = [item]
        }
    }
}
