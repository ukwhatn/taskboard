import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import TaskboardKit

/// 会話の一覧の 1 行の中身（Mac の `ChatList.Item`、iPhone・iPad の `ChatCollection.Item`）。前と同じなら行を組み直さない
enum ChatRowContent: Equatable {
    /// 上端の読み込み
    case loader(loading: Bool)
    case row(ChatRows.Row)
    /// 生成中の本文の塊。`index` が書き終えた塊の数と同じなら書きかけ
    case streamChunk(blockID: String, index: Int)
    case streamBlock(ConversationTimeline.StreamingBlock)
    /// 生成中・状態の行。`stops` は止めるボタンを出すか
    case activity(ConversationActivity, stops: Bool)
    case outgoing(ConversationTimeline.Outgoing)
}

/// 会話の一覧の 1 行
struct ChatListItem: Equatable {
    let id: String
    /// 測るまでの高さ
    let estimate: CGFloat
    let content: ChatRowContent
}

/// 行が会話の全体から引くもの（行と入れ子の呼び出しの結果、サブエージェントの発言）。これが変わった行だけ組み直す
/// （会話に発言が 1 つ足されるたびに置いている全部のツールの行を組み直すと、生成が終わって返答が届いたときに 100 ms を超えた）
struct ChatRowInputs: Equatable {
    var results: [ChatMessage?] = []
    var children: [[ChatMessage]] = []
    /// 結果が裏のタスクの呼び出しの、今の様子
    var background: [ConversationBackgroundTaskState.Status?] = []
    /// 最後に圧縮した会話の、それより前の人の発言（巻き戻しを出さない）
    var readOnly = false
}

/// 行を組むのに使う、会話の全体から引いたものと画面の設定と操作の口
@MainActor
struct ChatRowContext {
    /// 行の見た目に効く値。変わったら置いている行を組み直す。行の見た目に効く値を足すときはここに足す（閉じは比べられないので、有無だけを入れる）
    struct Look: Equatable {
        var fontSize: Double
        var query: String?
        /// 検索で今見ている行の id
        var current: String?
        var expandedTools: Set<String>
        var collapseTools: Bool
        var openedFile: String?
        var opensFiles = false
        var hasActions = false
        var rewinds = false
        /// 操作の帯を、ホバーしていなくても出す発言（snapshot 用）
        var revealed: String?
        /// 発言の id → そこから分けたフォークの数（`ChatMessageActions.forkCounts`）
        var forkCounts: [String: Int] = [:]
        var runsCode = false
        var showsImages = false
        var retries = false
        /// 経過の時間を 1 秒ごとに進める。false なら `today` で描く（snapshot）
        var live = true
        var today = Date.distantPast
    }

    var look: Look
    var results: [String: ChatMessage] = [:]
    /// Agent の呼び出しの `toolID` → サブエージェントの発言
    var subagents: [String: [ChatMessage]] = [:]
    var rewindRange = ChatRewindRange([])
    var backgroundTasks = ChatBackgroundTasks(conversation: nil)
    var openFile: ((ChatFileRef) -> Void)?
    var messageActions: ChatMessageActions?
    var codeRun: CodeRunActions?
    /// 生成中の本文の見せる文
    var reveal: StreamingReveal?
    var stopGenerating: (() -> Void)?
    var retry: ((String) -> Void)?
    var images: ChatSentImageAccess?
    var openLink: (URL) -> Void = { _ in }

    var fonts: ChatFonts { ChatFonts(size: look.fontSize) }

    func inputs(for content: ChatRowContent) -> ChatRowInputs {
        guard case .row(let row) = content else { return ChatRowInputs() }
        var inputs = ChatRowInputs()
        var queue: [ChatMessage]
        switch row {
        case .message(let message):
            queue = [message]
            inputs.readOnly = rewindRange.readOnly.contains(message.id)
        case .tools(let members): queue = members
        }
        var visited = 0
        while let message = queue.popLast(), visited < 10_000 {
            visited += 1
            guard message.kind == .toolUse, let toolID = message.toolID else { continue }
            inputs.results.append(results[toolID])
            if let task = results[toolID]?.backgroundTaskID { inputs.background.append(backgroundTasks.status(of: task)) }
            if let children = subagents[toolID], !children.isEmpty {
                inputs.children.append(children)
                queue += children
            }
        }
        return inputs
    }

    static let empty = ChatRowContext(look: Look(fontSize: SessionTextSize.chatDefault, expandedTools: [], collapseTools: true))
}

