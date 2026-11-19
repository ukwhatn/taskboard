import Foundation

/// 文書が読み込む外部の資源のホスト。アプリは外部の読み込みを止めて描き、止めた資源を WKWebView から知る手段が無いので、
/// daemon が publish のときに本文から集めて版に持たせる（アプリはこれを帯に出し、許されたときだけ止めずに描く）
public enum DocExternalHosts {
    /// 読み込みに使う属性（`href` はリンクの `a`・`area` を除く）
    private static let tag = try! NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9-]*)(\\s[^>]*)>")
    private static let attribute = try! NSRegularExpression(
        pattern: "\\s(src|srcset|href|poster)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [.caseInsensitive])
    private static let cssURL = try! NSRegularExpression(pattern: "url\\(\\s*[\"']?([^\"')\\s]+)", options: [.caseInsensitive])
    private static let cssImport = try! NSRegularExpression(pattern: "@import\\s+[\"']([^\"']+)[\"']", options: [.caseInsensitive])
    private static let markdownImage = try! NSRegularExpression(pattern: "!\\[[^\\]]*\\]\\(\\s*<?([^)\\s>]+)")
    private static let markdownImageReference = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\[([^\\]]*)\\]")
    private static let markdownDefinition = try! NSRegularExpression(pattern: "^ {0,3}\\[([^\\]]+)\\]:\\s*<?(\\S+?)>?(?:\\s|$)", options: [.anchorsMatchLines])

    /// 小文字にして重複を除き、並べたホスト。https だけを数える（http は ATS が止め、相対・`//` は文書の基点が無いので、許しても読み込まれない）
    public static func hosts(in content: String, format: DocFormat) -> [String] {
        let text = format == .markdown ? DocMarkers.withoutCode(content) : content
        var urls = attributeURLs(in: text) + captures(cssURL, in: text, group: 1) + captures(cssImport, in: text, group: 1)
        if format == .markdown { urls += markdownImageURLs(in: text) }
        let hosts = urls.compactMap { raw -> String? in
            guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https" else { return nil }
            return url.host()?.lowercased()
        }
        return Array(Set(hosts)).sorted()
    }

    private static func attributeURLs(in text: String) -> [String] {
        let ns = text as NSString
        return tag.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { t -> [String] in
            let name = ns.substring(with: t.range(at: 1)).lowercased()
            let attributes = ns.substring(with: t.range(at: 2))
            let attrs = attributes as NSString
            return attribute.matches(in: attributes, range: NSRange(location: 0, length: attrs.length)).flatMap { m -> [String] in
                let key = attrs.substring(with: m.range(at: 1)).lowercased()
                if key == "href", name == "a" || name == "area" { return [] }
                guard let value = (2...4).lazy.map({ m.range(at: $0) }).first(where: { $0.location != NSNotFound }).map(attrs.substring(with:)) else { return [] }
                // srcset は「URL 幅の記述, …」の並び
                return key == "srcset" ? value.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) } : [value]
            }
        }
    }

    private static func markdownImageURLs(in text: String) -> [String] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var definitions: [String: String] = [:]
        for m in markdownDefinition.matches(in: text, range: whole) {
            definitions[ns.substring(with: m.range(at: 1)).lowercased()] = ns.substring(with: m.range(at: 2))
        }
        // `![図][]` は題を参照の名前にする
        let references = markdownImageReference.matches(in: text, range: whole).compactMap { m -> String? in
            let label = ns.substring(with: m.range(at: 2))
            return definitions[(label.isEmpty ? ns.substring(with: m.range(at: 1)) : label).lowercased()]
        }
        return captures(markdownImage, in: text, group: 1) + references
    }

    private static func captures(_ pattern: NSRegularExpression, in text: String, group: Int) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: group)) }
    }
}
