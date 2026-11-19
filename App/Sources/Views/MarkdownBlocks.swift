import Foundation
import Markdown

/// Markdown のブロック。`MarkdownBlocks.parse` が作り、`MarkdownView` が描く。
/// SwiftUI と同じファイルに置くと `Text` / `Link` / `Image` / `Table` が swift-markdown の型と衝突するので、描画とファイルを分ける
enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case list(MarkdownList)
    /// 言語は info string の先頭の語（会話の［実行］を出すかと、diff の塊の色付け（`DiffCode`）に使う）
    case code(String, language: String? = nil)
    case quote([MarkdownBlock])
    case rule
    case table(MarkdownTable)
}

struct MarkdownList: Equatable {
    struct Item: Equatable {
        /// nil はチェックボックスの無い項目
        var checked: Bool?
        var blocks: [MarkdownBlock]
    }

    /// 番号付きなら開始番号
    var start: Int?
    var items: [Item]
}

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var alignments: [Alignment]
    var header: [AttributedString]
    /// 各行のセル数は `alignments.count` に揃えてある（足りない分は空）
    var rows: [[AttributedString]]
}

enum MarkdownBlocks {
    /// 本文に書かれた HTML の扱い
    enum HTML: Sendable {
        /// 書かれた文字のまま出す（チャット。Claude Code の返事の HTML は、コードの話として書かれていることが多い）
        case raw
        /// タグを外した文字で出す（PR の本文とレビュー。GitHub は HTML として描くので、テンプレートのコメントと dependabot の details がタグのまま並んでいた）
        case text
    }

    /// cmark-gfm でパースし、描く単位のブロックに直す。行内は AttributedString に直接組む
    /// （format() で Markdown に戻して `AttributedString(markdown:)` に渡すと、エスケープと空白が変わる）
    static func parse(_ text: String, html: HTML = .raw) -> [MarkdownBlock] {
        // smart は引用符やダッシュを書き換えるので切る。チャットの本文は書かれたとおりに出す
        let document = Markdown.Document(parsing: text, options: [.disableSmartOpts, .disableSourcePosOpts])
        return blocks(document.children, html: html)
    }

    /// 描き直しのたびに parse しない（チャットと PR の本文は親の body が走るたびに作り直される）
    @MainActor static func cached(_ text: String, html: HTML = .raw) -> [MarkdownBlock] {
        let key = "\(html == .raw ? "r" : "t"):\(text)" as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let parsed = parse(text, html: html)
        cache.setObject(CachedBlocks(blocks: parsed), forKey: key, cost: text.utf8.count)
        return parsed
    }

    /// 生成中の文を書き終えた塊に分ける区切り：コードの塊の外にある空行の次（空行が続くときは最後の空行の次だけ）。
    /// 最後の区切りより後ろは書きかけとみなす。差分が届くたびに全文を数え直さないよう、数え終えた行の続きから数える
    struct SettledScan {
        /// 区切りの位置（UTF-8 の位置）
        private(set) var breaks: [Int] = []
        /// 前に数えた文。`scanned` までが次の文の頭と同じなら、そこから続ける
        private var text = ""
        /// 数え終えた行の終わり（UTF-8 の位置。改行の次）
        private var scanned = 0
        private var open: Fence?
        private var blankRun = false

        /// `text` まで数える。戻り値は、前と変わった最初の区切りの番号（変わらなければ `breaks.count`）
        @discardableResult
        mutating func advance(to text: String) -> Int {
            if !Self.hasPrefix(text, self.text, length: scanned) { self = SettledScan() }
            self.text = text
            var changed = breaks.count
            var lineStart = text.utf8.index(text.startIndex, offsetBy: scanned)
            while let lineEnd = text[lineStart...].firstIndex(of: "\n") {
                let line = text[lineStart..<lineEnd]
                if let fence = Fence(line) {
                    if let current = open {
                        if fence.closes(current) { open = nil }
                    } else {
                        open = fence
                    }
                }
                lineStart = text.index(after: lineEnd)
                let blank = open == nil && line.allSatisfy({ $0 == " " || $0 == "\t" })
                if blank {
                    let offset = text.utf8.distance(from: text.startIndex, to: lineStart)
                    if blankRun {
                        breaks[breaks.count - 1] = offset
                        changed = min(changed, breaks.count - 1)
                    } else {
                        breaks.append(offset)
                    }
                }
                blankRun = blank
            }
            scanned = text.utf8.distance(from: text.startIndex, to: lineStart)
            return changed
        }

