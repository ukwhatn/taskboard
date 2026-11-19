import SwiftUI
import TaskboardKit

/// 全マシン・全案件を 1 枚に縦に積んだボード（サイドバーで案件を選ぶと、その案件だけ。`AppModel.overviewSections`）。案件ごとに列を横に並べる。縦と横は 1 枚のスクロールの面で、
/// サイドビューを開いていても、どこからでも横に送れる（案件ごとに横のスクロールを持つと、入力が別の帯か外側の縦に行く）。
/// マシンと案件の見出しは横に送っても左端に留める（`stickyLeading`）。縦には貼り付けない（送った案件の見出しに重なる）。
/// タスクを開くと、その案件までスクロールする（`AppModel.overviewScrollTarget`）。
struct OverviewBoard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    /// ↑↓←→ / hjkl / ↩ / Esc を受ける。端末やチャットの入力にフォーカスがある間は、そちらがキーを取る
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        let sections = model.overviewSections
        // LazyVStack は組んだ子の幅を中身の幅にし、組む前の帯は大きさ 0。どの子にもいちばん広い帯の幅を付けないと、横に送れない。
        // LazyVStack の外に付けると、組んだ子で決まる幅と外の幅の間で組み直しが止まらなくなった
        let width = contentWidth(sections)
        Group {
            if sections.isEmpty {
                EmptyState(title: "接続先はありません", symbol: "network", message: "接続先を追加すると、そのMacの案件がここに並びます。") {
                    Button("接続先を追加") { model.navigate(to: .settings(.connections), from: .link) }
                }
            } else {
                FillContainer {
                    ScrollViewReader { proxy in
                        ScrollView([.horizontal, .vertical]) {
                            // 帯は画面に入ったものだけを組む（全部を組むと、組むときと案件へ移って片付けるときに主スレッドが 100 ms を超えて止まった）。
                            // LazyVStack は子に面の幅を渡すので、子は横を `fixedSize` で中身の幅にする（付けないと案件の名前が切れる）
                            LazyVStack(alignment: .leading, spacing: Space.section) {
                                ForEach(sections, id: \.id) { section in
                                    Section {
                                        if !section.collapsed {
                                            machineBody(fleetID: section.id, state: section.state, boards: section.boards, width: width)
                                        }
                                    } header: {
                                        OverviewMachineHeader(fleetID: section.id, state: section.state, collapsible: model.focusedBoard == nil)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .stickyLeading()
                                            .frame(minWidth: width, alignment: .leading)
                                    }
                                }
                            }
                            // 縦の contentMargins は、LazyVStack に幅を付けないと効かなかった
                            .padding(.vertical, Space.block)
                        }
                        // 2 方向のスクロールでは、面より小さい中身が真ん中に置かれる。上と左に寄せる
                        .defaultScrollAnchor(.topLeading)
                        .modifier(OverviewBoardPosition())
                        .background { OverviewBoardScroller(proxy: proxy, keyboardFocused: $keyboardFocused) }
                    }
                }
                .clipLeadingEdge()
                .focusable()
                .focusEffectDisabled()
                .focused($keyboardFocused)
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape]) { press in handle(press) }
                .onKeyPress(characters: CharacterSet(charactersIn: "hjkl"), phases: .down) { press in handle(press) }
            }
        }
        .navigationTitle("案件")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("タスクを追加", systemImage: "plus") {
                    if let board = defaultBoard { model.newTaskSheet = NewTaskDraft(board: board) }
                }
                .disabled(defaultBoard == nil)
                .help("タスクを追加（⌘N）")
            }
        }
    }

    @ViewBuilder
    private func machineBody(fleetID: String, state: MachineState, boards: [Board], width: CGFloat) -> some View {
        if boards.isEmpty {
            HStack(spacing: Space.row) {
                Text(state.connected ? "案件はありません" : "接続していないため、案件を表示できません。").textRole(.secondary)
                if state.connected, let machine = state.machine?.id, model.canWrite(machine) {
                    Button("案件を追加") { model.startNewBoard(on: machine) }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .stickyLeading()
            .frame(minWidth: width, alignment: .leading)
        }
        ForEach(boards) { board in
            // 横の余白は帯の中に持たせる（2 方向のスクロールで横の contentMargins を使うと、ウィンドウの外で描いたときに初めの位置で余白が隠れた）。
            // 外側の VStack に持たせると、サイドバーで選んだ帯の左端に送ったときに余白の分だけ右に止まる。
            // 帯は 1 回に 1 つずつ組む（8 案件を 1 回で組むと、主スレッドが 190 ms 止まった）
            DeferredMount(lane: .later) {
                BoardStrip(board: board, tasks: state.tasks.values.filter { $0.boardID == board.id }.sorted { $0.number < $1.number })
                    .equatable()
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, inset)
            .frame(minWidth: width, alignment: .leading)
            .id("\(board.machine.rawValue)/\(board.id)")
        }
    }

    /// 並んでいる帯のうち、いちばん広いものの幅（左右の余白を含む）
    private func contentWidth(_ sections: [AppModel.OverviewSection]) -> CGFloat {
        let widest = sections.filter { !$0.collapsed }.flatMap(\.boards).map { board in
            BoardColumnSegment.rowWidth(board.columns, expanded: model.overviewExpandedColumns["\(board.machine.rawValue)/\(board.id)"] ?? [])
        }.max() ?? 0
        return widest + inset * 2
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌥⌘← → などの修飾キー付きはメニューに任せる
        guard press.modifiers.subtracting([.numericPad, .function]).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: model.moveCursor(.up)
        case .downArrow: model.moveCursor(.down)
        case .leftArrow: model.moveCursor(.left)
        case .rightArrow: model.moveCursor(.right)
        case .return: model.openCursor()
        case .escape:
            guard model.selectedTask != nil else { return .ignored }
            model.closeTask()
        default:
            switch press.characters {
            case "k": model.moveCursor(.up)
            case "j": model.moveCursor(.down)
            case "h": model.moveCursor(.left)
            case "l": model.moveCursor(.right)
            default: return .ignored
            }
        }
        return .handled
    }

    /// ⌘N の行き先: サイドバーで選んだ案件、無ければ先頭の案件
    private var defaultBoard: Board? {
        if case .board(let machine, let id) = model.sidebar, let board = model.fleet.board(id: id, on: machine) {
            return board
        }
        for machine in model.orderedMachines {
            if let board = model.orderedBoards(machine.state, fleetID: machine.id).first { return board }
        }
        return nil
    }
}

