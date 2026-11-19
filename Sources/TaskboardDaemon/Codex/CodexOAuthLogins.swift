import Foundation
import TaskboardKit

/// codex のコネクタの認証（`mcpServer/oauth/login`）の待ち。マシンの接続（`CodexMachine`）と会話（`CodexConversation`）が、
/// それぞれ自分の app-server で始めた認証を持つ（app-server は資格情報をプロセスごとに覚えるので、認証した app-server でないとすぐには繋がらない）。
/// 完了の知らせは `loginId` だけで照らし合わせ（名前で当てると、同じコネクタの前の認証の知らせを取り違える）、
/// 戻り先のアドレスは待っている認証の redirect_uri（port・path・state）と同じものを 1 度だけ開く
struct CodexOAuthLogins: Sendable {
    enum Failure: Error, Equatable {
        case notConnected
        /// codex が断った（OAuth の無いコネクタ、名前が違う）
        case refused(String)
        /// `loginId` を返さない古い codex（0.162 より前）
        case outdated
        /// 認証のページが https でも 127.0.0.1・localhost の http でもない
        case unopenablePage
        /// 待っている認証が無い（終わった・取り消した・子が終わった・時間が過ぎた）
        case noLogin
        /// 戻り先のアドレスが、待っている認証の redirect_uri（port・path・state）と違う
        case callbackMismatch
        case callbackUnreachable
    }

    struct Login: Sendable, Equatable {
        let loginId: String
        let name: String
        /// 認証のページの redirect_uri と state。無ければ戻り先のアドレスを開かない
        let redirect: OAuthRedirect?
        let startedAt: Date
        var callbackOpened = false
    }

    struct Params: Encodable, Sendable {
        var name: String
        var timeoutSecs: Int
    }

    /// 待つ長さ（codex に `timeoutSecs` で渡し、過ぎた待ちの戻り先のアドレスは開かない）
    let limit: TimeInterval
    private(set) var waiting: [String: Login] = [:]

    init(limit: TimeInterval) { self.limit = limit }

    func params(name: String) -> Params { Params(name: name, timeoutSecs: Int(limit)) }

    /// `mcpServer/oauth/login` の応答（断られたものは呼ぶ側が先に扱う）から待ちを加え、開く認証のページを返す。同じコネクタの前の待ちは消す
    mutating func start(name: String, response line: CodexRPCLine, at now: Date) throws(Failure) -> (loginId: String, page: URL) {
        guard let result = try? line.result(StartResult.self) else { throw .refused("応答を読めない") }
        guard let loginId = result.loginId, !loginId.isEmpty else { throw .outdated }
        guard let page = OAuthLinks.openable(result.authorizationUrl) else { throw .unopenablePage }
        for (id, login) in waiting where login.name == name { waiting[id] = nil }
        waiting[loginId] = Login(loginId: loginId, name: name, redirect: OAuthLinks.redirect(of: page), startedAt: now)
        return (loginId, page)
    }

    /// 時間の過ぎた待ちを除き、除いたものを返す（アプリも同じ長さで待つのをやめる。その後に届いた知らせで成功にしない）
    mutating func expire(at now: Date) -> [Login] {
        let expired = waiting.values.filter { now.timeIntervalSince($0.startedAt) > limit }
        for login in expired { waiting[login.loginId] = nil }
        return expired
    }

    /// ほかの端末で受けた戻り先のアドレスを確かめ、開いた印を付けて返す。開けなかったら `callbackFailed` で印を外す
    mutating func openCallback(loginId: String, url raw: String) throws(Failure) -> URL {
        guard var login = waiting[loginId], !login.callbackOpened else { throw .noLogin }
        guard let url = OAuthLinks.callback(raw), let redirect = login.redirect, Self.matches(url, redirect) else { throw .callbackMismatch }
        login.callbackOpened = true
        waiting[loginId] = login
        return url
    }

    mutating func callbackFailed(loginId: String) {
        waiting[loginId]?.callbackOpened = false
    }

    /// `mcpServer/oauthLogin/completed`：待っている認証の知らせなら待ちを除き、その認証と成否を返す
    mutating func complete(_ line: CodexRPCLine) -> (login: Login, success: Bool)? {
        guard let done = try? line.params(Completed.self), let loginId = done.loginId, let login = waiting[loginId], login.name == done.name
        else { return nil }
        waiting[loginId] = nil
        return (login, done.success)
    }

    mutating func cancel(loginId: String) {
        waiting[loginId] = nil
    }

    mutating func removeAll() {
        waiting.removeAll()
    }

    func waiting(name: String) -> Login? {
        waiting.values.first { $0.name == name }
    }

    static func matches(_ callback: URL, _ redirect: OAuthRedirect) -> Bool {
        guard let target = URLComponents(url: callback, resolvingAgainstBaseURL: false),
            let expected = URLComponents(url: redirect.address, resolvingAgainstBaseURL: false)
        else { return false }
        let path = { (value: String) in value.isEmpty ? "/" : value }
        return target.port == expected.port && path(target.path) == path(expected.path)
            && target.queryItems?.first(where: { $0.name == "state" })?.value == redirect.state
    }

    private struct StartResult: Decodable {
        var authorizationUrl: String
        var loginId: String?
    }

    /// 認証のページの URL・error の文は読まない
    private struct Completed: Decodable {
        var name: String
        var loginId: String?
        var success: Bool
    }
}
