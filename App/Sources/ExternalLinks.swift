import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// アプリの外へ出るリンク（http・https・mailto と、アプリが受け持つ scheme）の開き先。Mac は、そのサービスのアプリが入っていれば
/// アプリの URL scheme に書き換えて開く（Slack・Discord などの Electron のアプリは https のリンクを引き受けず、ブラウザで開くと
/// 「アプリで開く」のページを 1 枚挟む）。iPhone・iPad は universal link が同じことをするので、そのまま渡す
enum ExternalLinks {
    /// 開くとこの端末の中身に触れるか、ページの中で動く scheme。文書やチャットに置かれていても開かない
    static let refusedSchemes: Set<String> = ["file", "javascript", "data", "blob", "about", "vbscript", "taskboard"]

    /// アプリの外で開くリンクか。http・https・mailto と、入っているアプリが受け持つ scheme（`discord:`・`slack:` など）
    static func isExternal(_ url: URL) -> Bool {
        isExternal(url, hasHandler: hasHandler)
    }

    static func isExternal(_ url: URL, hasHandler: (URL) -> Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !refusedSchemes.contains(scheme) else { return false }
        return ["http", "https", "mailto"].contains(scheme) || hasHandler(url)
    }

    private static func hasHandler(_ url: URL) -> Bool {
        #if os(macOS)
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        #else
        // iOS は Info.plist に並べた scheme しか聞けない。開けなければ OS が何もしないので、開こうとしてよい
        true
        #endif
    }

    /// アプリへ書き換えずにブラウザで開く（認証のページ。アプリで開くと、認証の後の戻り先に届かない）
    static func openInBrowser(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
        let target = NativeAppLink.rewrite(url, isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }, slackTeams: SlackTeams.load) ?? url
        NSWorkspace.shared.open(target)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

extension View {
    /// この中の `Link`・`openURL` のアプリの外へのリンクを `ExternalLinks` で開く
    func externalLinks() -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard ExternalLinks.isExternal(url) else { return .systemAction }
            ExternalLinks.open(url)
            return .handled
        })
    }
}

/// https のリンクを、そのサービスのアプリの URL に書き換える。アプリが無いか、書き換えられない形なら nil
enum NativeAppLink {
    /// - Parameters:
    ///   - isInstalled: bundle ID のアプリが入っているか
    ///   - slackTeams: Slack のワークスペースのドメイン（`acme`・`acme.enterprise`）から team ID を引く表。Slack を開くときだけ読む
    static func rewrite(_ url: URL, isInstalled: (String) -> Bool, slackTeams: () -> [String: String]) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        switch host {
        case "discord.com", "www.discord.com", "ptb.discord.com", "canary.discord.com", "discordapp.com", "www.discordapp.com":
            guard isInstalled("com.hnc.Discord"), path.hasPrefix("/channels/") || path.hasPrefix("/invite/") || path.hasPrefix("/users/") else { return nil }
            return URL(string: "discord://-" + path)
        case "discord.gg":
            guard isInstalled("com.hnc.Discord"), path.count > 1 else { return nil }
            return URL(string: "discord://-/invite" + path)
        case "www.notion.so", "notion.so":
            guard isInstalled("notion.id") else { return nil }
            return replacingScheme(url, with: "notion")
        case "teams.microsoft.com":
            guard isInstalled("com.microsoft.teams2") || isInstalled("com.microsoft.teams") else { return nil }
            return replacingScheme(url, with: "msteams")
        default:
            if host.hasSuffix(".slack.com") { return slack(url, host: host, isInstalled: isInstalled, teams: slackTeams) }
            if host == "zoom.us" || host.hasSuffix(".zoom.us") { return zoom(url, host: host, isInstalled: isInstalled) }
            return nil
        }
    }

    /// `https://<ws>.slack.com/archives/<channel>/p<16 桁>` → `slack://channel?team=&id=&message=`。
    /// slack:// はドメインでなく team ID を取るので、Slack が手元に持つワークスペースの一覧から引く
    private static func slack(_ url: URL, host: String, isInstalled: (String) -> Bool, teams: () -> [String: String]) -> URL? {
        guard isInstalled("com.tinyspeck.slackmacgap") else { return nil }
        let domain = String(host.dropLast(".slack.com".count))
        guard let team = teams()[domain] else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var items = [URLQueryItem(name: "team", value: team)]
        let kind: String
        if parts.count >= 2, parts[0] == "archives" {
            kind = "channel"
            items.append(URLQueryItem(name: "id", value: parts[1]))
            if parts.count >= 3, let ts = messageTimestamp(parts[2]) { items.append(URLQueryItem(name: "message", value: ts)) }
        } else if parts.count >= 2, parts[0] == "team" {
            kind = "user"
            items.append(URLQueryItem(name: "id", value: parts[1]))
        } else {
            kind = "open"
        }
        var components = URLComponents()
        components.scheme = "slack"
        components.host = kind
        components.queryItems = items
        return components.url
    }

    /// permalink の `p1700000000123456` → `1700000000.123456`
    static func messageTimestamp(_ part: String) -> String? {
        guard part.hasPrefix("p") else { return nil }
        let digits = part.dropFirst()
        guard digits.count > 6, digits.allSatisfy(\.isNumber) else { return nil }
        return "\(digits.dropLast(6)).\(digits.suffix(6))"
    }

    /// `https://<sub>.zoom.us/j/<id>?pwd=` → `zoommtg://<host>/join?confno=<id>&pwd=`
    private static func zoom(_ url: URL, host: String, isInstalled: (String) -> Bool) -> URL? {
        guard isInstalled("us.zoom.xos") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, ["j", "w", "my"].contains(parts[0]) else { return nil }
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = host
        components.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: parts[1])]
        if let pwd = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" }) { items.append(pwd) }
        components.queryItems = items
        return components.url
    }

    private static func replacingScheme(_ url: URL, with scheme: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = scheme
        return components.url
    }
}

#if os(macOS)
/// Slack の desktop が手元に持つワークスペースの一覧（`root-state.json` の `workspaces`）。ドメイン → team ID
enum SlackTeams {
    static func load() -> [String: String] {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Slack/storage/root-state.json")
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let workspaces = root["workspaces"] as? [String: Any]
        else { return [:] }
        var teams: [String: String] = [:]
        for case let workspace as [String: Any] in workspaces.values {
            guard let id = workspace["id"] as? String else { continue }
            if let domain = workspace["domain"] as? String { teams[domain.lowercased()] = teams[domain.lowercased()] ?? id }
            // Enterprise Grid の org は `https://<org>.enterprise.slack.com/` で、リンクもそのドメインで来る
            if let url = (workspace["url"] as? String).flatMap(URL.init(string:)), let host = url.host?.lowercased(), host.hasSuffix(".slack.com") {
                teams[String(host.dropLast(".slack.com".count))] = id
            }
        }
        return teams
    }
}
#endif