/// 面の位置。案件を選び直したら左上に戻す（前の案件で送った位置を引き継がない）。面を `.id` で作り直して戻すと、切り替えのたびに
/// 全部の帯とカードを組み直し、主スレッドが 90 ms ほど止まった。debug の `/board/scroll` もこの位置を動かす。
/// 位置の状態をこの modifier に持ち、スクロールのたびに OverviewBoard の body を作り直さない
private struct OverviewBoardPosition: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var position = ScrollPosition(idType: TaskKey.self)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onChange(of: model.sidebar) { _, _ in position.scrollTo(point: .zero) }
            #if DEBUG
            .onChange(of: model.debugBoardScrollY) { _, y in if let y { position.scrollTo(y: y) } }
            .onScrollGeometryChange(for: [CGFloat].self) {
                [$0.containerSize.width, $0.containerSize.height, $0.contentSize.width, $0.contentSize.height, $0.contentOffset.x, $0.contentOffset.y]
            } action: { _, v in
                model.debugBoardScrollSizes = (CGSize(width: v[0], height: v[1]), CGSize(width: v[2], height: v[3]), CGPoint(x: v[4], y: v[5]))
            }
            #endif
    }
}

/// 全体のボードのスクロールとフォーカスの受け直し。選択・カーソル・スクロールの目標を読むのはこのビューだけ
/// （OverviewBoard の body で読むと、カーソルを動かすたびに全案件の帯を作り直す）
private struct OverviewBoardScroller: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy
    var keyboardFocused: FocusState<Bool>.Binding

    var body: some View {
        Color.clear
            .onChange(of: model.overviewScrollTarget) { _, target in
                guard let target else { return }
                reveal(target)
                model.overviewScrollTarget = nil
            }
            .onAppear {
                if let target = model.overviewScrollTarget {
                    reveal(target)
                    model.overviewScrollTarget = nil
                }
                keyboardFocused.wrappedValue = true
            }
            .onChange(of: model.cursorTask) { old, key in
                // 中央・全面に開いたタスクの裏では送らない（隠れたボードを計り直すだけで、閉じたときに見ていた位置から動いている）
                guard let key, !model.taskCoversBoard else { return }
                // 帯は画面に入るまで組まないので、別の帯のカードはまだ無い。先にその帯へ送り、組み終えてからカードへ送る
                if let strip = stripID(of: key), strip != old.flatMap(stripID) {
                    proxy.scrollTo(strip, anchor: .topLeading)
                    MountQueue.afterQueued { if model.cursorTask == key { proxy.scrollTo(key) } }
                }
                proxy.scrollTo(key)
                // 「さらにN件」の中のカードは、同じ描画で列が開くので、送る時点ではまだ描かれていない。描かれた後にもう一度送る
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    guard model.cursorTask == key else { return }
                    proxy.scrollTo(key)
                }
            }
            .onChange(of: model.boardFocusRequests) { _, _ in keyboardFocused.wrappedValue = true }
            .onChange(of: model.selectedTask) { old, new in
                // パネルを閉じたらボードでキーを受け直す
                if old != nil, new == nil { keyboardFocused.wrappedValue = true }
            }
    }

    private func stripID(of key: TaskKey) -> String? {
        model.fleet.task(for: key).map { "\($0.machine.rawValue)/\($0.boardID)" }
    }

    /// 横は左端へ戻す（.top だと、帯の幅の真ん中に横が合う）。帯は画面が出た後に 1 つずつ組むので、上の帯が組み上がって
    /// 目標がずれた後にもう一度送る
    private func reveal(_ target: String) {
        proxy.scrollTo(target, anchor: .topLeading)
        MountQueue.afterQueued { proxy.scrollTo(target, anchor: .topLeading) }
    }
}