        /// UTF-8 の頭の `length` バイトが同じ
        private static func hasPrefix(_ text: String, _ prefix: String, length: Int) -> Bool {
            guard length > 0 else { return true }
            guard text.utf8.count >= length else { return false }
            var text = text
            var prefix = prefix
            return text.withUTF8 { a in prefix.withUTF8 { b in memcmp(a.baseAddress!, b.baseAddress!, length) == 0 } }
        }
    }

    /// コードの塊の囲みの行（CommonMark の fenced code block）。字下げは 3 つまで、同じ文字が 3 つ以上
    private struct Fence {
        let mark: Character
        let length: Int
        /// 囲みの後ろに文字（言語の名前など）がある。閉じの行にはならない
        let hasInfo: Bool

        init?(_ line: Substring) {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
            let length = rest.prefix { $0 == mark }.count
            guard length >= 3 else { return nil }
            let info = rest.dropFirst(length)
            // ` の囲みの言語の名前には ` を入れられない（入っていれば行内のコード）
            if mark == "`", info.contains("`") { return nil }
            self.mark = mark
            self.length = length
            hasInfo = !info.allSatisfy { $0 == " " || $0 == "\t" }
        }

        func closes(_ opening: Fence) -> Bool {
            mark == opening.mark && length >= opening.length && !hasInfo
        }
    }