/// 一覧が持ち、行を外して置き直しても残すもの
@MainActor
final class ChatRowState {
    /// 行の中で押して開閉した状態（行の id ごと）
    var open: [String: Bool] = [:]
    /// 押して開閉したばかりの見出しの鍵（組み直した見出しの印を前の向きから回す。1 回組んだら外す）
    var turning: String?
    /// 今の発言の操作。帯とメニューは押したときにこれを読む
    private(set) var actions: ChatMessageActions?
    private var rewindButtons: [WeakButton] = []

    /// 巻き戻せない理由は応答が始まるたびと終わるたびに替わる。置いている行を全部組み直さず、巻き戻しのボタンだけを直す
    /// （組み直すと、表を含む行が置いてあるときに 1 回で 100 ms を超えた）
    func setActions(_ actions: ChatMessageActions?) {
        let changed = actions?.rewindBlocked != self.actions?.rewindBlocked
        self.actions = actions
        guard changed else { return }
        rewindButtons.removeAll { $0.button == nil }
        for entry in rewindButtons { if let button = entry.button { applyRewind(button) } }
    }

    func attachRewind(_ button: ChatIconButtonView) {
        rewindButtons.removeAll { $0.button == nil }
        rewindButtons.append(WeakButton(button: button))
        applyRewind(button)
    }

    private func applyRewind(_ button: ChatIconButtonView) {
        let blocked = actions?.rewindBlocked
        button.setHelp(blocked)
        button.isEnabled = blocked == nil
    }

    private struct WeakButton {
        weak var button: ChatIconButtonView?
    }
}

/// 組んだ行のうち、一覧が使う部品
@MainActor
final class ChatRowMarks {
    /// 検索で今見ている発言（一覧が枠を描く）
    weak var focus: PlatformView?
}

/// 行の下の端から、次の行との間へはみ出して描く分（発言の操作の帯）
@MainActor
protocol ChatOverflowing: AnyObject {
    var overflow: CGFloat { get }
}

/// `ChatRowContent` を行の部品（AppKit・UIKit）に組む。Mac の一覧（`ChatList`）と iPhone・iPad の一覧（`ChatCollection`）で同じものを使う
@MainActor
struct ChatRowFactory {
    let context: ChatRowContext
    let state: ChatRowState
    let marks: ChatRowMarks
    /// 行の中で開閉したとき（行を組み直して測り直す）
    let relayout: () -> Void

    private var fonts: ChatFonts { context.fonts }
    private var look: ChatRowContext.Look { context.look }
    private var query: String? { look.query }
    private var current: String? { look.current }
    private var indent: CGFloat { ChatChevron.indent(fonts: fonts) }

    func make(_ content: ChatRowContent) -> ChatPart {
        switch content {
        case .loader(let loading):
            return loading ? ChatAlignView(ChatSpinnerView(), alignment: .center) : ChatSpacerView(height: 1)
        case .row(let row):
            return rowView(row, inSubagent: false)
        case .streamChunk(let blockID, let index):
            let settled = context.reveal?.settled[blockID] ?? []
            // 書きかけ（`tails`）を読むのは書きかけの行だけ。書き終えた塊の行は段落を書き終えたときだけ組み直す
            let blocks = index < settled.count ? MarkdownBlocks.cached(settled[index]) : MarkdownBlocks.parse(context.reveal?.tails[blockID] ?? "")
            return assistantBody(blocks, codeRun: nil)
        case .streamBlock(let block):
            return streamBlock(block)
        case .activity(let activity, let stops):
            return indented(ChatActivityRowView(activity: activity, fonts: fonts, stop: stops ? context.stopGenerating : nil, live: look.live, today: look.today))
        case .outgoing(let message):
            return outgoing(message)
        }
    }

    // MARK: 行

    /// 1 行（発言か組）。サブエージェントの中の行も同じ形で組む
    private func rowView(_ row: ChatRows.Row, inSubagent: Bool) -> ChatPart {
        switch row {
        case .message(let message): messageRow(message, inSubagent: inSubagent)
        case .tools(let members): toolRun(members, inSubagent: inSubagent)
        }
    }

