import SwiftUI
import TaskboardKit

/// メッセージの列。ツールの結果は呼び出しの行に入れて、単独では出さない。
/// 下端に追従し、伸びた分を末尾へ送る。人が上へ送ると追従を外し（過去を読んでいる間は引き戻さず、「最新の発言へ」を出す）、下端に戻ると付け直す（`ChatBottomPin`）
struct ChatTranscript: View {
    @Environment(\.pageInset) private var inset
    @Environment(AppModel.self) private var model: AppModel?
    @Environment(\.chatSentImages) private var sentImages
    @Environment(\.today) private var today
    @Environment(\.liveClock) private var liveClock
    let messages: [ChatMessage]
    /// 開いた状態で出す呼び出しとサブエージェントの組（`toolID`）と、taskboard の知らせ（発言の id）。snapshot 用
    var expandedTools: Set<String> = []
    /// 設定の「ツールの実行を初めから畳む」。オフなら全部開いて出す
    @AppStorage(AppPreferences.collapseToolsKey) private var collapseTools = true
    var fontSize = SessionTextSize.chatDefault
    /// 検索の欄が開いている間だけ渡す
    var search: ChatSearch?
    /// `ChatFeed.backlogs`。変わったら末尾へ送る
    var backlogs = 0
    /// ファイルの欄で開いているファイル（`ChatFileRef.id`）
    var openedFile: String?
    /// ファイルの札を押したとき。nil なら札は押せない
    var openFile: ((ChatFileRef) -> Void)?
    /// host の会話の生成中の block と、先に出した発言（終わった発言の後に出す）
    var streaming: [ConversationTimeline.StreamingBlock] = []
    /// 生成中の本文の見せる文。`streaming` の文は読まない
    var reveal: StreamingReveal?
    var outgoing: [ConversationTimeline.Outgoing] = []
    /// host の会話の engine が発言を書かずに続けていること（圧縮中）。生成中の block の後ろに出す
    var activity: ConversationActivity?
    /// 止まりの行の［生成を停止］
    var stopGenerating: (() -> Void)?
    /// 送れなかった発言の［再送信］
    var retry: ((String) -> Void)?
    /// 上端に来たとき（古い方のページを読む）。nil なら読まない
    var reachedTop: (() -> Void)?
    var loadingOlder = false
    /// host の会話の発言のメニュー（フォーク・巻き戻し）と、コードの塊の［実行］
    var messageActions: ChatMessageActions?
    var codeRun: CodeRunActions?
    /// 会話の裏のタスクの様子（ツールの行の印）
    var backgroundTasks = ChatBackgroundTasks(conversation: nil)
    var jump = ChatJumpRequest()
    @State private var pinned = true
    @State private var index = ChatTranscriptIndex()
    /// 一覧を下端へ送る回数（［最新のメッセージへ］と、履歴を読み込んだとき）
    @State private var bottomRequests = 0
    #if os(iOS)
    /// ⌥⌘↑・⌥⌘↓ で前に送った発言。下端に戻ったら外す（送った発言から次を数える）
    @State private var jumpTarget = JumpTarget()
    #endif

    /// 発言ごとのフォークの数を入れた操作の口（フォークの地点を発言の一覧の索引で引く）
    private func counted(_ actions: ChatMessageActions?, _ index: ChatTranscriptIndex) -> ChatMessageActions? {
        guard var actions, !actions.forkPoints.isEmpty else { return actions }
        actions.forkCounts = index.forkAnchors.counts(actions.forkPoints)
        return actions
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ChatTranscript")
        #endif
        let index = index.update(messages, groupsTools: collapseTools)
        let current = search?.currentRow(in: messages)
        let fonts = ChatFonts(size: fontSize)
        let rows = index.rows
        let items = items(rows: rows, fonts: fonts)
        let context = rowContext(index: index, current: current)
        #if os(macOS)
        list(items: items, context: context, rows: rows, fonts: fonts, current: current, index: index)
        #else
        collection(items: items, context: context, rows: rows, fonts: fonts, current: current, index: index)
        #endif
    }

