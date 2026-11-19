import Foundation
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

@Suite struct MarkdownBlocksTests {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    private func paragraphs(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.compactMap { if case .paragraph(let text) = $0 { plain(text) } else { nil } }
    }

    /// 文字列の中で `piece` に当たる部分の行内の書式
    private func intent(of piece: String, in text: AttributedString) -> InlinePresentationIntent? {
        guard let range = text.range(of: piece) else { return nil }
        return text[range].runs.first?.inlinePresentationIntent
    }

    private func settledEnd(_ text: String) -> String.Index {
        var scan = MarkdownBlocks.SettledScan()
        scan.advance(to: text)
        return text.utf8.index(text.startIndex, offsetBy: scan.breaks.last ?? 0)
    }

    private func chunks(_ text: String, streaming: Bool) -> (settled: [String], tail: String?) {
        var chunks = ChatMarkdownChunks()
        return chunks.update(text, streaming: streaming)
    }

    @Test("生成中の文は、コードの塊の外の最後の空行までを書き終えた分とする")
    func settledEnd() {
        func settled(_ text: String) -> String { String(text[..<settledEnd(text)]) }
        #expect(settled("") == "")
        #expect(settled("書きかけ") == "")
        #expect(settled("一つ目の段落。\n\n二つ目の書きかけ") == "一つ目の段落。\n\n")
        #expect(settled("一つ目。\n\n二つ目。\n\n") == "一つ目。\n\n二つ目。\n\n")
        // コードの塊の中の空行では切らない
        #expect(settled("前の段落。\n\n```swift\nlet a = 1\n\nlet b = 2") == "前の段落。\n\n")
        #expect(settled("```\ncode\n```\n\nthe tail https://example.com") == "```\ncode\n```\n\n")
        #expect(settled("~~~\na\n\nb\n~~~\n\n続き") == "~~~\na\n\nb\n~~~\n\n")
    }

    @Test("生成中の文は、書き終えた段落と書きかけの段落を分けて解析しても、全体を解析したのと同じブロックになる")
    func streamingMatchesParse() {
        let text = "調べた結果です。**変更した所**は 2 つ。\n\n- 一つ目\n- 二つ目\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\n詳しくは https://example.com を見てください"
        let end = settledEnd(text)
        #expect(MarkdownBlocks.parse(String(text[..<end])) + MarkdownBlocks.parse(String(text[end...])) == MarkdownBlocks.parse(text))
    }

    @Test(
        "囲みは開いたときと同じ文字で、同じ長さ以上の行で閉じる。字下げが 4 つ以上の行は囲みにしない。どれも分けて解析しても全体と同じ",
        arguments: [
            "前。\n\n```\na\n~~~\n\nb\n```\n\n後の書きかけ",
            "前。\n\n~~~\na\n```\n\nb\n~~~\n\n後の書きかけ",
            "前。\n\n````\na\n```\n\nb\n````\n\n後の書きかけ",
            "前。\n\n```swift\na\n```swift\n\nb\n```\n\n後の書きかけ",
            "前。\n\n    ```\n\n段落。\n\n後の書きかけ",
            "前。\n\n   ```\na\n\nb\n   ```\n\n後の書きかけ",
        ])
    func fencesMatchParse(text: String) {
        let end = settledEnd(text)
        #expect(MarkdownBlocks.parse(String(text[..<end])) + MarkdownBlocks.parse(String(text[end...])) == MarkdownBlocks.parse(text))
        #expect(text[end...].hasSuffix("後の書きかけ") && end > text.startIndex)
    }

    @Test("チャットの本文は空行ごとの塊に分け、続く空行は 1 つの区切りにし、生成中は最後の区切りの後ろを書きかけにする")
    func chatChunks() {
        let text = "一つ目。\n\n\n二つ目。\n\n```\na\n\nb\n```\n\n三つ目の書きかけ"
        let streaming = chunks(text, streaming: true)
        #expect(streaming.settled == ["一つ目。\n\n\n", "二つ目。\n\n", "```\na\n\nb\n```\n\n"])
        #expect(streaming.tail == "三つ目の書きかけ")
        let finished = chunks(text, streaming: false)
        #expect(finished.settled.last == "三つ目の書きかけ")
        #expect(finished.tail == nil)
        // 塊ごとに解析しても全体と同じブロックになる
        #expect(finished.settled.flatMap { MarkdownBlocks.parse($0) } == MarkdownBlocks.parse(text))
        #expect(chunks("\n\n", streaming: true).settled.isEmpty)
        #expect(chunks("", streaming: false) == ([], nil))
    }

