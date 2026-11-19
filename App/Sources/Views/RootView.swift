import SwiftUI
import TaskboardKit

/// プラットフォームごとの殻。Mac と iPad はサイドバーと中身の 2 列、iPhone はタブ。
struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            #if os(iOS)
            if AppModel.isPhone {
                phoneTabs
            } else {
                splitView
            }
            #else
            splitView
            #endif
        }
        .pageInsets()
        .sheet(item: $model.newTaskSheet) { draft in
            NewTaskSheet(draft: draft)
        }
        .sheet(item: $model.renaming) { target in SessionRenameSheet(target: target.conversation) }
        .sheet(item: $model.worktreeCleanup) { target in WorktreeCleanupSheet(machine: target.machine) }
        .sheet(item: $model.newBoardSheet) { draft in NewBoardSheet(draft: draft) }
        .sheet(isPresented: $model.paletteOpen) { CommandPalette() }
        #if os(macOS)
        .sheet(item: $model.orchestratorSheet) { target in OrchestratorSheet(machine: target.machine) }
        #endif
        .sheet(isPresented: $model.shortcutsOpen) { ShortcutOverlay() }
        .sheet(item: $model.scheduleSheet) { draft in ScheduleForm(draft: draft) }
        #if os(macOS)
        .onAppear { MenuCheckmarks.start(model: model) }
        .onChange(of: model.settingsWindowRequests) { _, _ in openSettings() }
        .onChange(of: model.taskWindowRequest) { _, key in
            guard let key else { return }
            openWindow(value: key)
            model.taskWindowRequest = nil
        }
        .onChange(of: model.docWindowRequest) { _, key in
            guard let key else { return }
            openWindow(value: key)
            model.docWindowRequest = nil
        }
        #endif
    }

    #if os(iOS)
    /// iPhone は「タスク」と「設定」の 2 本
    private var phoneTabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.phoneTab) {
            Tab("タスク", systemImage: "rectangle.grid.2x2", value: PhoneTab.tasks) {
                // タスクも path に積む。navigationDestination(item:) で出すと、別のタスクに替えたときに閉じた知らせで選択が消え、
                // タスクの画面から開くセッションも path に載らずに押せなかった
                NavigationStack(path: $model.phoneTaskRoutes) {
                    PhoneTaskList()
                        .navigationTitle("タスク")
                        .navigationDestination(for: PhoneRoute.self) { route in
                            switch route {
                            case .item(.board(let machine, let id)):
                                if let board = model.fleet.board(id: id, on: machine) {
                                    BoardView(board: board)
                                } else {
                                    EmptyState("この案件はありません", symbol: "rectangle.grid.2x2", message: "一覧から別の案件を開いてください。")
                                }
                            case .item(.orchestrator(let machine)):
                                OrchestratorScreen(machine: machine)
                            case .item(.unassigned(let machine)):
                                UnassignedScreen(machine: machine)
                            case .item:
                                EmptyView()
                            case .task(let key):
                                TaskDetailScreen(key: key)
                            case .conversation(let key):
                                ConversationView(key: key, feed: model.conversationFeed(for: key)).id(key)
                            }
                        }
                }
                .modifier(FailureBanner())
            }
            .badge(model.inboxWaitingCount)
            Tab("設定", systemImage: "gearshape", value: PhoneTab.settings) {
                NavigationStack {
                    SettingsView()
                }
                .modifier(FailureBanner())
            }
        }
    }
    #endif

    /// Mac / iPad はサイドバーと、全体のボード（か一覧）。タスクはその右（サイド）・全面・中央に開く。
    private var splitView: some View {
        NavigationSplitView {
            OverviewSidebar()
                .navigationSplitViewColumnWidth(min: WindowMetrics.sidebar.min, ideal: WindowMetrics.sidebar.ideal)
        } detail: {
            MinimumFrame(minimum: WindowMetrics.detailColumn) { TaskPresentationHost { detailContent } }
                .toolbar {
                    if let label = model.onlyMachineLabel {
                        ToolbarItem(placement: Self.onlyMachinePlacement) { OnlyMachineBadge(label: label) }
                    }
                }
        }
        .modifier(FailureBanner())
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.sidebar {
        case .settings:
            // Mac は設定ウィンドウで開くので、ここに来るのは iPad だけ
            SettingsView()
        case .orchestrator(let machine):
            // マシンが替わったら帯の押した値（常駐）を持ち越さない
            OrchestratorScreen(machine: machine).id(machine)
        case .unassigned(let machine):
            UnassignedScreen(machine: machine).id(machine)
        case .overview, .board:
            NavigationStack { HomeScreen() }
        }
    }
}

extension RootView {
    #if os(macOS)
    static let onlyMachinePlacement = ToolbarItemPlacement.status
    #else
    static let onlyMachinePlacement = ToolbarItemPlacement.topBarLeading
    #endif
}

/// 1 台だけ表示の間、ツールバーに出す「◯◯ のみ」。押すと解除し、メニューで残すマシンを選び直す
struct OnlyMachineBadge: View {
    @Environment(AppModel.self) private var model
    let label: String

    var body: some View {
        Menu {
            Picker("表示するMac", selection: Binding(get: { model.onlyMachineID }, set: { model.onlyMachineID = $0 })) {
                ForEach(model.onlyMachineCandidates, id: \.id) { candidate in
                    Text(candidate.name).tag(candidate.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("1台だけ表示を解除") { model.onlyMachineEnabled = false }
        } label: {
            Label(label, systemImage: "eye.slash")
                .labelStyle(.titleAndIcon)
        } primaryAction: {
            model.onlyMachineEnabled = false
        }
        .tint(.orange)
        .help("押すと解除します（⌃⌘1）。▾で表示するMacを選べます。")
    }
}