    /// 一覧の並び［上端の読み込み、履歴の行、生成中の block、圧縮中の行、送っている発言］
    private func items(rows: [ChatRows.Row], fonts: ChatFonts) -> [ChatListItem] {
        var items: [ChatListItem] = []
        items.reserveCapacity(1 + rows.count + streaming.count + outgoing.count + 1)
        // 読み込みの行の id に一番上の行を含める（古いページが足されたら、また上端に来たときに読む）
        if reachedTop != nil {
            items.append(ChatListItem(id: "older/" + (rows.first?.id ?? ""), estimate: loadingOlder ? fonts.line : 1, content: .loader(loading: loadingOlder)))
        }
        for row in rows { items.append(ChatListItem(id: row.id, estimate: Self.estimate(row, fonts: fonts), content: .row(row))) }
        // 生成中の本文は、書き終えた塊ごとの行と書きかけの 1 行に並べる（塊の数は段落を書き終えたときだけ替わる）。
        // 書きかけの行の id は書き終えたときになる塊の番号にし、書き終えても同じ行のまま残す
        for block in streaming {
            if block.block == .text, let reveal {
                for index in 0...(reveal.settled[block.id]?.count ?? 0) {
                    items.append(ChatListItem(id: "\(block.id)#\(index)", estimate: fonts.line * 2, content: .streamChunk(blockID: block.id, index: index)))
                }
            } else {
                items.append(ChatListItem(id: block.id, estimate: fonts.line * 3, content: .streamBlock(block)))
            }
        }
        if let activity { items.append(ChatListItem(id: "activity", estimate: fonts.line, content: .activity(activity, stops: stopGenerating != nil))) }
        for message in outgoing {
            items.append(ChatListItem(id: message.id, estimate: Self.estimate(text: message.text, fonts: fonts) + Space.block, content: .outgoing(message)))
        }
        return items
    }

    /// 行を組むのに使う、会話の全体から引いたものと画面の設定と操作の口
    private func rowContext(index: ChatTranscriptIndex, current: String?) -> ChatRowContext {
        let model = model
        let messageActions = counted(messageActions, index)
        return ChatRowContext(
            look: ChatRowContext.Look(
                fontSize: fontSize, query: search?.activeQuery, current: current, expandedTools: expandedTools, collapseTools: collapseTools,
                openedFile: openedFile, opensFiles: openFile != nil, hasActions: messageActions != nil, rewinds: messageActions?.rewind != nil,
                revealed: messageActions?.revealed, forkCounts: messageActions?.forkCounts ?? [:], runsCode: codeRun != nil, showsImages: sentImages != nil,
                // today は時計を止めたとき（snapshot）だけ渡す。環境に入れていない `today` は読むたびに今の時刻になり、
                // 上の画面の環境が変わるたびに見た目が違うと見なされて、置いている行を全部組み直していた
                retries: retry != nil, live: liveClock, today: liveClock ? .distantPast : today),
            results: index.results, subagents: index.subagents, rewindRange: index.rewindRange, backgroundTasks: backgroundTasks, openFile: openFile,
            messageActions: messageActions, codeRun: codeRun,
            reveal: reveal, stopGenerating: stopGenerating, retry: retry, images: sentImages,
            openLink: { url in
                switch LinkDestination(url) {
                case .browser: ExternalLinks.open(url)
                case .app: model?.open(url, from: .link)
                case .ignore: break
                }
            })
    }