    @Test("差分を足すたびに続きから数えても、毎回初めから数えたのと同じ塊になる（コードの塊、続く空行、空白だけの行、CRLF、日本語と英語）。前の続きでない文に替わったら初めから数える")
    func chatChunksResume() {
        let text = "調べた結果です。\n\n\n- 一つ目\n- two\n \n\t\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nCRLF の行\r\n\r\n~~~\n~~~~\n\n~~~\n\nThe end of 終わり。\n\n"
        let characters = Array(text)
        for step in [1, 2, 3, 7] {
            var resumed = ChatMarkdownChunks()
            var end = 0
            while end < characters.count {
                end = min(end + step, characters.count)
                let prefix = String(characters[..<end])
                for streaming in [true, false] {
                    var fresh = ChatMarkdownChunks()
                    let expected = fresh.update(prefix, streaming: streaming)
                    let actual = resumed.update(prefix, streaming: streaming)
                    #expect(actual.settled == expected.settled && actual.tail == expected.tail, "step \(step) end \(end)")
                }
            }
        }
        // 頭が替わった文（生成中の block が別の返答に使われたなど）
        var chunks = ChatMarkdownChunks()
        _ = chunks.update("前の返答。\n\n続き", streaming: true)
        let replaced = chunks.update("別の返答。\n\n", streaming: true)
        #expect(replaced.settled == ["別の返答。\n\n"] && replaced.tail == nil)
        let shorter = chunks.update("別", streaming: true)
        #expect(shorter.settled.isEmpty && shorter.tail == "別")
    }

    @Test("空と空白だけはブロックを作らない")
    func empty() {
        #expect(MarkdownBlocks.parse("").isEmpty)
        #expect(MarkdownBlocks.parse("\n\n  \n").isEmpty)
    }

    @Test("CJK と ASCII の混じった段落で、強調とコードとリンクを行内の書式にする")
    func inlineCJKAndASCII() throws {
        let blocks = MarkdownBlocks.parse("日本語と **bold** と `code` と *斜体* と ~~消し~~ と [リンク](https://example.com)")
        try #require(blocks.count == 1)
        guard case .paragraph(let text) = blocks[0] else { Issue.record("段落にならない: \(blocks)"); return }
        #expect(plain(text) == "日本語と bold と code と 斜体 と 消し と リンク")
        #expect(intent(of: "bold", in: text) == .stronglyEmphasized)
        #expect(intent(of: "code", in: text) == .code)
        #expect(intent(of: "斜体", in: text) == .emphasized)
        #expect(intent(of: "消し", in: text) == .strikethrough)
        #expect(intent(of: "日本語", in: text) == nil)
        let link = try #require(text.range(of: "リンク"))
        #expect(text[link].runs.first?.link == URL(string: "https://example.com"))
    }

    @Test("素の URL もリンクにする（日本語の文の中でも）。コードとリンクの中の URL はそのまま")
    func bareURL() throws {
        let blocks = MarkdownBlocks.parse("PR は https://github.com/o/r/pull/41 です。`https://example.com/code` と [資料](https://example.com/doc) も")
        guard case .paragraph(let text) = try #require(blocks.first) else { Issue.record("段落にならない"); return }
        #expect(plain(text) == "PR は https://github.com/o/r/pull/41 です。https://example.com/code と 資料 も")
        let pr = try #require(text.range(of: "https://github.com/o/r/pull/41"))
        #expect(text[pr].runs.first?.link == URL(string: "https://github.com/o/r/pull/41"))
        #expect(text[pr].runs.count == 1)
        let code = try #require(text.range(of: "https://example.com/code"))
        #expect(text[code].runs.first?.link == nil)
        #expect(text[code].runs.first?.inlinePresentationIntent == .code)
        let doc = try #require(text.range(of: "資料"))
        #expect(text[doc].runs.first?.link == URL(string: "https://example.com/doc"))
        let before = try #require(text.range(of: "PR は "))
        #expect(text[before].runs.first?.link == nil)
    }

