import Foundation
import TaskboardKit
import Testing

@Suite("文書の本文の印（質問と送る文面の欄の位置）")
struct DocMarkersTests {
    @Test("markdown の HTML コメントと、HTML の data 属性の 4 形を、本文の順に読む")
    func readsAllForms() {
        let body = """
            # 計画
            前提の説明。
            <!-- ask: q1 -->
            文面の説明。
            <!--draft:slack-1-->
            <div data-ask="q2"></div>
            <div class="x" data-draft='mail.2'></div>
            """
        let markers = DocMarkers.markers(in: body, format: .markdown)
        #expect(markers == [.init(kind: .ask, id: "q1"), .init(kind: .draft, id: "slack-1"), .init(kind: .ask, id: "q2"), .init(kind: .draft, id: "mail.2")])
    }

    @Test("markdown のコードの中の印は読まない（印の書き方を説明する文書が断られないように）")
    func skipsCodeInMarkdown() {
        let body = """
            印は `<!-- ask: q9 -->` と書く。
            ```html
            <div data-draft="d9"></div>
            ```
            ~~~
            <!-- ask: q8 -->
            ~~~
            <!-- ask: q1 -->
            """
        #expect(DocMarkers.markers(in: body, format: .markdown) == [.init(kind: .ask, id: "q1")])
    }

    @Test("HTML の文書はコードの中を区別しない（escape された印は印の形にならない）")
    func htmlEscapedIsNotMarker() {
        let body = "<p><code>&lt;!-- ask: q9 --&gt;</code></p><div data-ask=\"q1\"></div>"
        #expect(DocMarkers.markers(in: body, format: .html) == [.init(kind: .ask, id: "q1")])
    }

    @Test("空の本文・印の無い本文・id の無い印は何も返さない。日本語の本文の中でも読む")
    func edges() {
        #expect(DocMarkers.markers(in: "", format: .markdown).isEmpty)
        #expect(DocMarkers.markers(in: "印なし", format: .html).isEmpty)
        #expect(DocMarkers.markers(in: "<!-- ask: -->", format: .markdown).isEmpty)
        #expect(DocMarkers.markers(in: "日本語の段落。<!-- draft: 返信 -->続き", format: .markdown).isEmpty, "id は英数字と ._- だけ")
        #expect(DocMarkers.markers(in: "日本語の段落。<!-- draft: r1 -->続き", format: .markdown) == [.init(kind: .draft, id: "r1")])
    }

    @Test("印を欄の置き場に置き換える。置き換えない印はそのまま残す")
    func replace() {
        let html = "<p>a</p><!-- ask: q1 --><p>b</p><div data-draft=\"d1\"></div>"
        let replaced = DocMarkers.replace(in: html) { marker in marker.id == "q1" ? "[\(marker.slot)]" : nil }
        #expect(replaced == "<p>a</p>[ask:q1]<p>b</p><div data-draft=\"d1\"></div>")
    }

    @Test("照合: 無い id と、同じ印の重複を理由つきで返す")
    func check() {
        let markers: [DocMarker] = [.init(kind: .ask, id: "q1"), .init(kind: .draft, id: "d1")]
        #expect(DocMarkers.problem(markers, questions: ["q1"], drafts: ["d1"]) == nil)
        #expect(DocMarkers.problem(markers, questions: ["q2"], drafts: ["d1"])?.contains("q1") == true)
        #expect(DocMarkers.problem(markers, questions: ["q1"], drafts: [])?.contains("d1") == true)
        #expect(DocMarkers.problem(markers + [.init(kind: .ask, id: "q1")], questions: ["q1"], drafts: ["d1"])?.contains("q1") == true)
    }
}
