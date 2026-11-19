import Foundation

/// Slack の Web API（`https://slack.com/api/<method>`）。token は Authorization のヘッダにだけ載せ、URL・ログ・エラー文に出さない
struct SlackWebAPI: Sendable {
    let session: URLSession
    let base: URL

    init(session: URLSession = .shared, base: URL = URL(string: "https://slack.com/api")!) {
        self.session = session
        self.base = base
    }

    struct Failure: Error, Equatable, CustomStringConvertible {
        /// Slack の `error`（`invalid_auth` など）か、HTTP・通信の失敗
        var code: String
        var description: String { "Slack の API が失敗した（\(code)）" }
    }

    /// `ok` が false なら `error` を `Failure` にする。form で送る（`chat.postMessage` 以外も JSON の本文を受けるが、`conversations.*` の GET 系は form しか読まない）
    func call(_ method: String, token: String, _ parameters: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: base.appending(path: method))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` は form では空白になるので符号化する
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(code: "network")
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 429 { throw Failure(code: "ratelimited") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(code: "http_\((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard object["ok"] as? Bool == true else { throw Failure(code: object["error"] as? String ?? "unknown") }
        return object
    }

    struct Identity: Equatable, Sendable {
        var teamID: String
        var workspace: String
        var botUserID: String
        var botName: String
    }

    /// bot token の持ち主（`auth.test`）
    func authTest(botToken: String) async throws -> Identity {
        let object = try await call("auth.test", token: botToken)
        return Identity(
            teamID: object["team_id"] as? String ?? "", workspace: object["team"] as? String ?? "",
            botUserID: object["user_id"] as? String ?? "", botName: object["user"] as? String ?? "")
    }

    /// Socket Mode の接続先（`apps.connections.open`。app-level token、scope `connections:write`）
    func openConnection(appToken: String) async throws -> URL {
        let object = try await call("apps.connections.open", token: appToken)
        guard let string = object["url"] as? String, let url = URL(string: string), url.scheme == "wss" else { throw Failure(code: "no_url") }
        return url
    }

    func userName(_ id: String, botToken: String) async -> String? {
        guard let object = try? await call("users.info", token: botToken, ["user": id]), let user = object["user"] as? [String: Any] else { return nil }
        let profile = user["profile"] as? [String: Any]
        return [profile?["display_name"], profile?["real_name"], user["name"]].compactMap { ($0 as? String)?.nilIfBlank }.first
    }

    func channelName(_ id: String, botToken: String) async -> String? {
        guard let object = try? await call("conversations.info", token: botToken, ["channel": id]),
            let channel = object["channel"] as? [String: Any]
        else { return nil }
        return channel["name"] as? String
    }

    /// bot が入っているチャンネル（公開・非公開）。1,000 件まで
    func channels(botToken: String) async throws -> [(id: String, name: String)] {
        var found: [(id: String, name: String)] = []
        var cursor = ""
        repeat {
            var parameters = ["types": "public_channel,private_channel", "exclude_archived": "true", "limit": "200"]
            if !cursor.isEmpty { parameters["cursor"] = cursor }
            let object = try await call("users.conversations", token: botToken, parameters)
            for channel in object["channels"] as? [[String: Any]] ?? [] {
                if let id = channel["id"] as? String, let name = channel["name"] as? String { found.append((id, name)) }
            }
            cursor = (object["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
        } while !cursor.isEmpty && found.count < 1_000
        return found.sorted { $0.name < $1.name }
    }

    func permalink(channel: String, ts: String, botToken: String) async -> String? {
        try? await call("chat.getPermalink", token: botToken, ["channel": channel, "message_ts": ts])["permalink"] as? String
    }

    /// スレッドの発言（親を含む、古い順）。bot が入っていないチャンネルは `not_in_channel` で失敗する
    func replies(channel: String, ts: String, botToken: String, limit: Int = 50) async throws -> [[String: Any]] {
        try await call("conversations.replies", token: botToken, ["channel": channel, "ts": ts, "limit": "\(limit)"])["messages"] as? [[String: Any]] ?? []
    }

    /// 返信を付けて、付いた発言の ts を返す
    func post(channel: String, threadTs: String, text: String, botToken: String) async throws -> String? {
        try await call("chat.postMessage", token: botToken, ["channel": channel, "thread_ts": threadTs, "text": text, "unfurl_links": "false"])["ts"] as? String
    }

    /// 人への DM に送り、DM のチャンネルと発言の ts を返す（アプリの「メッセージ」タブ。`chat:write` だけで送れる）
    func postDirect(user: String, text: String, botToken: String) async throws -> (channel: String, ts: String)? {
        let object = try await call("chat.postMessage", token: botToken, ["channel": user, "text": text, "unfurl_links": "false"])
        guard let channel = object["channel"] as? String, let ts = object["ts"] as? String else { return nil }
        return (channel, ts)
    }

    /// 確認の画面を開く（`trigger_id` は 3 秒で切れる）。`view` は JSON の文字列で渡す
    func openView(triggerID: String, view: [String: Any], botToken: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: view, options: [.sortedKeys])
        _ = try await call("views.open", token: botToken, ["trigger_id": triggerID, "view": String(decoding: data, as: UTF8.self)])
    }

    /// ショートカットを使った人にだけ見える返事（`response_url`。token は要らない）
    func respond(_ url: URL, text: String) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["response_type": "ephemeral", "replace_original": false, "text": text])
        request.timeoutInterval = 30
        _ = try? await session.data(for: request)
    }

    /// チャンネルの新しい発言（新しい順）。bot が入っていないチャンネルは `not_in_channel` で失敗する
    func history(channel: String, botToken: String, limit: Int) async throws -> [[String: Any]] {
        try await call("conversations.history", token: botToken, ["channel": channel, "limit": "\(limit)"])["messages"] as? [[String: Any]] ?? []
    }

    enum SessionStatus: String {
        case processing, active, suspended
    }

    /// スレッドの agent session の様子（無ければ作る）。`initiator`・`title` は作るときだけ効く。Agents を有効にしていないアプリでは失敗する
    func setSessionStatus(
        channel: String, threadTs: String, _ status: SessionStatus, initiator: String? = nil, title: String? = nil, botToken: String
    ) async throws {
        var parameters = ["channel_id": channel, "thread_ts": threadTs, "status": status.rawValue]
        if let initiator { parameters["initiator_user_id"] = initiator }
        if let title { parameters["title"] = title }
        _ = try await call("agents.sessions.setStatus", token: botToken, parameters)
    }

    func react(channel: String, ts: String, name: String, botToken: String) async throws {
        do {
            _ = try await call("reactions.add", token: botToken, ["channel": channel, "timestamp": ts, "name": name])
        } catch let failure as Failure where failure.code == "already_reacted" {}
    }
}

extension String {
    fileprivate var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