    /// 発言 1 件（組の中の行も同じ）。検索で今見ている行の枠と、発言のメニューを付ける（サブエージェントの中の発言には付けない）。
    /// Agent の呼び出しの下には、サブエージェントの発言とツールを畳んで出す
    private func messageRow(_ message: ChatMessage, inSubagent: Bool) -> ChatPart {
        let body: ChatPart
        switch ChatRows.shape(of: message) {
        case .toolCall:
            let result = message.toolID.flatMap { context.results[$0] }
            let children = message.toolID.flatMap { context.subagents[$0] } ?? []
            let call = toolCall(message, result: result)
            if let parent = message.toolID, !children.isEmpty {
                // 検索は一致を本筋の呼び出しの行で数えるので、入れ子の組は中に一致があれば開く
                let revealed = (current == message.id || inSubagent && current != nil)
                    && ChatSearch.matchesInside(ChatRows.descendants(of: parent, in: context.subagents), query: query)
                body = ChatStackView([call, subagent(parent: parent, members: children, revealed: revealed)], spacing: Space.inline)
            } else {
                body = call
            }
        case .thinking: body = thinking(message)
        case .notice(let notice): body = self.notice(message, notice)
        case .injected: body = injected(message)
        case .plain: body = messageBody(message)
        }
        if current == message.id { marks.focus = body }
        let actions = inSubagent ? nil : context.messageActions
        if message.kind == .text, !message.isInjected, !message.isThinking {
            return ChatMessageContainerView(
                content: body, bar: { actionBar(message, actions: actions) }, trailing: message.role == .user,
                revealed: actions?.revealed == message.id || actions?.forkCounts[message.id] != nil, menu: { menu(message, withActions: actions != nil) })
        }
        if let actions, message.isForkTarget || (context.rewindRange.allows(message) && actions.rewind != nil) {
            return ChatMenuView(content: body) { menu(message, withActions: true) }
        }
        return body
    }

    /// 人の発言の吹き出し・アシスタントの本文・知らせの 1 行
    private func messageBody(_ message: ChatMessage) -> ChatPart {
        switch (message.role, message.kind) {
        case (_, .notice):
            let text = ChatAttributed.plain(message.text, font: fonts.platformCaption, color: ChatPalette.Platform.mutedText, line: nil, query: query)
            ChatAttributed.setParagraph(text, ChatAttributed.paragraph(line: nil, alignment: .center))
            if message.isCompactSummary { return ChatPaddingView(ChatDividerView(label: ChatTextBlock(text, hugs: true)), horizontal: 0, vertical: Space.inline) }
            return ChatPaddingView(ChatTextBlock(text), horizontal: 0, vertical: Space.inline)
        case (.user, _):
            // 画像でない添付は、本文の頭の一覧（`MentionedFiles`）を外してファイルの札にする。画像は縮小版を頭に並べる（押すと大きく開く）
            let split = MentionedFiles.split(message.text)
            let text = split?.text ?? message.text
            var inner: [ChatPart] = []
            if let images = message.images, !images.isEmpty {
                inner.append(ChatFlowView(
                    items: images.map { ChatThumbnailView(ref: ChatSentImageRef(lineID: message.lineID, image: $0), access: context.images, fonts: fonts) },
                    spacing: Space.row, lineSpacing: Space.row))
            }
            if !text.isEmpty || split != nil {
                let paths = split?.paths ?? []
                var group: [ChatPart] = paths.map { ChatAttachedFileChipView(name: ($0 as NSString).lastPathComponent, path: $0, fonts: fonts) }
                if !text.isEmpty { group.append(bubbleText(text, query: query)) }
                let stack = ChatStackView(group, spacing: Space.inline)
                stack.hugs = true
                stack.accessibilityGroupLabel = String(localized: "メッセージ：\(([text] + paths.map { ($0 as NSString).lastPathComponent }).filter { !$0.isEmpty }.joined(separator: "、"))")
                inner.append(stack)
            }
            let content = ChatStackView(inner, spacing: Space.inline)
            content.hugs = true
            return ChatBubbleView(content: content, fonts: fonts)
        case (.assistant, _):
            let chunks = ChatMarkdownChunks.cached(id: message.id, text: message.text, streaming: false)
            let body = assistantBody(chunks.settled.flatMap { MarkdownBlocks.cached($0) }, codeRun: context.codeRun.map { ChatCodeRun(actions: $0, messageID: message.id) })
            guard message.isError else { return body }
            // API の誤りで終わった返事。CLI の英語の文は理由ごとに違うので、そのまま添える
            let heading = ChatIconLabelView(
                String(localized: "応答を取得できませんでした"), symbol: "exclamationmark.circle.fill", font: fonts.platformSubheadline, color: ChatPalette.Platform.dangerText)
            return ChatStackView([ChatStackView([heading], indent: ChatMetrics.assistantInset), body], spacing: Space.inline)
        }
    }

