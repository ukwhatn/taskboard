import Foundation
import Testing

@testable import TaskboardKit

@Suite("差分の行のコメント")
struct DiffLineCommentTests {
    @Test("足した行と変わらない行は今の行番号、消した行は変える前の行番号で示す")
    func lines() {
        #expect(DiffLineComment.prompt(path: "Sources/a.swift", change: .added, old: nil, new: 12, text: "    let b = 3", comment: "定数にしてください\n")
            == "`Sources/a.swift` 12行目（`let b = 3`）：定数にしてください")
        #expect(DiffLineComment.prompt(path: "a.swift", change: .context, old: 3, new: 4, text: "let a = 1", comment: "ここも")
            == "`a.swift` 4行目（`let a = 1`）：ここも")
        #expect(DiffLineComment.prompt(path: "メモ.md", change: .removed, old: 7, new: nil, text: "日本語の行", comment: "消さないでください")
            == "`メモ.md` 変更前の7行目（消した行`日本語の行`）：消さないでください")
    }

    @Test("空の行は括弧を省き、長い行は切る。` を含む行は `` で囲む。行番号が無ければ path だけ")
    func edges() {
        #expect(DiffLineComment.prompt(path: "a.txt", change: .added, old: nil, new: 1, text: "  ", comment: "空行は要りません")
            == "`a.txt` 1行目：空行は要りません")
        let long = String(repeating: "あ", count: 200)
        #expect(DiffLineComment.prompt(path: "a.txt", change: .added, old: nil, new: 2, text: long, comment: "x")
            == "`a.txt` 2行目（`\(String(repeating: "あ", count: DiffLineComment.codeLimit))…`）：x")
        #expect(DiffLineComment.prompt(path: "a.md", change: .added, old: nil, new: 3, text: "use `x`", comment: "y")
            == "`a.md` 3行目（`` use `x` ``）：y")
        #expect(DiffLineComment.prompt(path: "a.md", change: .added, old: nil, new: 3, text: "``x``", comment: "y")
            == "`a.md` 3行目（``` ``x`` ```）：y")
        #expect(DiffLineComment.prompt(path: "a.txt", change: .removed, old: nil, new: nil, text: "", comment: "z") == "`a.txt`：z")
    }

    @Test("複数の行は範囲の行番号と diff の行を引き、1 行なら 1 行の形と同じ")
    func ranges() {
        typealias Line = DiffLineComment.Line
        let lines = [
            Line(change: .context, old: 10, new: 10, text: "func a() {"),
            Line(change: .removed, old: 11, new: nil, text: "    old()"),
            Line(change: .added, old: nil, new: 11, text: "    new()"),
        ]
        #expect(DiffLineComment.prompt(path: "a.swift", lines: lines, comment: "名前を直してください")
            == "`a.swift` 10〜11行目：\n```diff\n func a() {\n-    old()\n+    new()\n```\n名前を直してください")
        #expect(DiffLineComment.prompt(path: "a.swift", lines: [lines[2]], comment: "ここ")
            == DiffLineComment.prompt(path: "a.swift", change: .added, old: nil, new: 11, text: "    new()", comment: "ここ"))
        let removed = [Line(change: .removed, old: 7, new: nil, text: "日本語"), Line(change: .removed, old: 8, new: nil, text: "の行")]
        #expect(DiffLineComment.prompt(path: "メモ.md", lines: removed, comment: "残して")
            == "`メモ.md` 変更前の7〜8行目：\n```diff\n-日本語\n-の行\n```\n残して")
    }

    @Test("``` を含む行は ```` で囲み、多すぎる行は頭だけを引く")
    func rangeEdges() {
        typealias Line = DiffLineComment.Line
        let fenced = [Line(change: .added, old: nil, new: 1, text: "```swift"), Line(change: .added, old: nil, new: 2, text: "```")]
        #expect(DiffLineComment.prompt(path: "a.md", lines: fenced, comment: "x")
            == "`a.md` 1〜2行目：\n````diff\n+```swift\n+```\n````\nx")
        let many = (1...50).map { (number: Int) in Line(change: .added, old: nil, new: number, text: "l\(number)") }
        let prompt = DiffLineComment.prompt(path: "a.txt", lines: many, comment: "y")
        #expect(prompt.hasPrefix("`a.txt` 1〜50行目：\n```diff\n+l1\n"))
        #expect(prompt.hasSuffix("+l\(DiffLineComment.lineLimit)\n…\n```\ny"))
        #expect(DiffLineComment.prompt(path: "a.txt", lines: [], comment: "z") == "`a.txt`：z")
    }
}
