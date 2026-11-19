import SwiftUI
import TaskboardKit

/// Markdown の文字の大きさと見た目。`body` を基準に、見出しとコードを決める
struct MarkdownStyle: Sendable {
    /// 箱（コードの塊・表）と行内のコードの見た目
    enum Look: Sendable {
        /// PR・文書：システムの色の箱
        case document
        /// チャット：`ChatPalette` の面と枠（Claude Desktop の Code の画面）。コードの塊は中身の幅にし、行内のコードに地を付ける
        case chat
    }

    var body: Font
    var code: Font
    var heading: @Sendable (Int) -> Font
    var look = Look.document
    /// 本文とコードの行の高さ（チャットだけ。nil ならシステムの既定）
    var line: CGFloat?
    var codeLine: CGFloat?
    /// 塊どうしの間
    var spacing = MarkdownMetrics.blockSpacing

    /// チャット: 設定した pt を基準にする。見出しは本文の 1.143・1.071・1 倍の semibold、コードは本文より 2pt 小さい（14pt で 12pt・行 17pt）
    static func sized(_ size: Double) -> MarkdownStyle {
        let fonts = ChatFonts(size: size)
        return MarkdownStyle(
            body: fonts.body,
            code: fonts.code,
            heading: { level in
                switch level {
                case 1: .system(size: size * 1.143, weight: .semibold)
                case 2: .system(size: size * 1.071, weight: .semibold)
                case 3: .system(size: size, weight: .semibold)
                default: .system(size: size, weight: .medium)
                }
            },
            look: .chat, line: fonts.line, codeLine: fonts.codeLine, spacing: fonts.itemGap)
    }

    /// PR の本文・レビュー
    static let callout = MarkdownStyle(
        body: .callout,
        code: .callout.monospaced(),
        heading: { level in
            switch level {
            case 1: .title3.weight(.semibold)
            case 2: .headline
            default: .callout.weight(.semibold)
            }
        })
}

/// Markdown のブロックを縦に並べて描く。ブロックごとに選んでコピーできる。
/// リンクは http・https とアプリの受け持つ scheme（discord:// など）をアプリの外で、taskboard:// をアプリの中で開き、ファイルと相対パスは開かない（`LinkDestination`）
struct MarkdownView: View {
    @Environment(AppModel.self) private var model: AppModel?
    let blocks: [MarkdownBlock]
    var style: MarkdownStyle = .callout
    /// 一致した箇所に背景色を付ける語（大文字小文字は区別しない）
    var highlight: String?

    init(_ text: String, style: MarkdownStyle = .callout, html: MarkdownBlocks.HTML = .raw, highlight: String? = nil) {
        self.blocks = MarkdownBlocks.cached(text, html: html)
        self.style = style
        self.highlight = highlight
    }

    init(blocks: [MarkdownBlock], style: MarkdownStyle) {
        self.blocks = blocks
        self.style = style
        self.highlight = nil
    }

    var body: some View {
        BlockStack(blocks: blocks, style: style, highlight: highlight, depth: 0)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                switch LinkDestination(url) {
                case .browser:
                    ExternalLinks.open(url)
                    return .handled
                case .app:
                    model?.open(url, from: .link)
                    return .handled
                case .ignore: return .discarded
                }
            })
    }
}

/// チャットの本文の塊。書き終えた塊と、生成中なら書きかけの残り。空白だけの塊は捨てる。
/// 文が前の文の続きなら、前の区切りの続きだけ数え、変わらない塊は前に作った文字列をそのまま使う（行の中身の比較がすぐ済む）
struct ChatMarkdownChunks {
    private var scan = MarkdownBlocks.SettledScan()
    /// 区切りごとの塊。空白だけなら nil
    private var pieces: [String?] = []

    mutating func update(_ text: String, streaming: Bool) -> (settled: [String], tail: String?) {
        let changed = scan.advance(to: text)
        let breaks = scan.breaks
        pieces.removeSubrange(min(changed, pieces.count)...)
        let utf8 = text.utf8
        func index(_ offset: Int) -> String.Index { utf8.index(utf8.startIndex, offsetBy: offset) }
        for number in pieces.count..<breaks.count {
            let piece = text[index(number == 0 ? 0 : breaks[number - 1])..<index(breaks[number])]
            pieces.append(piece.allSatisfy(\.isWhitespace) ? nil : String(piece))
        }
        let settled = pieces.compactMap { $0 }
        let rest = text[index(breaks.last ?? 0)...]
        guard !rest.allSatisfy(\.isWhitespace) else { return (settled, nil) }
        guard !streaming else { return (settled, String(rest)) }
        return (settled + [String(rest)], nil)
    }

