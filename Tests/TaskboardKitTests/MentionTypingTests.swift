import Foundation
import Testing

@testable import TaskboardKit

@Suite("入力欄の @ のファイルの指定")
struct MentionTypingTests {
    private func typing(_ draft: String, cursor: Int? = nil) -> MentionTyping? {
        MentionTyping.find(in: draft, cursor: cursor.map { draft.index(draft.startIndex, offsetBy: $0) })
    }

    @Test("@ が文の頭か空白・改行の後にあり、カーソルまでに空白が無ければ候補を出す")
    func findsTyping() {
        #expect(typing("@")?.query == "")
        #expect(typing("@src/ap")?.query == "src/ap")
        #expect(typing("この @src/ap")?.query == "src/ap")
        #expect(typing("1 行目\n@ab")?.query == "ab")
        #expect(typing("見て @日本語/メ")?.query == "日本語/メ")
        #expect(typing("mail me@example.com") == nil, "語の途中の @")
        #expect(typing("@src/app.swift を") == nil, "空白の後ろにカーソル")
        #expect(typing("a @b ") == nil)
        #expect(typing("src") == nil)
        #expect(typing("") == nil)
    }

    @Test("長すぎる打ちかけは、パスの指定とは見ない")
    func longQuery() {
        #expect(typing("@" + String(repeating: "a", count: MentionTyping.maxQueryLength)) != nil)
        #expect(typing("@" + String(repeating: "a", count: MentionTyping.maxQueryLength + 1)) == nil)
        #expect(typing(String(repeating: "あ", count: 5_000)) == nil, "空白の無い長い文でも、後ろへ探し続けない")
    }

    @Test("カーソルが文の途中なら、カーソルまでの打ちかけで引き、語の終わりまでを置き換える")
    func findsTypingAtCursor() throws {
        let draft = "@src/app.swift と @doc を見る"
        #expect(typing(draft, cursor: 4)?.query == "src")
        #expect(typing(draft, cursor: 15) == nil, "カーソルの手前が空白")
        let completed = try #require(typing(draft, cursor: 4)).completing(WorkFile(path: "src/App.swift", isDirectory: false), in: draft)
        #expect(completed.text == "@src/App.swift と @doc を見る")
        #expect(completed.text[completed.cursor...] == "と @doc を見る", "後ろに空白があれば足さず、その後ろにカーソルを置く")
    }

    @Test("選んだパスと空白を入れ、前の文はそのまま残す")
    func completes() throws {
        let file = WorkFile(path: "src/App.swift", isDirectory: false)
        let leading = try #require(typing("@sr")).completing(file, in: "@sr")
        #expect(leading.text == "@src/App.swift " && leading.cursor == leading.text.endIndex)
        let middle = try #require(typing("この @sr")).completing(file, in: "この @sr")
        #expect(middle.text == "この @src/App.swift ")
    }

    @Test("空白を含むパスは引用符で囲む。フォルダは空白を足さず、続けて奥を選べる")
    func quotesAndFolders() throws {
        let spaced = WorkFile(path: "docs/My Notes.md", isDirectory: false)
        let quoted = try #require(typing("@no")).completing(spaced, in: "@no")
        #expect(quoted.text == "@\"docs/My Notes.md\" ")
        let folder = WorkFile(path: "src/views/", isDirectory: true)
        let folderResult = try #require(typing("@vi")).completing(folder, in: "@vi")
        #expect(folderResult.text == "@src/views/" && folderResult.cursor == folderResult.text.endIndex)
        #expect(MentionTyping.find(in: folderResult.text, cursor: folderResult.cursor)?.query == "src/views/")
    }

    @Test("ファイルの名前と親のフォルダ")
    func nameAndParent() {
        let file = WorkFile(path: "src/views/Row.swift", isDirectory: false)
        #expect(file.name == "Row.swift" && file.parent == "src/views/")
        let folder = WorkFile(path: "src/views/", isDirectory: true)
        #expect(folder.name == "views" && folder.parent == "src/")
        let top = WorkFile(path: "README.md", isDirectory: false)
        #expect(top.name == "README.md" && top.parent == "")
    }
}
