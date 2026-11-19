import Foundation

/// Socket Mode の 1 通（`hello`・`disconnect`・`events_api`・`interactive` の envelope）
enum SlackEnvelope: Equatable {
    case hello
    /// `refresh_requested` は数時間ごとに来る。どれでも URL を取り直してつなぎ直す
    case disconnect(reason: String)
    /// 受領の返事（`{"envelope_id"}`）が要る。`request` は依頼として読めたときだけ
    case event(envelopeID: String, request: SlackIncoming?)
    /// 受領の返事（中身なし。確認の画面の送信なら画面を閉じる）が要る。`interaction` は taskboard のショートカットか確認の画面のときだけ
    case interactive(envelopeID: String, interaction: SlackInteraction?)
    /// 受領の返事だけを返して捨てる（slash command など、受けない種類）
    case other(envelopeID: String?)

    static func parse(_ data: Data) -> SlackEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return nil }
        let envelopeID = object["envelope_id"] as? String
        switch type {
        case "hello": return .hello
        case "disconnect": return .disconnect(reason: object["reason"] as? String ?? "")
        case "events_api":
            guard let envelopeID else { return .other(envelopeID: nil) }
            return .event(envelopeID: envelopeID, request: (object["payload"] as? [String: Any]).flatMap(SlackIncoming.init(payload:)))
        case "interactive":
            guard let envelopeID else { return .other(envelopeID: nil) }
            return .interactive(envelopeID: envelopeID, interaction: (object["payload"] as? [String: Any]).flatMap(SlackInteraction.init(payload:)))
        default: return .other(envelopeID: envelopeID)
        }
    }

    static func acknowledgement(_ envelopeID: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["envelope_id": envelopeID])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 依頼として読めた知らせ（`app_mention` か、bot への DM の `message`）。bot の発言・編集・削除は読まない
struct SlackIncoming: Equatable, Sendable {
    var eventID: String
    var channel: String
    var ts: String
    /// スレッドの中の発言ならスレッドの親の ts
    var threadTs: String?
    var user: String
    var text: String
    var isDirectMessage: Bool
    /// `event` の JSON（`slack_get` が転送されたメッセージを読む）
    var eventJSON: String

    init?(payload: [String: Any]) {
        guard let eventID = payload["event_id"] as? String, let event = payload["event"] as? [String: Any], let type = event["type"] as? String else { return nil }
        let isDirectMessage = type == "message" && event["channel_type"] as? String == "im"
        guard type == "app_mention" || isDirectMessage else { return nil }
        // 編集（message_changed）・削除・参加などの subtype は読まない。ファイルを付けた発言（file_share）とスレッドからの送り返しは読む
        if let subtype = event["subtype"] as? String, !["file_share", "thread_broadcast"].contains(subtype) { return nil }
        guard event["bot_id"] == nil, let user = event["user"] as? String, let channel = event["channel"] as? String, let ts = event["ts"] as? String else {
            return nil
        }
        self.eventID = eventID
        self.channel = channel
        self.ts = ts
        threadTs = event["thread_ts"] as? String
        self.user = user
        text = event["text"] as? String ?? ""
        self.isDirectMessage = isDirectMessage
        eventJSON = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// 返信を付けるスレッド
    var replyThread: String { threadTs ?? ts }
}

/// メッセージのショートカット［taskboardに送る］と、その確認の画面の送信
enum SlackInteraction: Equatable, Sendable {
    case shortcut(Shortcut)
    case submission(Submission)

    static let shortcutCallbackID = "taskboard_send_message"
    static let viewCallbackID = "taskboard_send"
    static let destinationBlock = "destination"
    static let instructionBlock = "instruction"
    static let valueAction = "value"

    struct Shortcut: Equatable, Sendable {
        var user: String
        var channel: String
        var channelName: String?
        var ts: String
        var threadTs: String?
        var text: String
        /// `{"type":"message_action","channel":{…},"message":{…}}`（`slack_get` が対象のメッセージとして読む）
        var eventJSON: String
        var triggerID: String
        var responseURL: URL?
    }