    /// 発言ごとの控え。大きさは文の UTF-8 の長さで数える
    @MainActor static func cached(id: String, text: String, streaming: Bool) -> (settled: [String], tail: String?) {
        let key = id as NSString
        let entry = cache.object(forKey: key) ?? Entry()
        let result = entry.chunks.update(text, streaming: streaming)
        cache.setObject(entry, forKey: key, cost: text.utf8.count * 2)
        return result
    }

    @MainActor private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    private final class Entry {
        var chunks = ChatMarkdownChunks()
    }
}

private struct BlockStack: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    let highlight: String?
    let depth: Int
    /// 箇条書きの項目の中は、子のリストを親の行に寄せる。nil なら `style.spacing`
    var spacing: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: spacing ?? style.spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        // 中のコードの塊は `codeLine` で上書きする
        .lineHeight(style.line.map { .exact(points: $0) })
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            style.text(text, highlight: highlight)
                .font(style.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let text):
            style.text(text, highlight: highlight)
                .font(style.heading(level))
                .padding(.top, level <= 2 ? MarkdownMetrics.tightSpacing : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let list):
            ListBlock(list: list, style: style, highlight: highlight, depth: depth)
        case .code(let code, let language):
            CodeBlock(code: code, language: language, style: style, highlight: highlight)
        case .quote(let inner):
            HStack(alignment: .top, spacing: MarkdownMetrics.quoteSpacing) {
                quoteBar
                BlockStack(blocks: inner, style: style, highlight: highlight, depth: depth)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            rule.padding(.vertical, MarkdownMetrics.tightSpacing)
        case .table(let table):
            TableBlock(table: table, style: style, highlight: highlight)
        }
    }

    @ViewBuilder
    private var quoteBar: some View {
        switch style.look {
        case .document: Capsule().fill(Color.secondary.opacity(0.4)).frame(width: 3)
        case .chat: Rectangle().fill(ChatPalette.fillStrong).frame(width: 2)
        }
    }

    @ViewBuilder
    private var rule: some View {
        switch style.look {
        case .document: Divider()
        case .chat: Rectangle().fill(ChatPalette.fillStronger).frame(height: 0.5)
        }
    }
}

extension MarkdownStyle {
    /// 段落・見出し・表のセルの文。チャットの行内のコードは、コードの色の文字にし、地を角丸で敷く
    /// （`backgroundColor` の地は角が無く、字の幅ぴったりになる）
    @ViewBuilder
    func text(_ text: AttributedString, highlight: String?) -> some View {
        let marked = TextHighlight.mark(text, highlight)
        if look == .chat, let joined = InlineCode.text(marked) {
            joined.textRenderer(InlineCode.Renderer())
        } else {
            Text(marked)
        }
    }
}

/// チャットの行内のコードの印と、その地を描く renderer
private struct InlineCode: TextAttribute {
    /// コードの run に印を付けた文。コードの run が無ければ nil
    static func text(_ text: AttributedString) -> Text? {
        guard let pieces = pieces(text) else { return nil }
        var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: pieces.count)
        for piece in pieces { joined.appendInterpolation(piece) }
        // `Text + Text` は deprecated なので文字列の補間でつなぐ（catalog には中身の無い鍵「%@」が出る）
        return Text(LocalizedStringKey(stringInterpolation: joined))
    }

    private static func pieces(_ text: AttributedString) -> [Text]? {
        func isCode(_ run: AttributedString.Runs.Run) -> Bool {
            run.inlinePresentationIntent?.contains(.code) == true && run.link == nil
        }
        guard text.runs.contains(where: isCode) else { return nil }
        return text.runs.map { run in
            guard isCode(run) else { return Text(AttributedString(text[run.range])) }
            var code = AttributedString(text[run.range])
            code.foregroundColor = ChatPalette.inlineCode
            return Text(code).customAttribute(InlineCode())
        }
    }

    struct Renderer: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            let inset = MarkdownMetrics.inlineCodeInset
            for line in layout {
                for run in line where run[InlineCode.self] != nil {
                    let rect = run.typographicBounds.rect.insetBy(dx: -inset.width, dy: -inset.height)
                    context.fill(RoundedRectangle(cornerRadius: Radius.chip).path(in: rect), with: .color(ChatPalette.fill))
                }
            }
            for line in layout { context.draw(line) }
        }
    }
}

