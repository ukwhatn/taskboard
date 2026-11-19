import SwiftUI
import TaskboardKit

/// ホーム（「すべての案件」と案件を選んだとき）。上の帯で会話と列を切り替える（⌘B）。iPad は列の形だけ
struct HomeScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        Group {
            switch model.homeLayout {
            case .conversations: ConversationBoard()
            case .columns: OverviewBoard()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { HomeLayoutBar() }
        #else
        OverviewBoard()
        #endif
    }
}

/// ホームの形の切り替えと、組ごとの数
private struct HomeLayoutBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset

    var body: some View {
        let tiles = model.homeTiles
        HStack(spacing: Space.row) {
            HStack(spacing: Space.inline) {
                ForEach(HomeLayout.allCases, id: \.self) { layout in
                    ChipButton(text: layout.label, selected: model.homeLayout == layout) { model.homeLayout = layout }
                        .help(String(localized: "会話と列を切り替える（⌘B）"))
                }
            }
            MetaLine(items: [
                String(localized: "対応待ち\(tiles.waiting.count)"), String(localized: "実行中\(tiles.running.count)"),
                String(localized: "未読\(tiles.unread.count)"), String(localized: "待機\(tiles.idle.count)"),
            ])
            Spacer(minLength: 0)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.row)
        .background(.bar)
    }
}

/// ホームの会話の形。サイドバーで選んだ案件の会話（「すべての案件」なら全部）を、組ごとに並べる
struct ConversationBoard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ConversationBoardSurface(tiles: model.homeTiles, filtered: model.focusedBoard != nil)
    }
}

