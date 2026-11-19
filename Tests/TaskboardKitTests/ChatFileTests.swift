import Foundation
import Testing

@testable import TaskboardKit

@Suite("チャットのファイルの diff")
struct ChatFileTests {
    private let hunks = [
        ChatDiffHunk(oldStart: 3, oldLines: 3, newStart: 3, newLines: 4, lines: [" let a = 1", "-let b = 2", "+let b = 3", "+let c = 4", " let d = 5"]),
        ChatDiffHunk(oldStart: 10, oldLines: 1, newStart: 11, newLines: 1, lines: ["-日本語の行", "+直した日本語の行"]),
    ]

    @Test("unified diff の文に書いて読み戻すと元の hunk になる。足した・消した行を数える")
    func roundTrip() {
        let text = ChatDiffHunk.unified(hunks)
        #expect(text == "@@ -3,3 +3,4 @@\n let a = 1\n-let b = 2\n+let b = 3\n+let c = 4\n let d = 5\n@@ -10,1 +11,1 @@\n-日本語の行\n+直した日本語の行")
        #expect(ChatDiffHunk.parse(unified: text) == hunks)
        #expect(hunks.map(\.added) == [2, 1] && hunks.map(\.removed) == [1, 1])
        #expect(ChatDiffHunk.unified([]) == "" && ChatDiffHunk.parse(unified: "").isEmpty)
    }

    @Test("ファイルの見出しと数を省いた @@ を読む。@@ より前の行と、印の無い行は読み飛ばす")
    func parseVariants() {
        let text = "--- a/x\n+++ b/x\n@@ -3 +3 @@ func f()\n-old\n+new\n\\ No newline at end of file\n@@ -0,0 +1,2 @@\n+a\n+b"
        #expect(ChatDiffHunk.parse(unified: text) == [
            ChatDiffHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, lines: ["-old", "+new"]),
            ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ["+a", "+b"]),
        ])
        #expect(ChatDiffHunk.parse(unified: "@@ 壊れた見出し @@\n+x").isEmpty)
    }

    @Test("hunk の前と間の変わらない行を畳み、行番号を振る。変える前の全文が無ければ最後の hunk の後ろは出さない")
    func rowsWithoutOriginal() {
        let rows = ChatDiffRow.rows(hunks)
        #expect(rows.first == .gap(id: 0, oldStart: 1, newStart: 1, count: 2, lines: nil))
        #expect(rows[1] == .line(id: 1, change: .context, old: 3, new: 3, text: "let a = 1"))
        #expect(rows[2] == .line(id: 2, change: .removed, old: 4, new: nil, text: "let b = 2"))
        #expect(rows[4] == .line(id: 4, change: .added, old: nil, new: 5, text: "let c = 4"))
        #expect(rows[5] == .line(id: 5, change: .context, old: 5, new: 6, text: "let d = 5"))
        // 1 つ目の hunk は旧 3〜5 行、2 つ目は旧 10 行から。間は旧 6〜9 の 4 行
        #expect(rows[6] == .gap(id: 6, oldStart: 6, newStart: 7, count: 4, lines: nil))
        #expect(rows.last == .line(id: 8, change: .added, old: nil, new: 11, text: "直した日本語の行"))
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test("変える前の全文があれば、畳んだ行に中身を入れ、最後の hunk の後ろも畳む")
    func rowsWithOriginal() {
        let original = (1...12).map { "旧\($0)" }
        let rows = ChatDiffRow.rows(hunks, original: original)
        #expect(rows.first == .gap(id: 0, oldStart: 1, newStart: 1, count: 2, lines: ["旧1", "旧2"]))
        #expect(rows[6] == .gap(id: 6, oldStart: 6, newStart: 7, count: 4, lines: ["旧6", "旧7", "旧8", "旧9"]))
        #expect(rows.last == .gap(id: 9, oldStart: 11, newStart: 12, count: 2, lines: ["旧11", "旧12"]))
        // 全文が短い（ファイルが記録と違う）ときは中身を入れない
        #expect(ChatDiffRow.rows(hunks, original: ["旧1"]).first == .gap(id: 0, oldStart: 1, newStart: 1, count: 2, lines: nil))
    }

    @Test("空のファイルへの追加（oldStart 0）は前を畳まない。hunk が無ければ行も無い")
    func rowsEdges() {
        let rows = ChatDiffRow.rows([ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ["+a", "+b"])], original: [])
        #expect(rows == [.line(id: 0, change: .added, old: nil, new: 1, text: "a"), .line(id: 1, change: .added, old: nil, new: 2, text: "b")])
        #expect(ChatDiffRow.rows([], original: ["x"]).isEmpty)
    }

    @Test("書いた文の行の数。末尾の改行の後ろは数えず、空は 0")
    func lineCount() {
        #expect(ChatFile.lineCount(of: "") == 0)
        #expect(ChatFile.lineCount(of: "a") == 1)
        #expect(ChatFile.lineCount(of: "a\n") == 1)
        #expect(ChatFile.lineCount(of: "a\nb") == 2)
        #expect(ChatFile.lineCount(of: "日本語\n\n本文\n") == 3)
        #expect(ChatFile.lineCount(of: "\n") == 1)
    }

    @Test("ファイルの情報は JSON で行き来する。古い daemon の行（files が無い）も読める")
    func wire() throws {
        let file = ChatFile(path: "/repo/a.swift", action: .edited, hunks: hunks, added: 3, removed: 2, offset: 1_234)
        let message = ChatMessage(id: "u1#0", role: .user, kind: .toolResult, text: "ok", toolID: "t1", files: [file])
        let data = try WireJSON.encoder().encode(message)
        #expect(try WireJSON.decoder().decode(ChatMessage.self, from: data) == message)
        let old = #"{"id":"u1#0","role":"user","kind":"toolResult","text":"ok","toolID":"t1","isError":false}"#
        #expect(try WireJSON.decoder().decode(ChatMessage.self, from: Data(old.utf8)).files == nil)
    }

    @Test("人の発言の画像は JSON で行き来し、古い daemon の行（images が無い）は nil。画像の口に渡す行の uuid は id の「#位置」の前")
    func imagesWire() throws {
        let message = ChatMessage(
            id: "b4ca57af-c0f5-4e77-a412-a973f398d722#0", role: .user, kind: .text, text: "見て",
            images: [ChatImage(index: 0, mediaType: "image/png", bytes: 97, offset: 512), ChatImage(index: 1, offset: 512)])
        #expect(try WireJSON.decoder().decode(ChatMessage.self, from: WireJSON.encoder().encode(message)) == message)
        let old = #"{"id":"u1","role":"user","kind":"text","text":"見て","isError":false}"#
        #expect(try WireJSON.decoder().decode(ChatMessage.self, from: Data(old.utf8)).images == nil)
        #expect(message.lineID == "b4ca57af-c0f5-4e77-a412-a973f398d722")
        #expect(ChatMessage(id: "u1", role: .user, kind: .text, text: "").lineID == "u1")
    }
}