    struct Submission: Equatable, Sendable {
        var viewID: String
        var user: String
        /// 確認の画面を開いたときの控えの鍵（`private_metadata`）
        var key: String
        /// nil はオーケストレーター
        var taskNumber: Int?
        var instruction: String
    }

    init?(payload: [String: Any]) {
        let user = (payload["user"] as? [String: Any])?["id"] as? String
        switch payload["type"] as? String {
        case "message_action":
            guard payload["callback_id"] as? String == Self.shortcutCallbackID, let user, let trigger = payload["trigger_id"] as? String,
                let channel = payload["channel"] as? [String: Any], let channelID = channel["id"] as? String,
                let message = payload["message"] as? [String: Any], let ts = message["ts"] as? String
            else { return nil }
            let event: [String: Any] = ["type": "message_action", "channel": channel, "message": message]
            self = .shortcut(
                Shortcut(
                    user: user, channel: channelID, channelName: channel["name"] as? String, ts: ts, threadTs: message["thread_ts"] as? String,
                    text: message["text"] as? String ?? "",
                    eventJSON: (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}",
                    triggerID: trigger, responseURL: (payload["response_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }))
        case "view_submission":
            guard let user, let view = payload["view"] as? [String: Any], view["callback_id"] as? String == Self.viewCallbackID,
                let viewID = view["id"] as? String, let key = view["private_metadata"] as? String
            else { return nil }
            let values = (view["state"] as? [String: Any])?["values"] as? [String: Any]
            func element(_ block: String) -> [String: Any]? { (values?[block] as? [String: Any])?[Self.valueAction] as? [String: Any] }
            let destination = (element(Self.destinationBlock)?["selected_option"] as? [String: Any])?["value"] as? String
            self = .submission(
                Submission(
                    viewID: viewID, user: user, key: key, taskNumber: destination.flatMap(Self.taskNumber(option:)),
                    instruction: (element(Self.instructionBlock)?["value"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
        default:
            return nil
        }
    }

    static let orchestratorOption = "orchestrator"
    static func option(task number: Int) -> String { "task:\(number)" }
    static func taskNumber(option: String) -> Int? { option.hasPrefix("task:") ? Int(option.dropFirst(5)) : nil }
}

/// 知らせの中身の読み方（Slack の mrkdwn の `<@U…>`・`<url|text>`、転送の attachment）
enum SlackText {
    /// `<@bot>` を外し、前後の空白を落とす
    static func removingMention(_ text: String, botUserID: String?) -> String {
        var text = text
        if let botUserID, !botUserID.isEmpty { text = text.replacingOccurrences(of: "<@\(botUserID)>", with: "") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 転送されたメッセージ（`attachments` のうち `is_share` か `is_msg_unfurl` のもの）。ショートカットで送られた依頼は、対象のメッセージとその転送
    static func shared(eventJSON: String) -> [SharedMessage] {
        guard let event = try? JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any] else { return [] }
        if let origin = shortcutOrigin(event), let message = event["message"] as? [String: Any] {
            let target = SharedMessage(
                author: nil, authorID: message["user"] as? String, text: message["text"] as? String ?? "", permalink: event["permalink"] as? String,
                channel: origin.channel, ts: origin.ts)
            return [target] + attachments(message)
        }
        return attachments(event)
    }

    /// ショートカットで送られた依頼の、対象のメッセージの場所
    struct ShortcutOrigin: Equatable, Sendable {
        var channel: String
        var channelName: String?
        var ts: String
        /// スレッドの中か、返信のあるメッセージならスレッドの親の ts
        var threadTs: String?
    }

    static func shortcutOrigin(eventJSON: String) -> ShortcutOrigin? {
        (try? JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any]).flatMap(shortcutOrigin)
    }

    private static func shortcutOrigin(_ event: [String: Any]) -> ShortcutOrigin? {
        guard event["type"] as? String == "message_action", let channel = event["channel"] as? [String: Any], let id = channel["id"] as? String,
            let message = event["message"] as? [String: Any], let ts = message["ts"] as? String
        else { return nil }
        let threadTs = message["thread_ts"] as? String ?? ((message["reply_count"] as? Int ?? 0) > 0 ? ts : nil)
        return ShortcutOrigin(channel: id, channelName: channel["name"] as? String, ts: ts, threadTs: threadTs)
    }

    /// アプリとの DM の発言に Slack が付ける、依頼した人がいま開いているもの（`app_context.entities`。関係の深い順）
    static func appContextEntities(_ event: [String: Any]) -> [[String: Any]] {
        let context = (event["app_context"] ?? event["context"]) as? [String: Any]
        return context?["entities"] as? [[String: Any]] ?? []
    }

    struct Viewing: Equatable, Sendable {
        var channel: String
        var channelName: String?
    }

    /// 開いていたチャンネル（entity の `slack#/types/channel_id` の最初の 1 つ。アプリとの DM 自身は除く）。名前は受けたときに `viewingNameKey` に入れておく
    static func viewing(eventJSON: String) -> Viewing? {
        guard let event = try? JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any] else { return nil }
        let channel = appContextEntities(event).lazy.compactMap { entity -> String? in
            guard entity["type"] as? String == "slack#/types/channel_id", let value = entity["value"] as? String, !value.hasPrefix("D") else { return nil }
            return value
        }.first
        return channel.map { Viewing(channel: $0, channelName: event[viewingNameKey] as? String) }
    }

    static let viewingNameKey = "taskboard_viewing_name"

    private static func attachments(_ event: [String: Any]) -> [SharedMessage] {
        let attachments = event["attachments"] as? [[String: Any]] ?? []
        return attachments.compactMap { attachment in
            guard attachment["is_share"] as? Bool == true || attachment["is_msg_unfurl"] as? Bool == true else { return nil }
            let text = (attachment["text"] as? String) ?? (attachment["fallback"] as? String) ?? ""
            return SharedMessage(
                author: (attachment["author_name"] as? String) ?? (attachment["author_subname"] as? String), authorID: attachment["author_id"] as? String,
                text: text, permalink: (attachment["from_url"] as? String) ?? (attachment["original_url"] as? String),
                channel: attachment["channel_id"] as? String, ts: attachment["ts"] as? String)
        }
    }

    struct SharedMessage: Equatable, Sendable {
        var author: String?
        var authorID: String?
        var text: String
        var permalink: String?
        var channel: String?
        var ts: String?
    }

    struct MessageLink: Equatable, Sendable {
        var url: String
        var channel: String
        var ts: String
        var threadTs: String?
    }

    /// 本文の中の Slack のメッセージのリンク（`https://<ws>.slack.com/archives/<channel>/p<16 桁>`）。`p1699999999000100` は ts `1699999999.000100`
    static func messageLinks(in text: String) -> [MessageLink] {
        let pattern = #"https://[A-Za-z0-9.-]+\.slack\.com/archives/([A-Z0-9]+)/p(\d{10})(\d{6})([^\s|>]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let url = ns.substring(with: match.range)
            let channel = ns.substring(with: match.range(at: 1))
            let ts = ns.substring(with: match.range(at: 2)) + "." + ns.substring(with: match.range(at: 3))
            let rest = ns.substring(with: match.range(at: 4))
            let threadTs = URLComponents(string: "https://x" + rest)?.queryItems?.first { $0.name == "thread_ts" }?.value
            guard seen.insert(channel + "/" + ts).inserted else { return nil }
            return MessageLink(url: url, channel: channel, ts: ts, threadTs: threadTs)
        }
    }
}