    @Test("URL の切り出し: 空・URL だけ・http 以外（メール・ファイル）")
    func linkSegments() {
        #expect(MarkdownBlocks.linkSegments("").map(\.text) == [""])
        let only = MarkdownBlocks.linkSegments("http://localhost:5790/state")
        #expect(only.map(\.text) == ["http://localhost:5790/state"])
        #expect(only.first?.url == URL(string: "http://localhost:5790/state"))
        #expect(MarkdownBlocks.linkSegments("連絡は a@example.com まで").allSatisfy { $0.url == nil })
        #expect(MarkdownBlocks.linkSegments("file:///Users/u/a.txt を開く").allSatisfy { $0.url == nil })
        // 空白を挟まずに日本語が続いても、括弧で囲んでも、URL だけを切り出す（NSDataDetector の切り方。JXA で確かめた値）
        #expect(MarkdownBlocks.linkSegments("https://github.com/o/r/pull/41を見て").map(\.text) == ["https://github.com/o/r/pull/41", "を見て"])
        #expect(MarkdownBlocks.linkSegments("「https://example.com/a」").map(\.text) == ["「", "https://example.com/a", "」"])
    }

    @Test("リンクの開き先: http・https・mailto はブラウザ、taskboard はアプリの中、ファイルと相対パスは開かない")
    func linkDestination() throws {
        #expect(LinkDestination(try #require(URL(string: "https://github.com/o/r/pull/41"))) == .browser)
        #expect(LinkDestination(try #require(URL(string: "HTTP://example.com"))) == .browser)
        #expect(LinkDestination(try #require(URL(string: "mailto:a@example.com"))) == .browser)
        #expect(LinkDestination(try #require(URL(string: "taskboard://task/fixture-studio/131"))) == .app)
        #expect(LinkDestination(URL(fileURLWithPath: "/Users/u/a.txt")) == .ignore)
        #expect(LinkDestination(try #require(URL(string: "docs/ui-copy.md"))) == .ignore)
    }

    @Test("強調の入れ子は書式を重ねる")
    func nestedEmphasis() throws {
        guard case .paragraph(let text) = try #require(MarkdownBlocks.parse("**太字の中の `code`**").first) else { Issue.record("段落にならない"); return }
        #expect(intent(of: "code", in: text) == [.stronglyEmphasized, .code])
    }

    @Test("段落の中の改行はそのまま残し、引用符やダッシュは書き換えない")
    func softBreakAndNoSmartPunctuation() {
        #expect(paragraphs(MarkdownBlocks.parse("1 行目\n2 行目")) == ["1 行目\n2 行目"])
        #expect(paragraphs(MarkdownBlocks.parse("\"quoted\" -- 'single'")) == ["\"quoted\" -- 'single'"])
    }