    /// HTML をタグを外した文字にする。コメントは消し、行を区切るタグ（br・p・li・見出し・summary など）は改行にし、文字参照を戻す
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacing(/<!--[\s\S]*?(-->|$)/, with: "")
        text = text.replacing(/<br\s*\/?>/.ignoresCase(), with: "\n")
        text = text.replacing(/<li(\s[^>]*)?>/.ignoresCase(), with: "• ")
        text = text.replacing(/<\/(p|div|li|h[1-6]|summary|details|tr|blockquote|ul|ol|pre|table)\s*>/.ignoresCase(), with: "\n")
        text = text.replacing(/<[^>]*>/, with: "")
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // タグを外して空いた行は詰める（閉じタグと元の改行が重なり、項目の間に空行が挟まった）。
        // 項目の中で段落が始まる形（<li>\n<p>…）は、印だけの行を次の行とつなぐ
        var lines: [String] = []
        for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if lines.last == "•" { lines[lines.count - 1] = "• " + line } else { lines.append(line) }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor private static let cache: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    /// 行数で畳む表示（PR のレビュー本文の compact）向けに、ブロックを改行区切りの 1 本にする。
    /// 表はセルを「 | 」で、箇条書きは「• 」「1. 」を頭に付けてつなぐ
    static func flattened(_ blocks: [MarkdownBlock]) -> AttributedString {
        var lines: [AttributedString] = []
        func walk(_ blocks: [MarkdownBlock], indent: String) {
            for block in blocks {
                switch block {
                case .paragraph(let text), .heading(_, let text):
                    lines.append(AttributedString(indent) + text)
                case .list(let list):
                    for (index, item) in list.items.enumerated() {
                        let marker = switch (item.checked, list.start) {
                        case (true?, _): "☑ "
                        case (false?, _): "☐ "
                        case (nil, let start?): "\(start + index). "
                        case (nil, nil): "• "
                        }
                        let first = lines.count
                        walk(item.blocks, indent: indent + "  ")
                        if lines.indices.contains(first) {
                            // 項目の 1 行目だけ、字下げの末尾 2 文字を印に置き換える
                            var line = AttributedString(indent + marker)
                            line += lines[first][lines[first].index(lines[first].startIndex, offsetByCharacters: indent.count + 2)...]
                            lines[first] = line
                        } else {
                            lines.append(AttributedString(indent + marker))
                        }
                    }
                case .code(let code, _):
                    for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                        var piece = AttributedString(String(line))
                        piece.inlinePresentationIntent = .code
                        lines.append(AttributedString(indent) + piece)
                    }
                case .quote(let inner):
                    walk(inner, indent: indent + "> ")
                case .rule:
                    lines.append(AttributedString(indent + "―"))
                case .table(let table):
                    for row in [table.header] + table.rows {
                        var line = AttributedString(indent)
                        for (column, cell) in row.enumerated() {
                            if column > 0 { line += AttributedString(" | ") }
                            line += cell
                        }
                        lines.append(line)
                    }
                }
            }
        }
        walk(blocks, indent: "")
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += line
        }
        return result
    }

    private static func blocks(_ children: some Sequence<any Markup>, html: HTML) -> [MarkdownBlock] {
        children.compactMap { block($0, html: html) }
    }

    private static func block(_ markup: any Markup, html mode: HTML) -> MarkdownBlock? {
        switch markup {
        case let paragraph as Paragraph:
            let text = inline(paragraph.children, html: mode)
            // タグだけの段落（<p align="center"> など）は、外すと何も残らない
            return mode == .text && text.characters.allSatisfy(\.isWhitespace) ? nil : .paragraph(text)
        case let heading as Heading:
            return .heading(level: heading.level, inline(heading.children, html: mode))
        case let list as UnorderedList:
            return .list(MarkdownList(start: nil, items: items(list.listItems, html: mode)))
        case let list as OrderedList:
            return .list(MarkdownList(start: Int(list.startIndex), items: items(list.listItems, html: mode)))
        case let code as CodeBlock:
            let language = code.language?.split(separator: " ").first.map { $0.lowercased() }
            return .code(code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code, language: language?.isEmpty == false ? language : nil)
        case let quote as BlockQuote:
            return .quote(blocks(quote.children, html: mode))
        case is ThematicBreak:
            return .rule
        case let table as Markdown.Table:
            return .table(self.table(table, html: mode))
        case let html as HTMLBlock:
            let raw = html.rawHTML.hasSuffix("\n") ? String(html.rawHTML.dropLast()) : html.rawHTML
            guard mode == .text else { return .paragraph(AttributedString(raw)) }
            let text = plainText(fromHTML: raw)
            return text.isEmpty ? nil : .paragraph(AttributedString(text))
        default:
            return nil
        }
    }

    private static func items(_ listItems: some Sequence<ListItem>, html: HTML) -> [MarkdownList.Item] {
        listItems.map { item in
            let checked: Bool? = switch item.checkbox {
            case .checked: true
            case .unchecked: false
            case nil: nil
            }
            return MarkdownList.Item(checked: checked, blocks: blocks(item.children, html: html))
        }
    }

    private static func table(_ table: Markdown.Table, html: HTML) -> MarkdownTable {
        let alignments: [MarkdownTable.Alignment] = table.columnAlignments.map {
            switch $0 {
            case .center: .center
            case .right: .trailing
            case .left, nil: .leading
            }
        }
        func cells(_ row: some TableCellContainer) -> [AttributedString] {
            var cells: [AttributedString] = row.cells.map { inline($0.children, html: html) }
            if cells.count < alignments.count { cells += Array(repeating: AttributedString(), count: alignments.count - cells.count) }
            return Array(cells.prefix(alignments.count))
        }
        return MarkdownTable(alignments: alignments, header: cells(table.head), rows: table.body.rows.map(cells))
    }

    private static func inline(_ children: some Sequence<any Markup>, html: HTML, intent: InlinePresentationIntent = [], link: URL? = nil) -> AttributedString {
        var result = AttributedString()
        for child in children {
            switch child {
            case let text as Markdown.Text:
                result += styled(text.string, intent: intent, link: link)
            case let code as InlineCode:
                result += styled(code.code, intent: intent.union(.code), link: link)
            case let strong as Strong:
                result += inline(strong.children, html: html, intent: intent.union(.stronglyEmphasized), link: link)
            case let emphasis as Emphasis:
                result += inline(emphasis.children, html: html, intent: intent.union(.emphasized), link: link)
            case let strike as Strikethrough:
                result += inline(strike.children, html: html, intent: intent.union(.strikethrough), link: link)
            case let anchor as Markdown.Link:
                result += inline(anchor.children, html: html, intent: intent, link: anchor.destination.flatMap(URL.init(string:)) ?? link)
            case let image as Markdown.Image:
                // 画像は描かず、代替文だけ残す
                result += inline(image.children, html: html, intent: intent, link: link)
            case is SoftBreak:
                // チャットは改行をそのまま見せる（Claude Code の返答は 1 行ずつ意味を持つことが多い）
                result += styled("\n", intent: intent, link: link)
            case is LineBreak:
                result += styled("\n", intent: intent, link: link)
            case let tag as InlineHTML:
                // タグを外すときは、改行のタグだけ改行に残す
                let text = html == .raw ? tag.rawHTML : (tag.rawHTML.contains(/^<br\s*\/?>$/.ignoresCase()) ? "\n" : "")
                result += styled(text, intent: intent, link: link)
            default:
                result += styled(child.format(), intent: intent, link: link)
            }
        }
        return result
    }

    private static func styled(_ string: String, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        // リンクの中とコードの中は、書かれた URL をリンクにしない（コードは書き写すためのもの）
        guard link == nil, !intent.contains(.code) else {
            var piece = AttributedString(string)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link { piece.link = link }
            return piece
        }
        var result = AttributedString()
        for segment in linkSegments(string) {
            var piece = AttributedString(segment.text)
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let url = segment.url { piece.link = url }
            result += piece
        }
        return result
    }

    /// 文の中の素の URL（http・https）を切り出す。swift-markdown 0.9.0 は cmark-gfm の autolink の拡張を付けないので、
    /// `[文字](URL)` の形でない URL（Claude Code の発言に多い）はリンクにならない
    static func linkSegments(_ string: String) -> [(text: String, url: URL?)] {
        guard let detector = urlDetector, !string.isEmpty else { return [(string, nil)] }
        var segments: [(text: String, url: URL?)] = []
        var cursor = string.startIndex
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased()), let range = Range(match.range, in: string) else { continue }
            if cursor < range.lowerBound { segments.append((String(string[cursor..<range.lowerBound]), nil)) }
            segments.append((String(string[range]), url))
            cursor = range.upperBound
        }
        if cursor < string.endIndex { segments.append((String(string[cursor...]), nil)) }
        return segments.isEmpty ? [(string, nil)] : segments
    }

    // NSDataDetector は Sendable でないが、作った後は読むだけで、NSRegularExpression と同じく並行に使える
    nonisolated(unsafe) private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

