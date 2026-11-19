import Foundation

/// 画像でない添付。ファイルは送らず、daemon のマシンの絶対パスを本文の頭に書き、agent が自分のツールで読む
/// （Claude Desktop・Codex Desktop と同じ形。Desktop の形に合わせると、CLI と app-server がその形を前提にしていても読める）
public enum MentionedFiles {
    public static func compose(_ text: String, paths: [String], engine: Conversation.Engine) -> String {
        guard !paths.isEmpty else { return text }
        switch engine {
        case .codex:
            let entries = paths.map { "## \(URL(fileURLWithPath: $0).lastPathComponent): \($0)\n\n" }.joined()
            return "# Files mentioned by the user:\n\n" + entries + "## My request:\n" + text
        case .claude, .unknown:
            let entries = paths.map { "<file><file_path>\(escaped($0))</file_path></file>\n" }.joined()
            let block = "<uploaded_files>\n" + entries + "</uploaded_files>"
            return text.isEmpty ? block : block + "\n\n" + text
        }
    }

    /// 履歴に届いた人の発言の本文から、頭の一覧（`compose` の形）を外し、パスと人が書いた本文に分ける。一覧が頭に無ければ nil
    public static func split(_ text: String) -> (paths: [String], text: String)? {
        claudeList(text) ?? codexList(text)
    }

    private static let claudeOpen = "<uploaded_files>\n", claudeClose = "</uploaded_files>"
    private static let codexOpen = "# Files mentioned by the user:\n\n", codexRequest = "## My request:\n"

    private static func claudeList(_ text: String) -> (paths: [String], text: String)? {
        guard text.hasPrefix(claudeOpen), let close = text.range(of: claudeClose) else { return nil }
        let lines = text[text.index(text.startIndex, offsetBy: claudeOpen.count)..<close.lowerBound].split(separator: "\n")
        var paths: [String] = []
        for line in lines {
            guard line.hasPrefix("<file><file_path>"), line.hasSuffix("</file_path></file>") else { return nil }
            paths.append(unescaped(String(line.dropFirst("<file><file_path>".count).dropLast("</file_path></file>".count))))
        }
        let rest = text[close.upperBound...]
        if rest.isEmpty { return (paths, "") }
        guard rest.hasPrefix("\n\n") else { return nil }
        return (paths, String(rest.dropFirst(2)))
    }

    private static func codexList(_ text: String) -> (paths: [String], text: String)? {
        guard text.hasPrefix(codexOpen) else { return nil }
        var rest = text.dropFirst(codexOpen.count)
        var paths: [String] = []
        while !rest.hasPrefix(codexRequest) {
            guard rest.hasPrefix("## "), let end = rest.range(of: "\n\n"), let path = codexPath(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound]) else { return nil }
            paths.append(path)
            rest = rest[end.upperBound...]
        }
        return (paths, String(rest.dropFirst(codexRequest.count)))
    }

    /// 「## {名前}: {パス}」の名前とパスの切れ目。名前にも「: 」が入りうるので、パスの末尾が名前と合う所で切る
    private static func codexPath(_ entry: Substring) -> String? {
        var from = entry.startIndex
        while let separator = entry.range(of: ": ", range: from..<entry.endIndex) {
            let path = String(entry[separator.upperBound...])
            if URL(fileURLWithPath: path).lastPathComponent == entry[..<separator.lowerBound] { return path }
            from = separator.upperBound
        }
        return nil
    }

    private static func unescaped(_ path: String) -> String {
        path.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
