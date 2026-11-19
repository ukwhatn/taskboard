import Foundation
import TaskboardKit

/// 案件の Slack の設定の下書き。案件の設定と同じ保存の帯で送る（`BoardSettingsDraft.slack`）
struct BoardSlackDraft: Hashable {
    /// daemon に token が入っている
    var configured: Bool
    /// 設定済みの案件で token の欄を出している
    var replacingTokens = false
    var botToken = ""
    var appToken = ""
    var members: [SlackMember]
    var routes: [SlackRoute]

    init(_ slack: BoardSlack) {
        configured = slack.configured
        members = slack.allowedUsers
        routes = slack.routes
    }

    var showsTokenFields: Bool { !configured || replacingTokens }

    /// token の欄の誤り。入力していない欄は誤りにしない（形の誤りは入れた欄に、片方だけは空の欄に出す）
    var botTokenIssue: String? { Self.issue(botToken, other: appToken, valid: SlackToken.isBotToken, prefix: "xoxb-") }
    var appTokenIssue: String? { Self.issue(appToken, other: botToken, valid: SlackToken.isAppToken, prefix: "xapp-") }

    private static func issue(_ token: String, other: String, valid: (String) -> Bool, prefix: String) -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            return other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(localized: "トークンを2つとも入力してください。")
        }
        return valid(token) ? nil : String(localized: "「\(prefix)」で始まるトークンを入力してください。")
    }

    /// 保存の前に止める誤り
    var hasIssue: Bool { showsTokenFields && (botTokenIssue != nil || appTokenIssue != nil) }

    /// 欄を出しただけ・空のままは変更にしない
    func differs(from baseline: BoardSlackDraft) -> Bool {
        request(from: baseline) != nil
    }

    /// 送る中身。変更が無ければ nil。token は 2 つそろえて入れたときだけ載せ、人と対応表はいつも全件を載せる（daemon が丸ごと置き換える）
    func request(from baseline: BoardSlackDraft) -> BoardSlackUpdate? {
        let bot = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacing = showsTokenFields && !bot.isEmpty && !app.isEmpty
        guard replacing || members != baseline.members || routes != baseline.routes else { return nil }
        return BoardSlackUpdate(
            botToken: replacing ? bot : nil, appToken: replacing ? app : nil, allowedUsers: members.map(\.id),
            routes: routes.map { SlackRouteUpdate(channelID: $0.channelID, taskNumber: $0.taskNumber) })
    }

    /// 足す前の誤り。足せるなら nil
    func memberIssue(_ input: String) -> String? {
        let id = Self.memberID(input)
        guard !id.isEmpty else { return nil }
        if id.wholeMatch(of: /[UW][A-Z0-9]+/) == nil { return String(localized: "「U」か「W」で始まるメンバーIDを入力してください。") }
        if members.contains(where: { $0.id == id }) { return String(localized: "このメンバーIDは追加済みです。") }
        return nil
    }

    /// 足せたら true
    @discardableResult
    mutating func addMember(_ input: String) -> Bool {
        let id = Self.memberID(input)
        guard !id.isEmpty, memberIssue(input) == nil else { return false }
        members.append(SlackMember(id: id))
        return true
    }

    private static func memberID(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同じチャンネルは 1 行だけ（後から足した方で置き換える）
    mutating func setRoute(_ channel: SlackChannel, taskNumber: Int) {
        let route = SlackRoute(channelID: channel.id, channelName: channel.name, taskNumber: taskNumber)
        if let index = routes.firstIndex(where: { $0.channelID == channel.id }) {
            routes[index] = route
        } else {
            routes.append(route)
        }
    }
}