/// 会話の組（対応待ち・実行中・未読・待機）の面。対応待ちと実行中は札を横に並べ、入りきらなければ実行中を 1 行に送る（`ConversationBoardLayout`）。
/// 札は会話を購読しない（Space で広げたときだけ、その 1 本の最後の発言を取得する）。札と 1 行は値で比べ、ほかの会話が変わっても描き直さない
struct ConversationBoardSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let tiles: ConversationTiles
    /// 案件を選んで絞っている（空のときの文を分ける）
    let filtered: Bool

    /// 面の大きさ。列の数と、実行中を札にするかを決める
    @State private var viewport: CGSize = .zero
    /// ↑↓←→ / hjkl / ↩ / Space / ⌘Y（権限の許可）/ Esc を受ける。端末やチャットの入力にフォーカスがある間は、そちらがキーを取る
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        let width = max(0, viewport.width - inset * 2)
        let columns = AppModel.tileColumns(width: width)
        let layout = AppModel.conversationBoardLayout(tiles, viewport: CGSize(width: width, height: viewport.height))
        let empty = tiles.waiting.isEmpty && tiles.running.isEmpty && tiles.unread.isEmpty && tiles.idle.isEmpty
        ScrollViewReader { proxy in
            ScrollView {
                if empty {
                    EmptyState(filtered ? String(localized: "この案件の会話はありません") : String(localized: "会話はありません"), symbol: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.section)
                } else {
                    VStack(alignment: .leading, spacing: Space.section) {
                        if !layout.waiting.isEmpty {
                            section(String(localized: "対応待ち"), count: layout.waiting.count) { grid(layout.waiting, columns: columns) }
                        }
                        if !tiles.running.isEmpty {
                            section(String(localized: "実行中"), count: tiles.running.count) { running(layout.running, columns: columns) }
                        }
                        if !layout.unread.isEmpty {
                            section(String(localized: "未読"), count: layout.unread.count) { lines(layout.unread, kind: .unread) }
                        }
                        if !layout.idle.isEmpty { idle(layout.idle) }
                    }
                    // 札の幅は面の幅から決めるので、中身の幅で面を縮めない
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.vertical, Space.block)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewport = size
                model.tileViewport = CGSize(width: max(0, size.width - inset * 2), height: size.height)
            }
            .background { ConversationBoardScroller(proxy: proxy, keyboardFocused: $keyboardFocused) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .escape]) { press in handle(press) }
        .onKeyPress(characters: CharacterSet(charactersIn: "hjkly"), phases: .down) { press in handle(press) }
        .navigationTitle(model.focusedBoard?.name ?? String(localized: "すべての案件"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("タスクを追加", systemImage: "plus") { model.startNewTask() }
                    .disabled(model.newTaskBoard == nil)
                    .help("タスクを追加（⌘N）")
            }
        }
    }

    // MARK: 組

    private func section(_ title: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                Text(title).textRole(.sectionTitle)
                Text("\(count)件").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// LazyVGrid にしない: 広げた札がメッセージを読み込んで伸びても行の高さを測り直さず、下の節に重なった。並ぶのは対応待ちと、画面に収まると判定した実行中だけなので遅延は要らない
    private func grid(_ list: [ConversationTile], columns: Int) -> some View {
        let count = max(1, columns)
        let width = max(0, (viewport.width - inset * 2 - Space.block * CGFloat(count - 1)) / CGFloat(count))
        let rows = stride(from: 0, to: list.count, by: count).map { Array(list[$0..<min(list.count, $0 + count)]) }
        return VStack(alignment: .leading, spacing: Space.block) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: Space.block) {
                    ForEach(row) { tile in
                        ConversationTileView(tile: tile, detail: detail(tile, links: true)).equatable().frame(width: width).id(tile.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func running(_ running: ConversationBoardLayout.Running, columns: Int) -> some View {
        switch running {
        case .tiles(let list): grid(list, columns: columns)
        case .lines(let list): lines(list, kind: .running)
        case .boards(let groups):
            VStack(alignment: .leading, spacing: Space.block) {
                ForEach(groups, id: \.groupID) { group in
                    let shown = model.runningLines(group, in: tiles)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Text(groupTitle(group)).font(.callout.weight(.semibold))
                            Text("\(group.lines.count + group.hidden)件").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        lines(shown, kind: .running)
                        if group.hidden > 0 {
                            let open = model.expandedRunningGroups.contains(group.groupID)
                            DisclosureButton(
                                title: open ? String(localized: "折りたたむ") : String(localized: "ほか\(group.hidden)件"), expanded: open
                            ) {
                                if open { model.expandedRunningGroups.remove(group.groupID) } else { model.expandedRunningGroups.insert(group.groupID) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 案件の見出し（マシンの名前を添える）。タスクの無い会話の組はマシンの名前だけ
    private func groupTitle(_ group: ConversationBoardLayout.BoardLines) -> String {
        let machine = model.machineName(group.machine)
        guard let board = group.board else { return String(localized: "タスクなし（\(machine)）") }
        return String(localized: "\(board.name)（\(machine)）")
    }

    private func lines(_ list: [ConversationTile], kind: ConversationLineRow.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(list) { tile in
                ConversationLineRow(tile: tile, kind: kind, detail: detail(tile, links: false)).equatable().id(tile.id)
            }
        }
    }

    private func idle(_ list: [ConversationTile]) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            DisclosureButton(title: String(localized: "待機\(list.count)件"), expanded: model.idleTilesExpanded, prominent: true) {
                model.idleTilesExpanded.toggle()
            }
            if model.idleTilesExpanded { lines(list, kind: .idle) }
        }
    }

    private func detail(_ tile: ConversationTile, links: Bool) -> TileDetail {
        let key = tile.id
        return TileDetail(
            machineName: model.machineName(key.machine),
            links: links ? (tile.task.map { task in task.links.compactMap { model.fleet.machineState(for: key.machine)?.links[$0.url] } } ?? []) : [],
            sending: model.tileSending.contains(key), failure: model.tileFailures[key],
            blocked: tile.group == .waiting ? model.writeBlock(key.machine, "送信できません") : nil,
            expansion: model.expandedTile?.key == key ? model.expandedTile : nil)
    }

    // MARK: キー

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = press.modifiers.subtracting([.numericPad, .function])
        // ⌘Y だけは修飾キー付きで受ける（メニューに項目が無く、会話の画面のカードの ⌘Y と同じ働き）
        if modifiers == .command, press.characters == "y" {
            model.confirmCursorTile()
            return .handled
        }
        // ⌥⌘← → などの修飾キー付きはメニューに任せる
        guard modifiers.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: model.moveTileCursor(.up)
        case .downArrow: model.moveTileCursor(.down)
        case .leftArrow: model.moveTileCursor(.left)
        case .rightArrow: model.moveTileCursor(.right)
        case .return: model.openCursorTile()
        case .space: model.toggleTileExpansion()
        case .escape:
            if model.expandedTile != nil {
                model.toggleTileExpansion(model.expandedTile?.key)
            } else if model.selectedTask != nil {
                model.closeTask()
            } else {
                return .ignored
            }
        default:
            switch press.characters {
            case "k": model.moveTileCursor(.up)
            case "j": model.moveTileCursor(.down)
            case "h": model.moveTileCursor(.left)
            case "l": model.moveTileCursor(.right)
            default: return .ignored
            }
        }
        return .handled
    }
}

/// 「ほかN件」「待機N件」の開閉
private struct DisclosureButton: View {
    let title: String
    let expanded: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.inline) {
                Text(title)
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .font(prominent ? .callout : .caption)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hitTarget()
        .accessibilityValue(expanded ? Text("展開済み") : Text("折りたたみ済み"))
    }
}

/// 1 行の会話（実行中が入りきらないとき・未読・待機）。印、題、状態と経過か最後の応答の頭。押すと開き、Space で広げる
struct ConversationLineRow: View, @MainActor Equatable {
    enum Kind: Equatable {
        case running, unread, idle
    }

    @Environment(AppModel.self) private var model
    let tile: ConversationTile
    let kind: Kind
    let detail: TileDetail

    static func == (lhs: ConversationLineRow, rhs: ConversationLineRow) -> Bool {
        lhs.tile == rhs.tile && lhs.kind == rhs.kind && lhs.detail == rhs.detail
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ConversationLineRow")
        #endif
        VStack(alignment: .leading, spacing: Space.inline) {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                StatusGlyph(appearance: .of(tile.sidebarStatus)).accessibilityHidden(true)
                Text(tile.conversation.displayTitle).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                summary.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: Space.row)
                Text(detail.machineName).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let expansion = detail.expansion { TileExpansionView(expansion: expansion) }
        }
        .padding(.horizontal, Space.row)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { TileCursorRing(key: tile.id, cornerRadius: Radius.control) }
        .contentShape(Rectangle())
        .onTapGesture { model.openTile(tile.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openTile(tile.id) }
    }

    @ViewBuilder
    private var summary: some View {
        let reply = tile.conversation.lastReply
        switch kind {
        case .running:
            HStack(spacing: 0) {
                if let since = tile.since { TileElapsed(since: since) }
                if let text = reply?.headline, !text.isEmpty { Text("・\(text)") }
            }
        case .unread:
            LiveClock(every: 60) { now in
                Text(Self.unreadText(reply, now: now))
            }
        case .idle:
            if let text = reply?.headline, !text.isEmpty { Text(text) }
        }
    }

    /// 「未読・12分前に応答を終えました。（最後の応答の頭）」。応答の時刻が分からなければ「未読」
    static func unreadText(_ reply: ConversationReply?, now: Date) -> String {
        guard let reply else { return String(localized: "未読") }
        let headline = reply.headline
        let head = headline.isEmpty ? "" : "　" + headline
        guard now.timeIntervalSince(reply.at) >= 60 else { return String(localized: "未読・応答を終えました") + head }
        return String(localized: "未読・\(RelativeTime.text(reply.at, now: now))に応答を終えました") + head
    }
}

/// キーで選んだ会話へのスクロールと、フォーカスの受け直し。選択を読むのはこの view だけ（面の body で読むと、選ぶたびに全部を組み直す）
private struct ConversationBoardScroller: View {
    @Environment(AppModel.self) private var model
    let proxy: ScrollViewProxy
    var keyboardFocused: FocusState<Bool>.Binding

    var body: some View {
        Color.clear
            .onAppear {
                keyboardFocused.wrappedValue = true
                if let key = model.cursorTile { proxy.scrollTo(key) }
            }
            .onChange(of: model.cursorTile) { _, key in
                guard let key, !model.taskCoversBoard else { return }
                proxy.scrollTo(key)
            }
            .onChange(of: model.boardFocusRequests) { _, _ in keyboardFocused.wrappedValue = true }
            .onChange(of: model.selectedTask) { old, new in
                if old != nil, new == nil { keyboardFocused.wrappedValue = true }
            }
    }
}
