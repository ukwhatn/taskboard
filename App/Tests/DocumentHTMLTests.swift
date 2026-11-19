import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// markdown の文書を WKWebView に載せる HTML。書いた文字は文字として出し、Markdown の中に書いた HTML だけをタグにする
@MainActor
@Suite struct DocumentHTMLTests {
    private func body(_ markdown: String) -> String {
        let html = DocumentWebController.html(for: DocContent(docID: 1, rev: 1, format: .markdown, content: markdown), textSize: 14)
        let start = html.range(of: "<main>")!.upperBound
        let end = html.range(of: "</main>")!.lowerBound
        return String(html[start..<end])
    }

    @Test("文字・行内のコード・コードの塊・見出しの < > & は escape する（日本語と英語）")
    func escapesText() {
        #expect(body("1 < 2 && x > 0、日本語 a<b") == "<p>1 &lt; 2 &amp;&amp; x &gt; 0、日本語 a&lt;b</p>\n")
        #expect(body("`<br>` と `a&b`") == "<p><code>&lt;br&gt;</code> と <code>a&amp;b</code></p>\n")
        #expect(body("```\n<div>\"x\"</div>\n```") == "<pre><code>&lt;div&gt;&quot;x&quot;&lt;/div&gt;\n</code></pre>\n")
        #expect(body("# 見出し a<b") == "<h1>見出し a&lt;b</h1>\n")
    }

    @Test("リンクとイメージの属性の \" と & は escape する")
    func escapesAttributes() {
        #expect(body("[文](https://example.com/?a=1&b=\"2\")") == "<p><a href=\"https://example.com/?a=1&amp;b=&quot;2&quot;\">文</a></p>\n")
    }

    @Test("Markdown の中に書いた HTML はそのままタグにする。diff の塊の行は escape した文字を包む")
    func keepsHTML() {
        #expect(body("<details><summary>開く</summary></details>") == "<details><summary>開く</summary></details>\n")
        #expect(body("前 <kbd>⌘</kbd> 後") == "<p>前 <kbd>⌘</kbd> 後</p>\n")
        #expect(body("```diff\n-<a>\n```") == "<pre><code class=\"language-diff\"><span class=\"tb-diff-removed\"><span class=\"tb-sign\">-</span>&lt;a&gt;\n</span></code></pre>\n")
    }
}