/// diff の塊の行の印。足した行と消した行に地を敷き、行の頭の + − に差分の色、hunk と見出しの行に薄い色を付ける（`ChatDiffLine` と同じ色）
private struct DiffLines: TextAttribute {
    let kind: DiffCode.Kind

    static func text(_ code: String, highlight: String?) -> Text {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: lines.count)
        for (index, (line, kind)) in zip(lines, DiffCode.kinds(code)).enumerated() {
            var piece = TextHighlight.mark(AttributedString(line + (index < lines.count - 1 ? "\n" : "")), highlight)
            switch kind {
            case .added, .removed:
                if let first = piece.characters.indices.first {
                    piece[first..<piece.characters.index(after: first)].foregroundColor = kind == .added ? DiffPalette.added : DiffPalette.removed
                }
            case .hunk, .header: piece.foregroundColor = .secondary
            case .context: break
            }
            joined.appendInterpolation(Text(piece).customAttribute(DiffLines(kind: kind)))
        }
        // `Text + Text` は deprecated なので文字列の補間でつなぐ（`InlineCode.text` と同じ）
        return Text(LocalizedStringKey(stringInterpolation: joined))
    }

    /// 地は文の幅いっぱいにし、上下は隣の行との間まで広げる（行の高さを固定すると、字の枠どうしの間が空く）
    struct Renderer: TextRenderer {
        func draw(layout: Text.Layout, in context: inout GraphicsContext) {
            let lines = Array(layout)
            let width = lines.map(\.typographicBounds.rect.maxX).max() ?? 0
            for (index, line) in lines.enumerated() {
                guard let kind = line.lazy.compactMap({ $0[DiffLines.self]?.kind }).first, kind == .added || kind == .removed else { continue }
                let bounds = line.typographicBounds.rect
                let top = index > 0 ? (lines[index - 1].typographicBounds.rect.maxY + bounds.minY) / 2 : bounds.minY
                let bottom = index < lines.count - 1 ? (bounds.maxY + lines[index + 1].typographicBounds.rect.minY) / 2 : bounds.maxY
                let tint = kind == .added ? DiffPalette.addedBackground : DiffPalette.removedBackground
                context.fill(Path(CGRect(x: 0, y: top, width: width, height: bottom - top)), with: .color(tint))
            }
            for line in lines { context.draw(line) }
        }
    }
}

/// コードの塊。会話の画面では、シェルの言語の塊に［実行］を出し、塊の下に出力を出す（`codeRun`）
private struct CodeBlock: View {
    @Environment(\.codeRun) private var codeRun
    @Environment(\.codeRunMessageID) private var messageID
    let code: String
    let language: String?
    let style: MarkdownStyle
    let highlight: String?

    var body: some View {
        let runnable = language.map(ConversationRunRequest.languages.contains) == true && codeRun != nil && messageID != nil
        let entry = runnable ? messageID.flatMap { codeRun?.entry($0, code) } : nil
        VStack(alignment: .leading, spacing: MarkdownMetrics.tightSpacing) {
            switch style.look {
            case .document:
                codeText.padding(MarkdownMetrics.boxPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: MarkdownMetrics.boxRadius))
                    .overlay(alignment: .topTrailing) {
                        if runnable, let codeRun, let messageID, let language {
                            Button("実行", systemImage: "play.fill") { codeRun.start(code, language, messageID) }
                                .labelStyle(.titleAndIcon)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(entry?.status == .running)
                                .padding(MarkdownMetrics.tightSpacing)
                                .help("会話のシェルで実行")
                        }
                    }
            case .chat:
                ChatCodeBox(code: code, actions: actions(runnable: runnable, running: entry?.status == .running)) {
                    codeText.padding(.horizontal, ChatMetrics.codePadding.width).padding(.vertical, ChatMetrics.codePadding.height)
                }
            }
            if let entry, let codeRun {
                CodeRunOutput(entry: entry, font: style.code, cancel: { codeRun.cancel(entry.id) }, reset: codeRun.reset)
            }
        }
    }

    private var codeText: some View {
        Group {
            if DiffCode.isDiff(language) {
                DiffLines.text(code, highlight: highlight).textRenderer(DiffLines.Renderer())
            } else {
                Text(TextHighlight.mark(AttributedString(code), highlight))
            }
        }
        .font(style.code)
        .lineHeight(style.codeLine.map { .exact(points: $0) })
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 右上の［実行］（シェルの塊だけ）と［コピー］
    private func actions(runnable: Bool, running: Bool) -> ChatCodeActions {
        guard runnable, let codeRun, let messageID, let language else { return ChatCodeActions(run: nil, running: false) }
        return ChatCodeActions(run: { codeRun.start(code, language, messageID) }, running: running)
    }
}