    @Test("見出しは # 1〜6 個。7 個は段落")
    func headings() {
        let blocks = MarkdownBlocks.parse("# 一\n## Two\n###### 六\n####### 七")
        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading(level: 1, AttributedString("一")))
        #expect(blocks[1] == .heading(level: 2, AttributedString("Two")))
        #expect(blocks[2] == .heading(level: 6, AttributedString("六")))
        #expect(paragraphs([blocks[3]]) == ["####### 七"])
    }

    @Test("``` と ~~~ のコードの塊。言語名は捨て、中身は Markdown として読まない")
    func fencedCode() {
        #expect(MarkdownBlocks.parse("```swift\nlet a = \"**x**\"\n```") == [.code("let a = \"**x**\"", language: "swift")])
        #expect(MarkdownBlocks.parse("~~~\n日本語の行\n  字下げ\n~~~") == [.code("日本語の行\n  字下げ")])
        // 言語は info string の先頭の語を小文字で持つ
        #expect(MarkdownBlocks.parse("```Bash title=run.sh\nls\n```") == [.code("ls", language: "bash")])
        #expect(MarkdownBlocks.parse("```日本語\n行\n```") == [.code("行", language: "日本語")])
    }

    @Test("diff の塊の行は、hunk の中の + と − を足した行と消した行、--- と +++ は hunk の前でだけ見出しにする")
    func diffLines() {
        #expect(DiffCode.isDiff("diff") && DiffCode.isDiff("patch") && !DiffCode.isDiff("swift") && !DiffCode.isDiff(nil))
        let git = """
            diff --git a/a.sql b/a.sql
            index 1a2b..3c4d 100644
            --- a/a.sql
            +++ b/a.sql
            @@ -1,3 +1,3 @@ 関数
             select 1;
            --- 古い注記
            +-- 新しい注記
            -日本語の行
            \\ No newline at end of file

            diff --git a/b b/b
            --- a/b
            """
        #expect(DiffCode.kinds(git) == [
            .header, .header, .header, .header, .hunk, .context, .removed, .added, .removed, .header, .context, .header, .header,
        ])
        // hunk の無い短い差分（返答に多い）も + と − で分ける
        #expect(DiffCode.kinds("- old\n+ new\n  same") == [.removed, .added, .context])
        #expect(DiffCode.kinds("") == [.context])
        #expect(DiffCode.kinds("+\n-") == [.added, .removed])
    }

    @Test("文書の HTML の diff の塊は行を種類の span で包み、文字の並びは変えない。ほかの言語の塊はそのまま")
    func diffHTML() {
        let html = #"<p>前</p><pre><code class="language-diff">@@ -1 +1 @@\#n-&lt;a&gt;\#n+新しい\#n</code></pre><pre><code class="language-swift">-x\#n</code></pre>"#
        let wrapped = DiffCode.html(html)
        #expect(wrapped == #"<p>前</p><pre><code class="language-diff"><span class="tb-diff-hunk">@@ -1 +1 @@\#n</span><span class="tb-diff-removed"><span class="tb-sign">-</span>&lt;a&gt;\#n</span><span class="tb-diff-added"><span class="tb-sign">+</span>新しい\#n</span></code></pre><pre><code class="language-swift">-x\#n</code></pre>"#)
        #expect(wrapped.replacingOccurrences(of: #"<span class="tb-[a-z-]+">|</span>"#, with: "", options: .regularExpression) == html)
        #expect(DiffCode.html("") == "")
    }

    @Test("閉じていないコードの塊は、末尾までをコードにする（返答の書きかけ）")
    func unclosedFence() {
        #expect(MarkdownBlocks.parse("前置き\n\n```\nlet a = 1\n# 見出しではない") == [
            .paragraph(AttributedString("前置き")),
            .code("let a = 1\n# 見出しではない"),
        ])
        #expect(MarkdownBlocks.parse("```") == [.code("")])
    }

    @Test("入れ子の箇条書きは字下げで判定し、項目の中に子のリストを持つ")
    func nestedList() {
        let blocks = MarkdownBlocks.parse("- 親 a\n  - 子 b\n    - 孫 c\n- 親 d\n* 別のリスト")
        #expect(blocks == [
            .list(MarkdownList(start: nil, items: [
                .init(checked: nil, blocks: [
                    .paragraph(AttributedString("親 a")),
                    .list(MarkdownList(start: nil, items: [
                        .init(checked: nil, blocks: [
                            .paragraph(AttributedString("子 b")),
                            .list(MarkdownList(start: nil, items: [.init(checked: nil, blocks: [.paragraph(AttributedString("孫 c"))])])),
                        ]),
                    ])),
                ]),
                .init(checked: nil, blocks: [.paragraph(AttributedString("親 d"))]),
            ])),
            // 記号が変わると別のリスト（CommonMark）
            .list(MarkdownList(start: nil, items: [.init(checked: nil, blocks: [.paragraph(AttributedString("別のリスト"))])])),
        ])
    }

    @Test("番号付きは開始番号を持ち、+ も箇条書きになる")
    func orderedAndPlus() {
        #expect(MarkdownBlocks.parse("3. 三\n4. 四") == [
            .list(MarkdownList(start: 3, items: [
                .init(checked: nil, blocks: [.paragraph(AttributedString("三"))]),
                .init(checked: nil, blocks: [.paragraph(AttributedString("四"))]),
            ])),
        ])
        #expect(MarkdownBlocks.parse("+ plus") == [.list(MarkdownList(start: nil, items: [.init(checked: nil, blocks: [.paragraph(AttributedString("plus"))])]))])
    }

    @Test("チェックボックスは済みと未完了を分ける")
    func checkboxes() {
        #expect(MarkdownBlocks.parse("- [ ] まだ\n- [x] 済み\n- 印なし") == [
            .list(MarkdownList(start: nil, items: [
                .init(checked: false, blocks: [.paragraph(AttributedString("まだ"))]),
                .init(checked: true, blocks: [.paragraph(AttributedString("済み"))]),
                .init(checked: nil, blocks: [.paragraph(AttributedString("印なし"))]),
            ])),
        ])
    }

    @Test("引用は中のブロックを持ち、水平線は単独のブロック")
    func quoteAndRule() {
        #expect(MarkdownBlocks.parse("> 引用 1\n>\n> - 中の項目\n\n---\n\n後") == [
            .quote([
                .paragraph(AttributedString("引用 1")),
                .list(MarkdownList(start: nil, items: [.init(checked: nil, blocks: [.paragraph(AttributedString("中の項目"))])])),
            ]),
            .rule,
            .paragraph(AttributedString("後")),
        ])
    }

    @Test("表は区切り行の揃えを読み、行内の書式を残す")
    func table() throws {
        let blocks = MarkdownBlocks.parse("| 名前 | 件数 | 状態 |\n|:---|---:|:---:|\n| **認証** | 12 | `ok` |")
        try #require(blocks.count == 1)
        guard case .table(let table) = blocks[0] else { Issue.record("表にならない: \(blocks)"); return }
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.header.map(plain) == ["名前", "件数", "状態"])
        #expect(table.rows.map { $0.map(plain) } == [["認証", "12", "ok"]])
        #expect(intent(of: "認証", in: table.rows[0][0]) == .stronglyEmphasized)
        #expect(intent(of: "ok", in: table.rows[0][2]) == .code)
    }

    @Test("列数の合わない行は、足りなければ空のセルで埋め、多ければ切る")
    func tableColumnMismatch() throws {
        guard case .table(let table) = try #require(MarkdownBlocks.parse("| a | b |\n|---|---|\n| 1 |\n| 1 | 2 | 3 |").first) else {
            Issue.record("表にならない"); return
        }
        #expect(table.alignments == [.leading, .leading])
        #expect(table.rows.map { $0.map(plain) } == [["1", ""], ["1", "2"]])
    }

    @Test("区切り行の列数が見出しと違うと表にならず、段落のまま")
    func tableHeaderMismatch() {
        #expect(paragraphs(MarkdownBlocks.parse("| a | b |\n|---|\n| 1 | 2 |")) == ["| a | b |\n|---|\n| 1 | 2 |"])
    }

    @Test("HTML は解釈せず、書かれた文字のまま出す")
    func html() {
        #expect(paragraphs(MarkdownBlocks.parse("<details>\n<summary>開く</summary>\n</details>")) == ["<details>\n<summary>開く</summary>\n</details>"])
        #expect(paragraphs(MarkdownBlocks.parse("a<br>b")) == ["a<br>b"])
    }

    @Test("PR の本文では、HTML のタグを外した文字で出す（コメントは消し、行を区切るタグは改行に）")
    func htmlAsText() {
        // dependabot の本文の形
        let dependabot = "Bumps lxml.\n\n<details>\n<summary>Changelog</summary>\n<p><em>Sourced from <a href=\"https://example.com\">lxml's changelog</a>.</em></p>\n<ul>\n<li>Bugs fixed</li>\n<li>A &amp; B &lt;c&gt;</li>\n</ul>\n</details>"
        #expect(paragraphs(MarkdownBlocks.parse(dependabot, html: .text)) == ["Bumps lxml.", "Changelog\nSourced from lxml's changelog.\n• Bugs fixed\n• A & B <c>"])
        // PR のテンプレートのコメントは何も残さない
        #expect(MarkdownBlocks.parse("<!--\n変更の概要を書く\n-->", html: .text).isEmpty)
        #expect(paragraphs(MarkdownBlocks.parse("## 概要\n<!-- 書き方 -->\n本文", html: .text)) == ["本文"])
        // 行内のタグは外し、改行のタグだけ改行に
        #expect(paragraphs(MarkdownBlocks.parse("a<br>b <kbd>⌘K</kbd> で開く", html: .text)) == ["a\nb ⌘K で開く"])
        // タグだけの段落は消える
        #expect(MarkdownBlocks.parse("<p align=\"center\"><img src=\"x.png\"></p>", html: .text).isEmpty)
        // コードの中の HTML はそのまま
        #expect(MarkdownBlocks.parse("```\n<div>x</div>\n```", html: .text) == [.code("<div>x</div>")])
        #expect(MarkdownBlocks.plainText(fromHTML: "<ul>\n<li>\n<p>GH#526: 修正</p>\n</li>\n</ul>") == "• GH#526: 修正")
        #expect(MarkdownBlocks.plainText(fromHTML: "") == "")
        #expect(MarkdownBlocks.plainText(fromHTML: "<!-- 閉じていない") == "")
    }

    @Test("畳む表示向けに、ブロックを改行区切りの 1 本にする")
    func flattened() {
        let text = MarkdownBlocks.flattened(MarkdownBlocks.parse("## 概要\n本文\n\n- 一\n  - 二\n1. 三\n- [x] 済み\n\n> 引用\n\n```\ncode\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |"))
        #expect(plain(text) == "概要\n本文\n• 一\n  • 二\n1. 三\n☑ 済み\n> 引用\ncode\na | b\n1 | 2")
        #expect(plain(MarkdownBlocks.flattened([])) == "")
    }
}

