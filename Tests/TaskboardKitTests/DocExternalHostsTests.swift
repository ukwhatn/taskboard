import Foundation
import TaskboardKit
import Testing

@Suite("文書の外部の資源のホスト")
struct DocExternalHostsTests {
    @Test("HTML の src・srcset・link の href・url()・@import からホストを集め、小文字にして重複を除いて並べる")
    func collectsFromHTML() {
        let html = """
            <html><head>
            <link rel="stylesheet" href="https://CDN.example.com/a.css">
            <style>@import "https://fonts.example.net/f.css"; body{background:url('https://img.example.org/bg.png')}</style>
            <script src="https://cdn.example.com/x.js"></script>
            </head><body>
            <img srcset="https://a.example.com/1x.png 1x, https://b.example.com/2x.png 2x">
            <div style="background-image: url(https://img.example.org/c.png)"></div>
            </body></html>
            """
        #expect(DocExternalHosts.hosts(in: html, format: .html) == ["a.example.com", "b.example.com", "cdn.example.com", "fonts.example.net", "img.example.org"])
    }

    @Test("リンク（a・area の href）と、https 以外（http・相対・data・//）は集めない")
    func skipsLinksAndOtherSchemes() {
        let html = """
            <a href="https://docs.example.com/">説明</a><area href="https://map.example.com/">
            <img src="http://plain.example.com/a.png"><img src="images/a.png"><img src="data:image/png;base64,AAAA">
            <img src="//proto.example.com/a.png"><link href="taskboard://task/x/1">
            """
        #expect(DocExternalHosts.hosts(in: html, format: .html).isEmpty)
    }

    @Test("markdown の画像（そのままと参照）、本文に書いた HTML を集め、コードの中とリンクは集めない")
    func collectsFromMarkdown() {
        let markdown = """
            # 画面の案
            ![図](https://img.example.com/a.png "題") と [説明](https://docs.example.com/)
            ![参照の図][fig]
            <img src="https://raw.example.org/b.png">
            `<img src="https://code.example.com/x.png">`
            ```html
            <link rel="stylesheet" href="https://fence.example.com/a.css">
            ```

            [fig]: https://ref.example.net/c.png
            [doc]: https://linkonly.example.net/
            """
        #expect(DocExternalHosts.hosts(in: markdown, format: .markdown) == ["img.example.com", "raw.example.org", "ref.example.net"])
    }

    @Test("外部の資源が無ければ空。日本語の本文と空の本文でも落ちない")
    func emptyCases() {
        #expect(DocExternalHosts.hosts(in: "", format: .markdown).isEmpty)
        #expect(DocExternalHosts.hosts(in: "# 計画\n日本語の本文です。<img src=\"画像.png\">", format: .markdown).isEmpty)
        #expect(DocExternalHosts.hosts(in: "<p>本文</p>", format: .html).isEmpty)
    }
}