    /// アシスタントの本文。吹き出しの無い分だけ下げる
    private func assistantBody(_ blocks: [MarkdownBlock], codeRun: ChatCodeRun?) -> ChatPart {
        let look = ChatMarkdownLook(fonts: fonts, query: query, openLink: context.openLink, codeRun: codeRun)
        return ChatStackView([ChatMarkdownView(blocks: blocks, look: look)], indent: ChatMetrics.assistantInset)
    }

    private func bubbleText(_ text: String, query: String?, opacity: CGFloat = 1) -> ChatTextBlock {
        let color = ChatPalette.Platform.text.fading(opacity)
        let block = ChatTextBlock(ChatAttributed.plain(text, font: fonts.platformBody, color: color, line: fonts.line, query: query), hugs: true)
        block.text.openLink = context.openLink
        return block
    }

    // MARK: ツール

    /// ツールの呼び出し 1 件。設定に従って畳み、開くと結果（4KB まで）。押して開閉した行だけ、設定より押した状態を優先する
    private func toolCall(_ call: ChatMessage, result: ChatMessage?) -> ChatPart {
        let key = "tool:" + call.id
        let expandedByDefault = !look.collapseTools || (call.toolID.map(look.expandedTools.contains) ?? false)
        let revealed = current == call.id && ChatSearch.matchesInside(call: call, result: result, query: query)
        let open = (state.open[key] ?? expandedByDefault) || revealed
        let status = ToolStatusAppearance(ChatToolStatus(result: result, background: context.backgroundTasks))
        var parts: [ChatHeaderPart] = [
            statusPart(status),
            .text(ChatAttributed.label(call.toolName ?? String(localized: "ツール"), font: fonts.platformSubheadlineMedium, query: query), tint: .header, flexible: false, truncation: .byTruncatingTail),
        ]
        if let tag = status.tag {
            parts.append(.text(ChatAttributed.label(tag, font: fonts.platformCaption, query: nil), tint: .fixed(ChatPalette.Platform.secondaryText), flexible: false, truncation: .byTruncatingTail))
        }
        parts.append(.text(ChatAttributed.label(call.text, font: fonts.platformSubheadlineCode, query: query), tint: .muted, flexible: true, truncation: .byTruncatingMiddle))
        var items: [ChatPart] = [ChatDisclosureHeaderView(open: open, fonts: fonts, parts: parts, turning: turns(key), toggle: toggle(key, open))]
        let files = ChatFileRef.refs(call: call, result: result)
        if !files.isEmpty { items.append(indented(fileChips(files))) }
        if let result, let document = DocumentToolRef.parse(toolName: call.toolName, result: result.text) { items.append(indented(documentLink(document))) }
        if open {
            var rows: [ChatPart] = [codeText(call.text, color: ChatPalette.Platform.label)]
            if let result {
                var lines: [ChatPart] = [
                    codeText(
                        result.text.isEmpty ? String(localized: "（出力はありません）") : result.text, color: result.isError ? ChatPalette.Platform.dangerText : ChatPalette.Platform.text,
                        highlights: !result.text.isEmpty),
                ]
                if let full = result.fullBytes {
                    lines.append(cardText(
                        String(localized: "先頭の4KBだけを表示しています（全体は\(ByteCountFormatter.string(fromByteCount: Int64(full), countStyle: .file))）"),
                        font: fonts.platformCaption2, color: ChatPalette.Platform.mutedText))
                }
                rows.append(ChatStackView(lines, spacing: Space.inline))
            } else {
                rows.append(cardText(String(localized: "実行中"), font: fonts.platformCaption, color: ChatPalette.Platform.secondaryText))
            }
            items.append(indented(ChatOutlineCardView(rows: rows)))
        }
        return ChatStackView(items, spacing: Space.inline)
    }

    /// 様子の印。回る印は窓に置かれている間だけ回る（`ChatList` は見えている行しか置かない）
    private func statusPart(_ status: ToolStatusAppearance) -> ChatHeaderPart {
        let size = fonts.platformCaption.pointSize
        guard let symbol = status.symbol else { return .spinner(size: size, label: status.label) }
        return .symbol(symbol, size: size, tint: .fixed(status.platformColor), label: status.label)
    }