@Suite struct TextHighlightTests {
    @Test("大文字小文字を区別せず、一致をすべて塗る（CJK と ASCII）")
    func marksAll() {
        let marked = TextHighlight.mark("Swift と swift と SWIFT、検索と検索", "swift")
        #expect(marked.runs.filter { $0.backgroundColor != nil }.count == 3)
        let cjk = TextHighlight.mark("検索と検索", "検索")
        #expect(cjk.runs.filter { $0.backgroundColor != nil }.map { String(cjk[$0.range].characters) } == ["検索", "検索"])
    }

    @Test("空の語と一致なしは塗らない")
    func noMatch() {
        #expect(TextHighlight.mark("abc", "").runs.allSatisfy { $0.backgroundColor == nil })
        #expect(TextHighlight.mark("abc", nil).runs.allSatisfy { $0.backgroundColor == nil })
        #expect(TextHighlight.mark("abc", "x").runs.allSatisfy { $0.backgroundColor == nil })
    }
}

@Suite struct ChatSearchTests {
    private let messages = [
        ChatMessage(id: "u1", role: .user, kind: .text, text: "README を直して"),
        ChatMessage(id: "a1", role: .assistant, kind: .text, text: "readme を読む"),
        ChatMessage(id: "c1", role: .assistant, kind: .toolUse, text: "Read README.md", toolName: "Read", toolID: "t1"),
        ChatMessage(id: "r1", role: .user, kind: .toolResult, text: "# README\n本文", toolID: "t1"),
        ChatMessage(id: "a2", role: .assistant, kind: .text, text: "直した"),
    ]