/// リンクを押したときの開き先。`MarkdownView` の `openURL` が使う
enum LinkDestination: Equatable {
    /// アプリの外（既定のブラウザ・メール・その scheme を受け持つアプリ。`ExternalLinks`）
    case browser
    /// アプリの中の画面（`AppModel.open(_:)`）
    case app
    /// 開かない（`file://` と相対パス。会話のファイルはファイルの札から開く）
    case ignore

    init(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "taskboard": self = .app
        default: self = ExternalLinks.isExternal(url) ? .browser : .ignore
        }
    }
}

private final class CachedBlocks {
    let blocks: [MarkdownBlock]
    init(blocks: [MarkdownBlock]) { self.blocks = blocks }
}

/// 言語が diff・patch のコードの塊の行の種類。足した行・消した行は差分の色（`DiffPalette`）、hunk と見出しは薄い色で描く
enum DiffCode {
    enum Kind: Equatable {
        case context, added, removed, hunk, header
    }

    static func isDiff(_ language: String?) -> Bool {
        language == "diff" || language == "patch"
    }

    /// 改行で分けた行ごとの種類。`---`・`+++` は hunk の前でだけ見出しにする（hunk の中では `--` で始まる行を消した・足した行）
    static func kinds(_ code: String) -> [Kind] {
        var inHunk = false
        return code.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if line.hasPrefix("diff ") {
                inHunk = false
                return .header
            }
            if line.hasPrefix("@@") {
                inHunk = true
                return .hunk
            }
            if line.hasPrefix("\\") { return .header }
            if !inHunk, line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("index ") { return .header }
            if line.hasPrefix("+") { return .added }
            if line.hasPrefix("-") { return .removed }
            return .context
        }
    }

    /// swift-markdown の HTML の diff の塊（`<code class="language-diff">`）の行を、種類の class の span で包む。
    /// 改行は span の中に残し、本文の文字の並びを変えない（文書の引用の検索が文字で探す）
    static func html(_ html: String) -> String {
        var result = ""
        var rest = Substring(html)
        while let open = rest.range(of: #"<code class="language-(diff|patch)">"#, options: [.regularExpression, .caseInsensitive]),
              let close = rest[open.upperBound...].range(of: "</code>") {
            result += rest[..<open.upperBound]
            let body = String(rest[open.upperBound..<close.lowerBound])
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            let trailing = body.hasSuffix("\n")
            if trailing { lines.removeLast() }
            // 種類は escape した後の文字で見る（行の頭の + − @ \ と英字は escape されない）
            let kinds = Self.kinds(lines.joined(separator: "\n"))
            for (index, (line, kind)) in zip(lines, kinds).enumerated() {
                let newline = index < lines.count - 1 || trailing ? "\n" : ""
                // 行の頭の + − だけに色を付ける（`::first-letter` は記号の後ろの 1 字まで含む）
                let text = kind == .added || kind == .removed ? "<span class=\"tb-sign\">\(line.prefix(1))</span>\(line.dropFirst())" : String(line)
                result += "<span class=\"tb-diff-\(kind)\">\(text)\(newline)</span>"
            }
            result += "</code>"
            rest = rest[close.upperBound...]
        }
        return result + rest
    }
}