    #if os(macOS)
    /// Mac は自前の一覧（`ChatList`）
    private func list(items: [ChatListItem], context: ChatRowContext, rows: [ChatRows.Row], fonts: ChatFonts, current: String?, index: ChatTranscriptIndex) -> some View {
        let target = current.flatMap { id in
            index.row(containing: id).map { ChatList.Target(id: rows[$0].id, alignTop: rows[$0].id != id, token: id) }
        }
        return ChatList(
            items: items, context: context,
            spacing: fonts.itemGap, verticalInset: Space.block, horizontalInset: inset, columnWidth: ReadableWidth.chat,
            pinned: $pinned, bottomRequest: bottomRequests, target: target, jump: jump, reachedTop: reachedTop
        )
        .background(ChatPalette.surface)
        // 会話をまとめて受けたら下端へ送る（検索で前の発言を見ている間は送らない）
        .onChange(of: backlogs) { _, _ in
            if current == nil { bottomRequests += 1 }
        }
        .overlay(alignment: .bottomTrailing) {
            if !pinned && current == nil {
                Button("最新のメッセージへ", systemImage: "arrow.down.to.line") {
                    pinned = true
                    bottomRequests += 1
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(Space.block)
            }
        }
    }
    #endif

    /// 測るまでの行の高さ。畳んだツールの行は 1 行、文は UTF-8 の長さから行数を見積もる（字数を数えると、長い会話で本体のたびに全文をなめる）
    private static func estimate(_ row: ChatRows.Row, fonts: ChatFonts) -> CGFloat {
        switch row {
        case .tools: return fonts.line
        case .message(let message):
            switch message.kind {
            case .text where message.isThinking: return fonts.line
            case .text: return estimate(text: message.text, fonts: fonts) + (message.role == .user ? Space.block : 0)
            default: return fonts.line
            }
        }
    }

    private static func estimate(text: String, fonts: ChatFonts) -> CGFloat {
        // 日本語は 1 字 3 バイトで、1 行に列の幅 ÷ 文字の大きさの字が入る。英語の多い文は少なめに見積もることになる
        let perLine = max(ReadableWidth.chat / CGFloat(fonts.size) * 3, 1)
        return (CGFloat(text.utf8.count) / perLine).rounded(.up) * fonts.line
    }

    #if os(iOS)
    /// iPhone・iPad は UIKit の一覧（`ChatCollection`）
    private func collection(items: [ChatListItem], context: ChatRowContext, rows: [ChatRows.Row], fonts: ChatFonts, current: String?, index: ChatTranscriptIndex) -> some View {
        let target = current.flatMap { id in index.row(containing: id).map { ChatCollection.Target(id: rows[$0].id, alignTop: rows[$0].id != id) } }
        let model = model
        return FillContainer {
            ChatCollection(
                items: items, context: context, spacing: fonts.itemGap, columnWidth: ReadableWidth.chat, verticalInset: Space.block, horizontalInset: inset,
                pinned: $pinned, bottomRequest: bottomRequests, target: target, jumpTarget: (jumpTarget.token, jumpTarget.id), reachedTop: reachedTop,
                followLimited: { model?.eventLog.record(AppEvent(at: Date(), type: "chat.follow_limit", id: UUID().uuidString)) })
            .ignoresSafeArea(.container, edges: .bottom)
        }
        // 会話をまとめて受けたら下端へ送る（検索で前の発言を見ている間は送らない）
        .onChange(of: backlogs) { _, _ in
            if current == nil { bottomRequests += 1 }
        }
        .onChange(of: jump.token) { _, _ in
            let id = ChatRows.promptStep(rows, forward: jump.forward, from: jumpTarget.id)
            jumpTarget = JumpTarget(token: jumpTarget.token + 1, id: id)
        }
        .onChange(of: pinned) { _, pinned in
            if pinned { jumpTarget.id = nil }
        }
        .overlay(alignment: .bottomTrailing) {
            // 初めから置いて濃さで出し入れする（追従が外れたときに初めて作ると、上へ送り始めた所で主スレッドを 15ms ほど止めた）
            let shows = !pinned && current == nil
            Button("最新のメッセージへ", systemImage: "arrow.down.to.line") {
                pinned = true
                bottomRequests += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(Space.block)
            .opacity(shows ? 1 : 0)
            .allowsHitTesting(shows)
            .accessibilityHidden(!shows)
        }
    }
    #endif
}

/// 発言の全体から引く行・ツールの結果・サブエージェントの発言。発言が変わらない間（生成中の差分だけが届く間）は組み直さない
/// （差分のたびに組み直すと、長い会話で描き直しが詰まり、スクロールが止まった）
final class ChatTranscriptIndex {
    private var source: [ChatMessage]?
    private var groupsTools = true
    private(set) var rows: [ChatRows.Row] = []
    private(set) var results: [String: ChatMessage] = [:]
    private(set) var subagents: [String: [ChatMessage]] = [:]
    private(set) var rewindRange = ChatRewindRange([])
    private(set) var forkAnchors = ChatForkAnchors([])
    /// 組み直すたびに上がる
    private(set) var version = 0
    /// 行の id と、行に出る発言の id → 行の位置
    private var positions: [String: Int] = [:]

    func update(_ messages: [ChatMessage], groupsTools: Bool) -> ChatTranscriptIndex {
        guard source != messages || self.groupsTools != groupsTools else { return self }
        source = messages
        self.groupsTools = groupsTools
        version += 1
        rows = ChatRows.rows(messages, groupsTools: groupsTools)
        results = Dictionary(messages.filter { $0.kind == .toolResult && $0.toolID != nil }.map { ($0.toolID!, $0) }, uniquingKeysWith: { $1 })
        subagents = ChatRows.subagents(messages)
        rewindRange = ChatRewindRange(messages)
        forkAnchors = ChatForkAnchors(messages)
        positions = [:]
        for (position, row) in rows.enumerated() {
            positions[row.id] = position
            if case .tools(let members) = row {
                for member in members { positions[member.id] = position }
            }
        }
        return self
    }

    /// 行の位置。行の id か、行に出る発言の id（組の中の発言なら組の行）で引く
    func row(containing id: String) -> Int? {
        positions[id]
    }
}

#if os(iOS)
/// ⌥⌘↑・⌥⌘↓ で送る先。`token` が替わったときに送り、`id` が nil なら下端へ
private struct JumpTarget {
    var token = 0
    var id: String?
}
#endif

/// チャットの下端への追従の判定。人が上へ送った（表示の位置が上がり、下端から離れた）ら、下端の近くでも外す。付け直すのは人が下端まで送ったときだけ。
/// 下端からの距離だけで決めると、ツールの行がまとめて届いて中身が一度に伸びたとき、末尾へ送る前に「離れた」と判定して外れていた。
/// 下端から 120 の内を下端とみなしていたときは、細かい送り（トラックパッド）が追従を外せず、毎回下端へ引き戻されていた。
/// 人が送ったかは位置の動きから推さない（行の高さの見積もりが直ったときや、まとめて届いた後に SwiftUI が位置を当て直したときも上がる）
/// 短い会話を下に寄せる、UIKit の一覧の上の余白。余白を書くと表示の位置が動き、その位置に連れて一覧の高さが変わると（ナビゲーションバー・タブバーの伸び縮み）、
/// 計算し直した余白が前の値に戻って往復し続ける（2 つの値を 1 秒に約 900 回行き来して、主スレッドが CPU 99% のまま戻らなかった）。
/// 同じ中身の高さと幅で A → B → A と戻ったら、大きい方（中身が隠れない方）で `hold` 秒止める
struct ChatTopPad {
    static let hold: TimeInterval = 1
    private var written: [CGFloat] = []
    private var shape: CGSize?
    private var heldUntil: TimeInterval = 0

    /// 書く余白。今の余白のままでよければ nil
    mutating func next(free: CGFloat, current: CGFloat, contentHeight: CGFloat, width: CGFloat, now: TimeInterval) -> CGFloat? {
        let extra = max(0, free.rounded(.down))
        let size = CGSize(width: width, height: contentHeight)
        if shape != size {
            shape = size
            written = []
            heldUntil = 0
        }
        guard now >= heldUntil else { return nil }
        guard abs(current - extra) > 0.5 else { return nil }
        if written.count == 2, abs(written[0] - extra) <= 0.5 {
            heldUntil = now + Self.hold
            written = []
            let settled = max(extra, current)
            return abs(current - settled) > 0.5 ? settled : nil
        }
        written = Array((written + [extra]).suffix(2))
        return extra
    }
}

enum ChatBottomPin {
    /// 人が送ってここまで下端に近づいたら付け直す。`scrollTo(edge: .bottom)` は下の余白（contentMargins）の分だけ手前で止まるので、余白の分を含める
    static let reattach: CGFloat = Space.block

    struct Position: Equatable {
        var offset: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat

        /// 下端までの距離
        var gap: CGFloat { contentHeight - viewportHeight - offset }
    }

    /// UIKit の一覧の下端の `contentOffset.y`。中身が見えている所より短ければ上端
    static func bottomOffset(contentHeight: CGFloat, boundsHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) -> CGFloat {
        max(-insetTop, contentHeight + insetBottom - boundsHeight)
    }

    /// 下端に揃っている（`margin` まではゆとりにする）
    static func isAtBottom(_ position: Position, margin: CGFloat) -> Bool {
        position.gap <= margin + 1
    }

    /// `byUser` は人がスクロールしている間（phase が tracking・interacting・decelerating か、ホイールを回した直後）。
    /// 人が動かしていない位置の変化（中身が伸び縮みした・見積もりが直った・位置を当て直した）では、付け外しを変えない
    static func pinned(_ pinned: Bool, from old: Position, to new: Position, byUser: Bool) -> Bool {
        guard byUser else { return pinned }
        // 下端で中身が縮んで位置が下がっただけのとき（下端からは離れていない）は外さない
        if new.offset < old.offset - 1, new.gap > old.gap + 1 { return false }
        return pinned || isAtBottom(new, margin: reattach)
    }
}

/// 前・次の人の発言へ送る要求（⌥⌘↑・⌥⌘↓）。`token` が替わったときだけ送る
struct ChatJumpRequest: Equatable {
    var forward = false
    var token = 0
}

extension ChatBottomPin.Position {
    /// UIKit の一覧の位置（`contentOffset.y`・`adjustedContentInset`）。見えている所は上下の inset を除いた分にする
    init(scrollOffset: CGFloat, contentHeight: CGFloat, boundsHeight: CGFloat, insetTop: CGFloat, insetBottom: CGFloat) {
        self.init(offset: scrollOffset + insetTop, contentHeight: contentHeight, viewportHeight: boundsHeight - insetTop - insetBottom)
    }
}
