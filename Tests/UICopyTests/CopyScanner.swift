import Foundation

/// Swift のソースから文字列リテラルを取り出す。補間 `\(...)` は「X」に置き換える（中の式と、式の中の文字列は読まない）。
/// コメントの中の文字列と、`// ui-copy:ignore` を付けた行と、ログ・`print`・`fatalError` の行は返さない
struct CopyScanner {
    struct Literal: Hashable {
        let line: Int
        /// 補間を X にした中身
        let text: String
        /// 補間の式も含めた元の中身（エラーの埋め込みを見る）
        let raw: String
    }

    static let ignoreMarker = "ui-copy:ignore"
    static let ignoreFileMarker = "ui-copy:ignore-file"
    /// 画面に出ない行。リテラルがこの語を含む行にあれば読まない
    static let skippedCalls = ["logger.", "Logger(", "print(", "fatalError(", "preconditionFailure(", "precondition(", "assert(", "assertionFailure(", "FileHandle.standardError"]

    static func literals(in source: String) -> [Literal] {
        if source.contains(ignoreFileMarker) { return [] }
        let lines = source.components(separatedBy: "\n")
        let skipped = Set(lines.indices.filter { index in
            let line = lines[index]
            return line.contains(ignoreMarker) || skippedCalls.contains { line.contains($0) }
        }.map { $0 + 1 })
        var scanner = Cursor(Array(source))
        var found: [Literal] = []
        while let token = scanner.next() {
            if !skipped.contains(token.line) { found.append(token) }
        }
        return found
    }

    /// 1 文字ずつ読む。コメント、文字列、補間の入れ子を数える
    private struct Cursor {
        let chars: [Character]
        var index = 0
        var line = 1

        init(_ chars: [Character]) { self.chars = chars }

        func peek(_ offset: Int = 0) -> Character? {
            let i = index + offset
            return i < chars.count ? chars[i] : nil
        }

        mutating func advance() -> Character? {
            guard index < chars.count else { return nil }
            let c = chars[index]
            index += 1
            if c == "\n" { line += 1 }
            return c
        }

        func starts(with s: String) -> Bool {
            for (offset, c) in s.enumerated() where peek(offset) != c { return false }
            return true
        }

        /// 次のリテラルまで読み進めて返す
        mutating func next() -> Literal? {
            while let c = peek() {
                if starts(with: "//") {
                    while let d = peek(), d != "\n" { _ = advance() }
                } else if starts(with: "/*") {
                    skipBlockComment()
                } else if c == "#" && peek(1) == "\"" {
                    // 生の文字列 #"..."#。中身は読むが補間は無い
                    _ = advance()
                    return readString(raw: true)
                } else if c == "\"" {
                    return readString(raw: false)
                } else {
                    _ = advance()
                }
            }
            return nil
        }

        mutating func skipBlockComment() {
            _ = advance(); _ = advance()
            var depth = 1
            while depth > 0, peek() != nil {
                if starts(with: "/*") { _ = advance(); _ = advance(); depth += 1 }
                else if starts(with: "*/") { _ = advance(); _ = advance(); depth -= 1 }
                else { _ = advance() }
            }
        }

        /// 開きの `"` か `"""` の位置から読む
        mutating func readString(raw: Bool) -> Literal {
            let startLine = line
            let multiline = starts(with: "\"\"\"")
            if multiline { _ = advance(); _ = advance(); _ = advance() } else { _ = advance() }
            var text = ""
            var rawText = ""
            while let c = peek() {
                if multiline ? starts(with: "\"\"\"") : c == "\"" {
                    if multiline { _ = advance(); _ = advance(); _ = advance() } else { _ = advance() }
                    if raw { while peek() == "#" { _ = advance() } }
                    break
                }
                if !multiline && c == "\n" { break }
                if c == "\\" && !raw {
                    _ = advance()
                    if peek() == "(" {
                        let expression = readInterpolation()
                        text += "X"
                        rawText += "\\(" + expression + ")"
                    } else if let escaped = advance() {
                        let value: String = switch escaped {
                        case "n": "\n"
                        case "t": "\t"
                        default: String(escaped)
                        }
                        text += value
                        rawText += value
                    }
                    continue
                }
                text.append(c)
                rawText.append(c)
                _ = advance()
            }
            let body = multiline ? text.trimmingCharacters(in: .newlines) : text
            return Literal(line: startLine, text: body, raw: rawText)
        }

        /// `(` の位置から、対応する `)` までを読む。中の文字列も読み飛ばす
        mutating func readInterpolation() -> String {
            _ = advance()
            var depth = 1
            var expression = ""
            while depth > 0, let c = peek() {
                if c == "\"" {
                    let inner = readString(raw: false)
                    expression += "\"" + inner.raw + "\""
                    continue
                }
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { _ = advance(); break } }
                expression.append(c)
                _ = advance()
            }
            return expression
        }
    }
}