    /// 続いたツールの呼び出しと差し込んだ文の組。初めは畳み、題に回数と最後の呼び出しを出す。開くと 1 件ずつの行を並べる
    private func toolRun(_ members: [ChatMessage], inSubagent: Bool) -> ChatPart {
        let key = "run:" + (members.first?.id ?? "")
        let calls = members.filter { $0.kind == .toolUse }
        let status = ChatToolStatus.summary(calls.map { call in ChatToolStatus(result: call.toolID.flatMap { context.results[$0] }, background: context.backgroundTasks) })
        let expandedByDefault = members.contains { $0.toolID.map(look.expandedTools.contains) ?? false }
        let revealed = current.map { id in members.contains { $0.id == id } } ?? false
        let open = (state.open[key] ?? expandedByDefault) || revealed
        let title = ChatRowTitle.toolRun(calls: calls.count, injected: members.filter(\.isInjected).count)
        var parts: [ChatHeaderPart] = [
            .symbol("square.stack.3d.up", size: fonts.platformCaption.pointSize, tint: .header, label: nil),
            .text(ChatAttributed.label(title, font: fonts.platformSubheadlineMedium, query: nil), tint: .header, flexible: false, truncation: .byTruncatingTail),
        ]
        if let last = calls.last {
            parts.append(.text(ChatAttributed.label(last.toolName ?? String(localized: "ツール"), font: fonts.platformSubheadline, query: nil), tint: .muted, flexible: true, truncation: .byTruncatingTail))
        }
        if let status { parts.append(statusPart(ToolStatusAppearance(status))) }
        var items: [ChatPart] = [ChatDisclosureHeaderView(open: open, fonts: fonts, parts: parts, turning: turns(key), toggle: toggle(key, open))]
        if open {
            items.append(ChatStackView(members.map { messageRow($0, inSubagent: inSubagent) }, spacing: Space.row, indent: indent))
        } else {
            // 畳んでいる間に出すファイルの札（組の中の呼び出しが読んだ・書いたもの。同じファイルは 1 枚）
            var seen: Set<String> = []
            let files = calls.flatMap { call in ChatFileRef.refs(call: call, result: call.toolID.flatMap { context.results[$0] }) }.filter { seen.insert($0.id).inserted }
            if !files.isEmpty { items.append(indented(fileChips(files))) }
        }
        return ChatStackView(items, spacing: Space.inline)
    }

    /// Agent の呼び出しが起こしたサブエージェントの発言とツール。初めは畳み、題に件数と最後の呼び出しの名前と様子を出す。
    /// 開くと本筋と同じ形の行を並べる（続いたツールは組にし、入れ子のサブエージェントはその呼び出しの下に畳む）
    private func subagent(parent: String, members: [ChatMessage], revealed: Bool) -> ChatPart {
        let key = "sub:" + parent
        let open = (state.open[key] ?? look.expandedTools.contains(parent)) || revealed
        let count = ChatRows.rows(members, groupsTools: false, parent: parent).count
        let last = members.last { $0.kind == .toolUse && $0.parentToolID == parent }
        var parts: [ChatHeaderPart] = [
            .symbol("arrow.triangle.branch", size: fonts.platformCaption.pointSize, tint: .header, label: nil),
            .text(ChatAttributed.label(ChatRowTitle.subagent(count: count), font: fonts.platformSubheadlineMedium, query: nil), tint: .header, flexible: false, truncation: .byTruncatingTail),
        ]
        if let last {
            parts.append(.text(ChatAttributed.label(last.toolName ?? String(localized: "ツール"), font: fonts.platformSubheadline, query: nil), tint: .muted, flexible: true, truncation: .byTruncatingTail))
            if let status = ChatToolStatus.summary([ChatToolStatus(result: last.toolID.flatMap { context.results[$0] }, background: context.backgroundTasks)]) {
                parts.append(statusPart(ToolStatusAppearance(status)))
            }
        }
        var items: [ChatPart] = [ChatDisclosureHeaderView(open: open, fonts: fonts, parts: parts, turning: turns(key), toggle: toggle(key, open))]
        if open {
            let rows = ChatRows.rows(members, groupsTools: look.collapseTools, parent: parent).map { rowView($0, inSubagent: true) }
            items.append(ChatStackView(rows, spacing: Space.row, indent: indent))
        }
        return ChatStackView(items, spacing: Space.inline, indent: indent)
    }

    /// Claude Code が人の側に差し込んだ文。人の発言と分け、初めは畳んで 1 行目だけ出す
    private func injected(_ message: ChatMessage) -> ChatPart {
        let key = "injected:" + message.id
        let open = (state.open[key] ?? !look.collapseTools) || current == message.id
        let firstLine = message.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts: [ChatHeaderPart] = [
            .symbol("text.badge.plus", size: fonts.platformCaption.pointSize, tint: .header, label: nil),
            .text(ChatAttributed.label(ChatRowTitle.injected, font: fonts.platformSubheadlineMedium, query: nil), tint: .header, flexible: false, truncation: .byTruncatingTail),
            .text(ChatAttributed.label(firstLine, font: fonts.platformSubheadline, query: query), tint: .muted, flexible: true, truncation: .byTruncatingTail),
        ]
        var items: [ChatPart] = [ChatDisclosureHeaderView(open: open, fonts: fonts, parts: parts, turning: turns(key), toggle: toggle(key, open))]
        if open { items.append(indented(ChatOutlineCardView(rows: [codeText(message.text, color: ChatPalette.Platform.label)]))) }
        return ChatStackView(items, spacing: Space.inline)
    }

