import Foundation
import TaskboardKit
import Testing

@Suite("文書の版の行ごとの差分")
struct LineDiffTests {
    @Test("変わった行の前後 3 行を残し、hunk の見出しに行の位置と数を書く")
    func unifiedWithContext() {
        let old = (1...10).map { "行\($0)" }.joined(separator: "\n")
        var lines = (1...10).map { "行\($0)" }
        lines[4] = "行5（直した）"
        lines.insert("足した行", at: 8)
        let diff = LineDiff.unified(old: old, new: lines.joined(separator: "\n"))
        #expect(diff == """
            @@ -2,9 +2,10 @@
             行2
             行3
             行4
            -行5
            +行5（直した）
             行6
             行7
             行8
            +足した行
             行9
             行10
            """)
    }

    @Test("離れた変更は別の hunk にする")
    func separateHunks() {
        let old = (1...20).map { "l\($0)" }
        var new = old
        new[0] = "first"
        new[19] = "last"
        let diff = LineDiff.unified(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"))
        #expect(diff.components(separatedBy: "\n").filter { $0.hasPrefix("@@") } == ["@@ -1,4 +1,4 @@", "@@ -17,4 +17,4 @@"])
    }

    @Test("同じ本文は空。空の版からの差分は全部が足した行")
    func edges() {
        #expect(LineDiff.unified(old: "# 計画\n本文", new: "# 計画\n本文").isEmpty)
        #expect(LineDiff.unified(old: "", new: "a\nb") == "@@ -0,0 +1,2 @@\n+a\n+b")
        #expect(LineDiff.unified(old: "a\nb", new: "") == "@@ -1,2 +0,0 @@\n-a\n-b")
    }
}
