import Foundation
import Testing
@testable import Taskboard

/// https のリンクを、入っているアプリの URL に書き換える
@Suite struct NativeAppLinkTests {
    private let teams = ["acme": "T0123", "bigcorp.enterprise": "E0456"]

    private func rewrite(_ string: String, installed: Set<String> = ["com.hnc.Discord", "com.tinyspeck.slackmacgap", "notion.id", "us.zoom.xos", "com.microsoft.teams2"]) -> String? {
        NativeAppLink.rewrite(URL(string: string)!, isInstalled: { installed.contains($0) }, slackTeams: { teams })?.absoluteString
    }

    @Test("Discord のチャンネルと招待は discord:// に。アプリが無ければ書き換えない")
    func discord() {
        #expect(rewrite("https://discord.com/channels/410454762522411009/1554051425229606962") == "discord://-/channels/410454762522411009/1554051425229606962")
        #expect(rewrite("https://discord.gg/abcDEF") == "discord://-/invite/abcDEF")
        #expect(rewrite("https://discord.com/channels/1/2", installed: []) == nil)
        // チャンネル以外（ブログ・規約）はブラウザで開く
        #expect(rewrite("https://discord.com/blog/hello") == nil)
    }

    @Test("Slack の permalink は team ID を引いて slack://channel に。メッセージの時刻は小数点を入れる")
    func slack() {
        #expect(rewrite("https://acme.slack.com/archives/C024BE91L/p1700000000123456") == "slack://channel?team=T0123&id=C024BE91L&message=1700000000.123456")
        #expect(rewrite("https://acme.slack.com/archives/C024BE91L") == "slack://channel?team=T0123&id=C024BE91L")
        #expect(rewrite("https://bigcorp.enterprise.slack.com/archives/C1/p1700000000000001") == "slack://channel?team=E0456&id=C1&message=1700000000.000001")
        #expect(rewrite("https://acme.slack.com/team/U12345") == "slack://user?team=T0123&id=U12345")
        // 手元の Slack が知らないワークスペースはブラウザで開く
        #expect(rewrite("https://other.slack.com/archives/C1") == nil)
    }

    @Test("permalink の時刻の形でないものは時刻にしない")
    func messageTimestamp() {
        #expect(NativeAppLink.messageTimestamp("p1700000000123456") == "1700000000.123456")
        #expect(NativeAppLink.messageTimestamp("p123") == nil)
        #expect(NativeAppLink.messageTimestamp("1700000000123456") == nil)
        #expect(NativeAppLink.messageTimestamp("p17000000001234あ6") == nil)
    }

    @Test("Notion・Teams は scheme だけ替え、Zoom は会議の番号とパスコードを渡す")
    func others() {
        #expect(rewrite("https://www.notion.so/acme/Page-0123abcd") == "notion://www.notion.so/acme/Page-0123abcd")
        #expect(rewrite("https://teams.microsoft.com/l/meetup-join/xyz") == "msteams://teams.microsoft.com/l/meetup-join/xyz")
        #expect(rewrite("https://acme.zoom.us/j/123456789?pwd=abc") == "zoommtg://acme.zoom.us/join?action=join&confno=123456789&pwd=abc")
        #expect(rewrite("https://zoom.us/pricing") == nil)
    }

    @Test("http・https 以外と、知らないサービスは書き換えない")
    func untouched() {
        #expect(rewrite("mailto:a@example.com") == nil)
        #expect(rewrite("https://github.com/ukwhatn/taskboard") == nil)
        #expect(rewrite("https://example.com/discord.com/channels/1/2") == nil)
    }

    #if os(macOS)
    @Test("Slack の root-state.json から、ドメインと Enterprise の org のドメインで team ID を引く")
    func slackTeams() {
        let json = #"{"workspaces":{"E1":{"domain":"bigcorp","id":"E1","url":"https://bigcorp.enterprise.slack.com/"},"T2":{"domain":"acme","id":"T2","url":"https://acme.slack.com/"},"bad":"x"}}"#
        let teams = SlackTeams.parse(Data(json.utf8))
        #expect(teams["bigcorp.enterprise"] == "E1")
        #expect(teams["acme"] == "T2")
        #expect(SlackTeams.parse(Data("{".utf8)).isEmpty)
    }
    #endif

    @Test("アプリの外で開くのは http・https・mailto と、受け持つアプリのある scheme。file・javascript・data は開かない")
    func externalSchemes() {
        let handled: (URL) -> Bool = { ["discord", "slack"].contains($0.scheme ?? "") }
        #expect(ExternalLinks.isExternal(URL(string: "discord://discord.com/channels/410454762522411009/1551792539466735618")!, hasHandler: handled))
        #expect(ExternalLinks.isExternal(URL(string: "slack://channel?team=T1&id=C1")!, hasHandler: handled))
        #expect(ExternalLinks.isExternal(URL(string: "https://example.com")!, hasHandler: { _ in false }))
        #expect(!ExternalLinks.isExternal(URL(string: "zoommtg://zoom.us/join")!, hasHandler: handled))
        for refused in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,x", "taskboard://task/m/1"] {
            #expect(!ExternalLinks.isExternal(URL(string: refused)!, hasHandler: { _ in true }), "\(refused)")
        }
    }

    @Test("文書の中で押したリンクはチャットと同じ開き先。taskboard:// はアプリの中、ファイルは開かない。押していない遷移（script・meta refresh・iframe）は開かない")
    func documentLinks() {
        #expect(DocumentWebController.destination(of: URL(string: "taskboard://task/m/12")!, pressed: true) == .app)
        #expect(DocumentWebController.destination(of: URL(string: "https://example.com")!, pressed: true) == .browser)
        #expect(DocumentWebController.destination(of: URL(string: "file:///etc/hosts")!, pressed: true) == .ignore)
        #expect(DocumentWebController.destination(of: URL(string: "javascript:alert(1)")!, pressed: true) == .ignore)
        #expect(DocumentWebController.destination(of: URL(string: "taskboard://task/m/12")!, pressed: false) == .ignore)
        #expect(DocumentWebController.destination(of: URL(string: "https://example.com")!, pressed: false) == .ignore)
    }
}