    @Test("大文字小文字を区別せず、ツールの結果は呼び出しの行として 1 件に数える")
    func rows() {
        #expect(ChatSearch.rows(in: messages, query: "readme") == ["u1", "a1", "c1"])
        #expect(ChatSearch.rows(in: messages, query: "本文") == ["c1"])
        #expect(ChatSearch.rows(in: messages, query: "直") == ["u1", "a2"])
        #expect(ChatSearch.rows(in: messages, query: "") == [])
    }

    @Test("ツール名でも一致する")
    func toolName() {
        #expect(ChatSearch.rows(in: messages, query: "read") == ["u1", "a1", "c1"])
    }

    @Test("最初は最新の一致を指し、前後へ送ると端で反対へ回る")
    func step() {
        var search = ChatSearch(isOpen: true, query: "readme")
        #expect(search.label(count: 3) == "3/3")
        #expect(search.currentRow(in: messages) == "c1")
        search.step(1, count: 3)
        #expect(search.label(count: 3) == "1/3")
        search.step(-1, count: 3)
        search.step(-1, count: 3)
        #expect(search.label(count: 3) == "2/3")
        #expect(search.currentRow(in: messages) == "a1")
    }

    @Test("一致が無いと「一致なし」、語が空なら件数を出さない")
    func label() {
        #expect(ChatSearch(isOpen: true, query: "存在しない").label(count: 0) == "一致なし")
        #expect(ChatSearch(isOpen: true, query: "").label(count: 0) == nil)
        var search = ChatSearch(isOpen: true, query: "x")
        search.step(1, count: 0)
        #expect(search.position == nil)
    }

    @Test("畳んだ中に一致があるかは、入力の全文と結果で見る")
    func inside() {
        #expect(ChatSearch.matchesInside(call: messages[2], result: messages[3], query: "本文"))
        #expect(!ChatSearch.matchesInside(call: messages[2], result: messages[3], query: "直した"))
    }
}