private struct ListBlock: View {
    let list: MarkdownList
    let style: MarkdownStyle
    let highlight: String?
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: MarkdownMetrics.tightSpacing) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: MarkdownMetrics.tightSpacing) {
                    marker(index: index, item: item)
                        .font(style.body)
                        .frame(minWidth: list.start == nil ? MarkdownMetrics.bulletWidth : MarkdownMetrics.numberWidth, alignment: .trailing)
                    BlockStack(blocks: item.blocks, style: style, highlight: highlight, depth: depth + 1, spacing: MarkdownMetrics.tightSpacing)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(index: Int, item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(checked ? "済み" : "未完了")
        } else if let start = list.start {
            Text("\(start + index).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(depth == 0 ? "•" : "◦").foregroundStyle(.secondary)
        }
    }
}

private struct TableBlock: View {
    let table: MarkdownTable
    let style: MarkdownStyle
    let highlight: String?

    var body: some View {
        switch style.look {
        case .document: documentTable
        case .chat: chatTable
        }
    }

    /// チャットの表: セルごとに地（見出しは濃く）を敷き、セルの間を空ける。線と外の枠は引かない
    private var chatTable: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: MarkdownMetrics.tableCellSpacing, verticalSpacing: MarkdownMetrics.tableCellSpacing) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        chatCell(cell, column: column, fill: ChatPalette.fillStrong).fontWeight(.semibold)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            chatCell(cell, column: column, fill: ChatPalette.fill)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chatCell(_ text: AttributedString, column: Int, fill: Color) -> some View {
        let alignment = alignment(column)
        // 行の中で一番高いセルに揃えて地を敷く
        return self.cell(text, column: column)
            .padding(MarkdownMetrics.tableCellPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment.horizontal, vertical: .top))
            .background(fill, in: RoundedRectangle(cornerRadius: MarkdownMetrics.tableCellRadius))
            .gridColumnAlignment(alignment.horizontal)
    }

    private var documentTable: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: MarkdownMetrics.tableColumnSpacing, verticalSpacing: MarkdownMetrics.tightSpacing) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column).fontWeight(.semibold).gridColumnAlignment(alignment(column).horizontal)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column)
                        }
                    }
                }
            }
            .padding(MarkdownMetrics.boxPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: MarkdownMetrics.boxRadius))
        .overlay(RoundedRectangle(cornerRadius: MarkdownMetrics.boxRadius).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        TableCellWidth(maxWidth: MarkdownMetrics.tableCellMaxWidth) {
            style.text(text, highlight: highlight)
                .font(style.body)
                .multilineTextAlignment(alignment(column).text)
        }
    }

    private func alignment(_ column: Int) -> (horizontal: HorizontalAlignment, text: TextAlignment) {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading: (.leading, .leading)
        case .center: (.center, .center)
        case .trailing: (.trailing, .trailing)
        }
    }
}

/// 中身の理想の幅が上限を超えるときは、上限の幅で折り返した大きさを返す。
/// frame(maxWidth:) は、幅の案が無いとき（横の ScrollView の中の Grid）に 1 行の高さのまま幅だけを縮め、折り返した行が下の行に重なった
private struct TableCellWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, maxWidth, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// 検索の一致箇所に背景色を付ける
enum TextHighlight {
    static let color = Color.yellow.opacity(0.45)

    static func mark(_ text: AttributedString, _ query: String?) -> AttributedString {
        guard let query, !query.isEmpty else { return text }
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex, let range = result[searchStart...].range(of: query, options: [.caseInsensitive]) {
            result[range].backgroundColor = color
            searchStart = range.upperBound
        }
        return result
    }

    static func mark(_ text: String, _ query: String?) -> AttributedString {
        mark(AttributedString(text), query)
    }
}