/// マシンの見出し。押すと畳む。案件を 1 つだけ出しているときは畳めない（`collapsible`）ので、マシンの名前だけを出す
private struct OverviewMachineHeader: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let state: MachineState
    var collapsible = true

    var body: some View {
        let name = model.machineName(fleetID: fleetID, state: state)
        HStack(spacing: Space.block) {
            if collapsible {
                toggle(name: name)
            } else {
                title(name: name)
            }
            MachineUsageBars(state: state, name: name)
        }
    }

    private func title(name: String) -> some View {
        HStack(spacing: Space.row) {
            Text(name).font(.title3.weight(.semibold)).lineLimit(1)
            if !state.connected {
                Text("未接続").textRole(.caption)
            }
        }
    }

    private func toggle(name: String) -> some View {
        let collapsed = model.collapsedMachines.contains(fleetID)
        return Button {
                model.toggleCollapsed(fleetID)
            } label: {
                HStack(spacing: Space.row) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                    title(name: name)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "\(name)を展開" : "\(name)を折りたたむ")
    }
}

/// 1 案件ぶんの帯。見出し（案件名・件数・追加）と、横に並ぶ列。高さは中身で決まる
/// 比べるのは案件とそのタスクだけ（マシンの state を丸ごと持つと、会話やセッションの知らせのたびに帯が描き直される）
private struct BoardStrip: View, @MainActor Equatable {
    @Environment(AppModel.self) private var model
    let board: Board
    let tasks: [BoardTask]

    static func == (lhs: BoardStrip, rhs: BoardStrip) -> Bool {
        lhs.board == rhs.board && lhs.tasks == rhs.tasks
    }

    private var key: String { "\(board.machine.rawValue)/\(board.id)" }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("BoardStrip:\(key)")
        #endif
        let open = board.openTaskCount(tasks)
        VStack(alignment: .leading, spacing: Space.block) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(board.name).textRole(.sectionTitle)
                Text("進行中\(open)件").font(.callout.monospacedDigit()).foregroundStyle(.secondary).layoutPriority(1)
                Button("タスクを追加", systemImage: "plus") { model.newTaskSheet = NewTaskDraft(board: board) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .help("「\(board.name)」にタスクを追加")
            }
            .stickyLeading()
            BoardColumnsRow(
                board: board, tasks: tasks,
                expanded: Binding(get: { model.overviewExpandedColumns[key] ?? [] }, set: { model.overviewExpandedColumns[key] = $0 }),
                limit: BoardMetrics.cardLimit)
        }
    }
}
