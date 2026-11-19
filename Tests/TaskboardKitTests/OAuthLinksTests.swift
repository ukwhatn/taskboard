import Foundation
import Testing

@testable import TaskboardKit

@Suite("コネクタの認証の URL")
struct OAuthLinksTests {
    @Test("開いてよいのは https と、127.0.0.1・localhost の http だけ。userinfo つき・host なし・ほかの scheme は開かない")
    func openable() {
        for url in [
            "https://auth.example.com/authorize?client_id=a&state=b", "HTTPS://Auth.Example.com/authorize", "http://127.0.0.1:47821/authorize?x=1",
            "http://localhost:8080/a",
        ] {
            #expect(OAuthLinks.openable(url) != nil, "\(url)")
        }
        for url in [
            "", "http://example.com/authorize", "https://user:pw@auth.example.com/", "https://user@auth.example.com/", "file:///etc/passwd",
            "taskboard://open", "javascript:alert(1)", "https:///authorize", "http://127.0.0.2/authorize", "認証のページ",
        ] {
            #expect(OAuthLinks.openable(url) == nil, "\(url)")
        }
    }

    @Test("callback は 127.0.0.1・localhost の http で、state と（code か error）があるもの。前後の空白と改行は落とす")
    func callback() {
        #expect(OAuthLinks.callback("http://localhost:53123/callback?code=abc&state=xyz")?.absoluteString == "http://localhost:53123/callback?code=abc&state=xyz")
        #expect(OAuthLinks.callback("  http://127.0.0.1:53123/callback?state=xyz&code=abc\n")?.absoluteString == "http://127.0.0.1:53123/callback?state=xyz&code=abc")
        #expect(OAuthLinks.callback("http://localhost:53123/callback?error=access_denied&state=xyz") != nil)
        for url in [
            "", "https://localhost:53123/callback?code=a&state=b", "http://example.com/callback?code=a&state=b", "http://localhost:53123/callback?code=a",
            "http://localhost:53123/callback?state=b", "http://localhost:53123/callback?code=&state=b", "http://localhost:53123/callback?code=a&state=",
            "http://localhost:53123/callback?code=a&state=b#frag", "http://u@localhost:53123/callback?code=a&state=b",
            "http://u:p@127.0.0.1:53123/callback?code=a&state=b", "localhost:53123/callback?code=a&state=b", "認証の後のページ",
        ] {
            #expect(OAuthLinks.callback(url) == nil, "\(url)")
        }
    }

    @Test("callback は 4KB（UTF-8 のバイト数）まで")
    func callbackLimit() {
        let head = "http://localhost:1/callback?state=s&code="
        #expect(OAuthLinks.callback(head + String(repeating: "a", count: OAuthLinks.callbackLimit - head.utf8.count)) != nil)
        #expect(OAuthLinks.callback(head + String(repeating: "a", count: OAuthLinks.callbackLimit - head.utf8.count + 1)) == nil)
        #expect(OAuthLinks.callback(head + String(repeating: "あ", count: (OAuthLinks.callbackLimit - head.utf8.count) / 3 + 1)) == nil)
    }

    @Test("認証のページの redirect_uri と state から、戻りを待つアドレスと state を読む。loopback の http で port のあるものと、空でない state があるものだけ")
    func redirect() throws {
        let page = try #require(URL(string: "https://auth.example.com/authorize?client_id=a&redirect_uri=http%3A%2F%2Flocalhost%3A51508%2Fcallback&state=s1"))
        let redirect = try #require(OAuthLinks.redirect(of: page))
        #expect(redirect.address.absoluteString == "http://localhost:51508/callback" && redirect.state == "s1")
        for query in [
            "redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb&state=s", "redirect_uri=http%3A%2F%2Flocalhost%2Fcallback&state=s",
            "redirect_uri=http%3A%2F%2Fexample.com%3A80%2Fcb&state=s", "state=s", "redirect_uri=http%3A%2F%2Flocalhost%3A51508%2Fcallback",
            "redirect_uri=http%3A%2F%2Flocalhost%3A51508%2Fcallback&state=",
        ] {
            #expect(OAuthLinks.redirect(of: try #require(URL(string: "https://auth.example.com/authorize?\(query)"))) == nil, "\(query)")
        }
    }

    @Test("戻り先に届いた要求の target を、戻り先のアドレスの callback に組み直す。path が違う要求（favicon など）、state か code の無い要求、state が認証のページと違う要求（押し直す前のページの戻り）は受けない")
    func callbackFromRequest() throws {
        let redirect = OAuthRedirect(address: try #require(URL(string: "http://localhost:51508/callback")), state: "s1")
        #expect(OAuthLinks.callback(requestTarget: "/callback?code=c1&state=s1", redirect: redirect)?.absoluteString == "http://localhost:51508/callback?code=c1&state=s1")
        #expect(OAuthLinks.callback(requestTarget: "/callback?error=access_denied&state=s1", redirect: redirect) != nil)
        for target in [
            "/favicon.ico", "/callback", "/callback?code=c1", "/other?code=c1&state=s1", "http://evil.example/callback?code=c1&state=s1", "",
            "/callback?code=c0&state=s0", "/callback?code=c1&state=s1x", "/callback?code=c1&state=S1",
        ] {
            #expect(OAuthLinks.callback(requestTarget: target, redirect: redirect) == nil, "\(target)")
        }
    }
}