    /// アシスタントの思考。初めは「思考」の 1 行に畳み、押すと中身を補足の色の Markdown で開く。`expandedTools` に発言の id があれば開いて出す（snapshot 用）。生成中の行（`streamBlock`）と見出しを共有する
    private func thinking(_ message: ChatMessage) -> ChatPart {
        let key = "thinking:" + message.id
        let open = (state.open[key] ?? look.expandedTools.contains(message.id)) || current == message.id
        var items: [ChatPart] = [thinkingHeader(String(localized: "思考"), open: open, turning: turns(key), toggle: toggle(key, open))]
        if open {
            let chunks = ChatMarkdownChunks.cached(id: message.id, text: message.text, streaming: false)
            let markdown = ChatMarkdownLook(fonts: fonts, query: query, color: ChatPalette.Platform.mutedText, openLink: context.openLink)
            items.append(indented(ChatMarkdownView(blocks: chunks.settled.flatMap { MarkdownBlocks.cached($0) }, look: markdown)))
        }
        return ChatStackView(items, spacing: Space.inline)
    }

    /// 思考の見出し。押せない（生成中の）ときも開閉の印の場所を空け、畳んだ履歴の行と同じ高さ・同じ位置にする
    private func thinkingHeader(_ title: String, open: Bool, turning: Bool = false, toggle: (() -> Void)?) -> ChatPart {
        ChatDisclosureHeaderView(
            open: open, fonts: fonts,
            parts: [
                .symbol("brain", size: fonts.platformSubheadline.pointSize, tint: .muted, label: nil),
                .text(ChatAttributed.label(title, font: fonts.platformSubheadline, query: nil), tint: .muted, flexible: false, truncation: .byTruncatingTail),
            ],
            color: ChatPalette.Platform.mutedText, turning: turning, toggle: toggle)
    }

    /// taskboard が人の発言として入れた知らせ。初めは見出しの 1 行に畳み、押すと全文を開く。回答と済ませた手作業は人の吹き出しのまま畳む。
    /// `expandedTools` に発言の id があれば開いて出す（snapshot 用）
    private func notice(_ message: ChatMessage, _ notice: TaskboardNotice) -> ChatPart {
        let key = "notice:" + message.id
        let open = (state.open[key] ?? look.expandedTools.contains(message.id)) || current == message.id
        let summary = notice.summary(of: message.text)
        // 見出しの 1 行の後ろ。1 行だけの知らせ（利用枠の続き）は開く中身が無い
        let rest = TaskboardNotice.stripMarker(message.text).drop { $0 != "\n" }.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        let toggle = rest.isEmpty ? nil : toggle(key, open)
        if notice == .answer || notice == .finished {
            // 吹き出しは中身の幅に合わせるので、見出しの行は伸ばさない
            let title = [notice.label, summary].compactMap { $0 }.joined(separator: "　")
            let header = ChatDisclosureHeaderView(
                open: open, fonts: fonts, parts: [.text(ChatAttributed.label(title, font: fonts.platformBody, query: query), tint: .header, flexible: true, truncation: .byTruncatingTail)],
                color: ChatPalette.Platform.text, reservesChevron: false, turning: turns(key), toggle: toggle)
            header.hugs = true
            header.hoverable = false
            header.minHeight = fonts.line
            var inner: [ChatPart] = [header]
            if open, !rest.isEmpty { inner.append(bubbleText(rest, query: query)) }
            let content = ChatStackView(inner, spacing: Space.inline)
            content.hugs = true
            return ChatBubbleView(content: content, fonts: fonts)
        }
        var parts: [ChatHeaderPart] = [
            .symbol(notice.symbol, size: fonts.platformCaption.pointSize, tint: .fixed(ChatPalette.Platform.accent), label: nil),
            .text(ChatAttributed.label(notice.label, font: fonts.platformSubheadlineMedium, query: nil), tint: .header, flexible: false, truncation: .byTruncatingTail),
        ]
        if let summary {
            parts.append(.text(ChatAttributed.label(summary, font: fonts.platformSubheadline, query: query), tint: .header, flexible: true, truncation: .byTruncatingTail))
        }
        var items: [ChatPart] = [ChatDisclosureHeaderView(open: open, fonts: fonts, parts: parts, turning: turns(key), toggle: toggle)]
        if open, !rest.isEmpty {
            let text = ChatTextBlock(ChatAttributed.plain(rest, font: fonts.platformSubheadline, color: ChatPalette.Platform.secondaryText, line: nil, query: query))
            text.text.openLink = context.openLink
            items.append(indented(ChatOutlineCardView(rows: [text])))
        }
        return ChatStackView(items, spacing: Space.inline)
    }

