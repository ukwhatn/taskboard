import Foundation

/// 文を Markdown のコードとして囲む
public enum MarkdownCode {
    /// 中に ` があれば `` で囲み、端の ` は空白で離す
    public static func inline(_ text: String) -> String {
        guard text.contains("`") else { return "`\(text)`" }
        let fence = text.contains("``") ? "```" : "``"
        return "\(fence) \(text) \(fence)"
    }

    /// 中のいちばん長い ` の並びより長い fence で囲む（3 つより短くしない）
    public static func block(_ text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return [fence, text.hasSuffix("\n") ? String(text.dropLast()) : text, fence].joined(separator: "\n")
    }
}
