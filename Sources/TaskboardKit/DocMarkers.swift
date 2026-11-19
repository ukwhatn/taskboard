import Foundation

/// 文書の本文に置く、質問か送る文面の欄の印。markdown は `<!-- ask: q1 -->`・`<!-- draft: slack-1 -->`、HTML は `<div data-ask="q1"></div>`・`<div data-draft="slack-1"></div>`
public struct DocMarker: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case ask, draft
    }

    public var kind: Kind
    public var id: String

    public init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    /// 欄の置き場の名前（`ask:q1`）。アプリの欄と、印の位置へ送る先に使う
    public var slot: String { "\(kind.rawValue):\(id)" }
}

/// 本文の印を読む。daemon は publish の照合に、アプリは HTML にした本文の置き換えに同じ規則を使う
public enum DocMarkers {
    private static let idPattern = "[A-Za-z0-9._-]+"
    private static let comment = try! NSRegularExpression(pattern: "<!--\\s*(ask|draft)\\s*:\\s*(\(idPattern))\\s*-->")
    /// 中身の無い要素（`<div data-ask="q1"></div>`）は閉じタグまでを印にする
    private static let attribute = try! NSRegularExpression(
        pattern: "<([A-Za-z][A-Za-z0-9]*)\\b[^>]*?\\sdata-(ask|draft)\\s*=\\s*[\"'](\(idPattern))[\"'][^>]*>(?:\\s*</\\1\\s*>)?")

    /// 本文の順の印。markdown はコード（fenced code・backtick）の中を読まない。swift-markdown の HTML でもそこは escape されて印にならない
    public static func markers(in content: String, format: DocFormat) -> [DocMarker] {
        let text = format == .markdown ? withoutCode(content) : content
        return matches(in: text).map(\.marker)
    }

    /// 印を `slot` の返す HTML に置き換える。nil を返した印はそのまま残す
    public static func replace(in html: String, slot: (DocMarker) -> String?) -> String {
        var result = html
        for match in matches(in: html).reversed() {
            guard let replacement = slot(match.marker), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// 印が質問・文面の id を指しているか。外れていれば会話へ返す理由
    public static func problem(_ markers: [DocMarker], questions: Set<String>, drafts: Set<String>) -> String? {
        var seen = Set<DocMarker>()
        for marker in markers {
            guard seen.insert(marker).inserted else { return Copy.text("agent.doc.marker.duplicate", ["slot": marker.slot]) }
            switch marker.kind {
            case .ask where !questions.contains(marker.id): return Copy.text("agent.doc.marker.unknownAsk", ["id": marker.id])
            case .draft where !drafts.contains(marker.id): return Copy.text("agent.doc.marker.unknownDraft", ["id": marker.id])
            default: continue
            }
        }
        return nil
    }

    private struct Match {
        var marker: DocMarker
        var range: NSRange
    }

    private static func matches(in text: String) -> [Match] {
        let whole = NSRange(text.startIndex..., in: text)
        let ns = text as NSString
        let comments = comment.matches(in: text, range: whole).map { m in
            Match(marker: DocMarker(kind: DocMarker.Kind(rawValue: ns.substring(with: m.range(at: 1)))!, id: ns.substring(with: m.range(at: 2))), range: m.range)
        }
        let attributes = attribute.matches(in: text, range: whole).map { m in
            Match(marker: DocMarker(kind: DocMarker.Kind(rawValue: ns.substring(with: m.range(at: 2)))!, id: ns.substring(with: m.range(at: 3))), range: m.range)
        }
        return (comments + attributes).sorted { $0.range.location < $1.range.location }
    }

    private static let inlineCode = try! NSRegularExpression(pattern: "(`+)[^`]*?\\1")

    /// fenced code の行と backtick の中を外す。shortcut: 字下げのコードの塊は区別しない。印の例を字下げで書いた文書が断られたら swift-markdown で読む
    static func withoutCode(_ content: String) -> String {
        var fence: String?
        var lines: [String] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            let opener = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let current = fence {
                if opener == current { fence = nil }
                continue
            }
            if let opener, line.count - trimmed.count <= 3 {
                fence = opener
                continue
            }
            let text = String(line)
            lines.append(inlineCode.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""))
        }
        return lines.joined(separator: "\n")
    }
}