    // MARK: 生成中・送っている発言

    /// 生成中の 1 block。本文は終わる前の Markdown、thinking は畳んだ 1 行（履歴の思考の行と同じ見出し）、ツールの入力は名前だけ
    private func streamBlock(_ block: ConversationTimeline.StreamingBlock) -> ChatPart {
        switch block.block {
        case .text:
            let chunks = ChatMarkdownChunks.cached(id: block.id, text: context.reveal?.text(for: block.id) ?? block.text, streaming: true)
            return assistantBody(chunks.settled.flatMap { MarkdownBlocks.cached($0) } + (chunks.tail.map { MarkdownBlocks.parse($0) } ?? []), codeRun: nil)
        case .thinking:
            return thinkingHeader(block.stopped ? String(localized: "思考") : String(localized: "思考中…"), open: false, toggle: nil)
        case .toolInput:
            let name = block.toolName ?? String(localized: "ツール")
            let row = ChatRowStackView([
                ChatSymbolView("circle.dotted", size: fonts.platformCaption.pointSize, tint: ChatPalette.Platform.generating),
                ChatLabelView(name, font: fonts.platformSubheadlineMedium, color: ChatPalette.Platform.secondaryText),
            ])
            row.setChatAccessibility(.staticText, label: String(localized: "\(name)、準備中"))
            return indented(row)
        }
    }

    /// 送った（送っている）発言。送れなかったら印と［再送信］
    private func outgoing(_ message: ConversationTimeline.Outgoing) -> ChatPart {
        // CLI が受けるまでは薄く出す。view の alphaValue は snapshot（cacheDisplay）に写らないので、字と地の色の濃さで付ける
        let opacity: CGFloat = message.state == .accepted ? 1 : 0.7
        var inner: [ChatPart] = message.fileNames.map { ChatAttachedFileChipView(name: $0, path: nil, fonts: fonts, opacity: opacity) }
        if !message.text.isEmpty { inner.append(bubbleText(message.text, query: nil, opacity: opacity)) }
        if message.attachmentCount > 0 {
            let label = ChatIconLabelView(
                String(localized: "画像\(message.attachmentCount)枚"), symbol: "photo", font: fonts.platformCaption, color: ChatPalette.Platform.secondaryText.fading(opacity))
            label.minHeight = fonts.line
            inner.append(label)
        }
        let content = ChatStackView(inner, spacing: Space.inline)
        content.hugs = true
        var items: [ChatPart] = [ChatBubbleView(content: content, fonts: fonts, opacity: opacity)]
        switch message.state {
        case .failed:
            var parts: [ChatPart] = [
                ChatIconLabelView(String(localized: "送信できませんでした"), symbol: "exclamationmark.circle.fill", font: fonts.platformCaption, color: ChatPalette.Platform.dangerText),
            ]
            if let retry = context.retry {
                let id = message.clientMessageID
                parts.append(ChatButtonView(title: String(localized: "再送信"), bordered: false, font: fonts.platformCaption) { retry(id) })
            }
            let row = ChatRowStackView(parts)
            row.hugs = true
            items.append(row)
        case .queued:
            items.append(ChatIconLabelView(String(localized: "待機中"), symbol: "clock", font: fonts.platformCaption, color: ChatPalette.Platform.mutedText))
        case .sending, .accepted:
            break
        }
        let stack = ChatStackView(items, spacing: Space.inline)
        stack.trailing = true
        return stack
    }

    // MARK: 部品

    /// 開閉の見出しを押したとき。押した状態を覚えて行を組み直す
    private func toggle(_ key: String, _ open: Bool) -> () -> Void {
        { [state, relayout] in
            state.open[key] = !open
            state.turning = key
            relayout()
        }
    }

    /// `key` の見出しを押して開閉したばかりか（組み直した見出しの印を回す）。1 回答えたら外す
    private func turns(_ key: String) -> Bool {
        guard state.turning == key else { return false }
        state.turning = nil
        return true
    }

