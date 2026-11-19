import Foundation
import Testing

@testable import TaskboardKit

@Suite("チャットの / の候補")
struct SlashCommandTests {
    private func command(_ name: String) -> SlashCommand { SlashCommand(name: name, description: "", kind: .skill, scope: .user) }

    private func typing(_ draft: String, cursor: Int? = nil) -> SlashTyping? {
        SlashTyping.find(in: draft, cursor: cursor.map { draft.index(draft.startIndex, offsetBy: $0) })
    }

    @Test("カーソルの手前の語が / で始まり、/ が文の頭か空白・改行の後にあれば候補を出す。空白・改行・2 つめの / が入ったら出さない")
    func findsTyping() {
        #expect(typing("/")?.name == "" && typing("/")?.leading == true)
        #expect(typing("/yo")?.name == "yo" && typing("/yo")?.leading == true)
        #expect(typing("この文を /yo")?.name == "yo" && typing("この文を /yo")?.leading == false)
        #expect(typing("1 行目\n/co")?.name == "co" && typing("1 行目\n/co")?.leading == false)
        #expect(typing("  /yo")?.leading == false, "頭の空白の後は文の頭として扱わない（Claude Code が組み込みとして読まない）")
        #expect(typing("/yomiyasu この文") == nil)
        #expect(typing("/yo\n") == nil)
        #expect(typing("/yo ") == nil)
        #expect(typing("/Users/me") == nil)
        #expect(typing("見て https://example.com/a") == nil)
        #expect(typing("a/b") == nil)
        #expect(typing("yo") == nil)
        #expect(typing("") == nil)
    }

    @Test("カーソルが文の途中なら、カーソルまでの打ちかけで引き、語の終わりまでを置き換える")
    func findsTypingAtCursor() throws {
        let draft = "/yomi と /pr を使う"
        #expect(typing(draft, cursor: 3)?.name == "yo" && typing(draft, cursor: 3)?.leading == true)
        #expect(typing(draft, cursor: 9)?.name == "", "/ の直後")
        #expect(typing(draft, cursor: 10)?.name == "p")
        #expect(typing(draft, cursor: 6) == nil, "カーソルの手前が空白")
        let completed = try #require(typing(draft, cursor: 10)).completing("pr-review", in: draft)
        #expect(completed.text == "/yomi と /pr-review を使う")
        #expect(completed.text[completed.cursor...] == "を使う", "後ろに空白があれば足さず、その空白の後にカーソルを置く")
    }

    @Test("選んだ名前と空白を入れ、前の文はそのまま残す")
    func completes() throws {
        let leading = try #require(typing("/yo")).completing("yomiyasu", in: "/yo")
        #expect(leading.text == "/yomiyasu " && leading.cursor == leading.text.endIndex)
        let middle = try #require(typing("この文を /yo")).completing("yomiyasu", in: "この文を /yo")
        #expect(middle.text == "この文を /yomiyasu " && middle.cursor == middle.text.endIndex)
        let bare = try #require(typing("/")).completing("commit", in: "/")
        #expect(bare.text == "/commit ")
    }

    @Test("頭が合うものを先に、途中に含むものを後に並べ、上限で切る。大文字と小文字は区別しない")
    func matching() {
        let all = ["commit", "create-draft-pr", "pr-comment", "pr-review", "yomiyasu", "self-review"].map(command)
        #expect(SlashCommand.matching("y", in: all).map(\.name) == ["yomiyasu"])
        #expect(SlashCommand.matching("PR", in: all).map(\.name) == ["pr-comment", "pr-review", "create-draft-pr"])
        #expect(SlashCommand.matching("review", in: all).map(\.name) == ["pr-review", "self-review"])
        #expect(SlashCommand.matching("", in: all, limit: 2).map(\.name) == ["commit", "create-draft-pr"])
        #expect(SlashCommand.matching("zzz", in: all).isEmpty)
        #expect(SlashCommand.matching("c", in: all, limit: 3).count == 3)
    }

    @Test("文の途中の / には、組み込みを出さない（Claude Code は文の頭に書いた組み込みしか動かさない）")
    func matchingMidText() {
        let all = [command("commit"), SlashCommand(name: "clear", description: "", kind: .builtin, scope: .builtin), SlashCommand(name: "pr", description: "", kind: .command, scope: .user)]
        #expect(SlashCommand.matching("c", in: all, leading: false).map(\.name) == ["commit"])
        #expect(SlashCommand.matching("", in: all, leading: false).map(\.name) == ["commit", "pr"])
        #expect(SlashCommand.matching("c", in: all).map(\.name) == ["commit", "clear"])
    }

    @Test("往復する。opensTerminal の付いた古い daemon の応答も読める")
    func wire() throws {
        let value = SlashCommand(name: "yomiyasu", description: "推敲", kind: .skill, scope: .project)
        #expect(try WireJSON.decoder().decode(SlashCommand.self, from: try WireJSON.encoder().encode(value)) == value)
        let old = #"{"name":"mcp","description":"MCP","kind":"builtin","scope":"builtin","opensTerminal":true}"#
        #expect(try WireJSON.decoder().decode(SlashCommand.self, from: Data(old.utf8)) == SlashCommand(name: "mcp", description: "MCP", kind: .builtin, scope: .builtin))
    }

    @Test("入力欄のカーソルが日本語の下書きより先を指していても落ちず、候補を出さない。下書きの中のカーソルはそのまま使う")
    func cursorAheadOfDraft() throws {
        // 入力欄の選択は入力欄の文の UTF-16 の位置で来る。候補を選んだ直後に下書きより 3 つ先を指していて、アプリが落ちた
        let draft = "これを /sk"
        let field = ("これを /skill-creator を使う" as NSString) as String
        #expect(SlashTyping.cursor(String.Index(utf16Offset: 10, in: field), in: draft) == nil)
        let end = try #require(SlashTyping.cursor(String.Index(utf16Offset: 7, in: field), in: draft))
        #expect(SlashTyping.find(in: draft, cursor: end)?.name == "sk")
        let ascii = "abc /sk"
        #expect(SlashTyping.cursor(ascii.endIndex, in: ascii) == ascii.endIndex)
        #expect(SlashTyping.cursor(ascii.endIndex, in: "abc /s") == nil)
    }
}