    /// 畳める行の中身を、見出しの開閉の印の後ろに揃えて置く（`chatRowIndented`）
    private func indented(_ view: ChatPart) -> ChatPart {
        ChatStackView([view], indent: indent)
    }

    /// taskboard の `doc_publish`・`ask_user` が載せた文書。質問を付けたなら質問の数と［質問を開く］、付けていなければ［文書を開く］
    private func documentLink(_ document: DocumentToolRef) -> ChatPart {
        let label = document.questionCount.map { String(localized: "質問\($0)問・\(document.docName)") } ?? document.docName
        let title = document.askID == nil ? String(localized: "文書を開く") : String(localized: "質問を開く")
        let text = ChatTextBlock(ChatAttributed.plain(label, font: fonts.platformCaption, color: ChatPalette.Platform.secondaryText, line: fonts.codeLine, query: nil), hugs: true)
        let button = ChatButtonView(title: title, bordered: true, font: fonts.platformCaption, help: document.docName) { [openLink = context.openLink] in openLink(document.url) }
        return ChatFlowView(items: [text, button])
    }

    private func fileChips(_ files: [ChatFileRef]) -> ChatPart {
        ChatFlowView(items: files.map { ChatFileChipView(ref: $0, fonts: fonts, selected: $0.id == look.openedFile, open: context.openFile) })
    }

    /// 開いたカードの中の、選べるコードの字の文（行の高さは `ChatFonts.codeLine`）
    private func codeText(_ text: String, color: PlatformColor, highlights: Bool = true) -> ChatTextBlock {
        let block = ChatTextBlock(ChatAttributed.plain(text, font: fonts.platformCode, color: color, line: fonts.codeLine, query: highlights ? query : nil))
        block.text.openLink = context.openLink
        return block
    }

    /// 開いたカードの中の注記（行の高さは `ChatFonts.codeLine`）
    private func cardText(_ text: String, font: PlatformFont, color: PlatformColor) -> ChatTextBlock {
        ChatTextBlock(ChatAttributed.plain(text, font: font, color: color, line: fonts.codeLine, query: nil))
    }

    /// 発言の下の操作の帯（コピー・巻き戻し・フォーク）
    private func actionBar(_ message: ChatMessage, actions: ChatMessageActions?) -> ChatRowStackView {
        var items: [ChatPart] = [ChatCopyButtonView(text: message.text)]
        if context.rewindRange.allows(message), actions?.rewind != nil {
            let button = ChatIconButtonView(label: String(localized: "ここまで巻き戻す"), symbol: "arrow.uturn.backward") { [state] in state.actions?.rewind?(message) }
            state.attachRewind(button)
            items.append(button)
        }
        if message.isForkTarget, actions != nil {
            items.append(ChatIconButtonView(label: String(localized: "ここからフォーク"), symbol: "arrow.triangle.branch") { [state] in state.actions?.fork(message) })
        }
        if let count = actions?.forkCounts[message.id], let showForks = actions?.showForks {
            items.append(ChatButtonView(title: String(localized: "フォーク\(count)件"), bordered: false, font: fonts.platformCaption, help: String(localized: "フォークを表示"), action: showForks))
        }
        let bar = ChatRowStackView(items, spacing: Space.inline / 2)
        bar.hugs = true
        return bar
    }

    /// 右クリック（長押し）のメニュー。発言の操作は開いたときの値で組む（`ChatRowState.actions`）
    private func menu(_ message: ChatMessage, withActions: Bool) -> [ChatMenuEntry] {
        var menu: [ChatMenuEntry] = []
        if message.kind == .text {
            let text = message.text
            menu.append(.item(String(localized: "コピー"), symbol: "doc.on.doc") { Pasteboard.copy(text) })
        }
        if withActions, let actions = state.actions {
            if message.isForkTarget {
                menu.append(.item(String(localized: "ここからフォーク"), symbol: "arrow.triangle.branch") { actions.fork(message) })
            }
            if context.rewindRange.allows(message), let rewind = actions.rewind {
                menu.append(.item(String(localized: "ここまで巻き戻す"), symbol: "arrow.uturn.backward", enabled: actions.rewindBlocked == nil) { rewind(message) })
                if let reason = actions.rewindBlocked { menu.append(.note(reason)) }
            }
            if let count = actions.forkCounts[message.id], let showForks = actions.showForks {
                menu.append(.item(String(localized: "フォーク\(count)件を表示"), symbol: "arrow.triangle.branch", action: showForks))
            }
        }
        return menu
    }
}

