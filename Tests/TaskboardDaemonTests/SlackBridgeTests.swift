import Foundation
import Synchronization
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Slack の Web API の代わりに応答し、呼ばれたメソッドと form の値を記録する。テストごとに別の host を使う
private final class StubSlack: URLProtocol {
    struct Call: Sendable, Equatable {
        var method: String
        var form: [String: String]
        var authorization: String?
        var body = ""
    }

    private static let state = Mutex<[String: (calls: [Call], reply: @Sendable (String, [String: String]) -> String)]>([:])

    static func api(host: String, _ reply: @escaping @Sendable (String, [String: String]) -> String) -> SlackWebAPI {
        state.withLock { $0[host] = ([], reply) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSlack.self]
        return SlackWebAPI(session: URLSession(configuration: configuration), base: URL(string: "https://\(host)/api")!)
    }

    static func calls(host: String) -> [Call] { state.withLock { $0[host]?.calls ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        var components = URLComponents()
        // response_url への返事は JSON の本文なので form として読まない
        if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true {
            components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        }
        let form = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        let method = url.lastPathComponent
        let call = Call(
            method: method, form: form, authorization: request.value(forHTTPHeaderField: "Authorization"), body: String(decoding: body, as: UTF8.self))
        let reply = Self.state.withLock { state -> (@Sendable (String, [String: String]) -> String)? in
            state[host]?.calls.append(call)
            return state[host]?.reply
        }
        let text = reply?(method, form) ?? #"{"ok":false,"error":"unknown_method"}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 会話への送り先を記録する
private actor FakeConversations: SlackConversations {
    struct Sent: Equatable {
        var conversation: String
        var text: String
        var messageID: String
    }

    var leads: [Int: TaskDeliveryTarget] = [:]
    var orchestrator: String?
    private(set) var sent: [Sent] = []
    private(set) var started: [(task: Int, id: String)] = []

    init(orchestrator: String? = "orch") { self.orchestrator = orchestrator }

    func setLead(_ target: TaskDeliveryTarget, task: Int) { leads[task] = target }

    func slackLead(task number: Int) async -> TaskDeliveryTarget? { leads[number] }
    func slackOrchestratorID() async -> String? { orchestrator }

    func slackSend(_ id: String, text: String, messageID: String) async throws {
        // 本物と同じく、同じ messageID は 2 回入らない
        guard !sent.contains(where: { $0.messageID == messageID }) else { return }
        sent.append(Sent(conversation: id, text: text, messageID: messageID))
    }

    func slackStartLead(task: BoardTask, board: Board?, text: String, id: String, messageID: String) async throws {
        started.append((task.number, id))
        sent.append(Sent(conversation: id, text: text, messageID: messageID))
    }
}

private let machine = MachineID(rawValue: "m-slack")
private let botToken = "xoxb-stub-bot-token-0123"
private let appToken = "xapp-stub-app-token-0123"

private struct World {
    var store: Store
    var state: DaemonState
    var bridge: SlackBridge
    var conversations: FakeConversations
    var board: Board
    var task: BoardTask
    var host: String
    var settings: SlackSettingsStore
    var publisher: StatePublisher

    var calls: [StubSlack.Call] { StubSlack.calls(host: host) }
}

private func standardReply(_ method: String, _ form: [String: String]) -> String {
    switch method {
    case "auth.test": #"{"ok":true,"team_id":"T1","team":"ws","user_id":"UBOT","user":"taskboard"}"#
    case "apps.connections.open": #"{"ok":true,"url":"wss://stub.invalid/link"}"#
    case "users.info": #"{"ok":true,"user":{"name":"yuki","profile":{"display_name":"ゆき"}}}"#
    case "conversations.info": #"{"ok":true,"channel":{"name":"dev"}}"#
    case "chat.getPermalink": #"{"ok":true,"permalink":"https://ws.slack.com/archives/\#(form["channel"] ?? "")/p1"}"#
    case "chat.postMessage":
        // 人の id に送ると DM のチャンネルが返る
        #"{"ok":true,"channel":"\#((form["channel"] ?? "").hasPrefix("U") ? "DIM" : form["channel"] ?? "")","ts":"1700000999.000100"}"#
    case "views.open": #"{"ok":true}"#
    case "reactions.add": #"{"ok":true}"#
    case "conversations.replies":
        #"{"ok":true,"messages":[{"ts":"1700000000.000100","user":"U2","text":"親の発言"},{"ts":"1700000100.000100","user":"UOK","text":"依頼"}]}"#
    default: #"{"ok":false,"error":"unknown_method"}"#
    }
}

/// 案件 a とタスク 1 つ、Slack の設定（UOK だけを許し、C-ROUTE をタスクへ届ける）を置く
private func world(
    orchestrator: String? = "orch", configure: Bool = true,
    reply: @escaping @Sendable (String, [String: String]) -> String = standardReply
) async throws -> World {
    let host = "slack-\(UUID().uuidString.lowercased()).test"
    let api = StubSlack.api(host: host, reply)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack-\(UUID().uuidString)")
    let settings = SlackSettingsStore(directory: directory)
    let store = try Store(inMemory: machine)
    let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
    let publisher = store.statePublisher(state: state)
    let board = try store.createBoard(name: "a", columns: nil)
    let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t"))
    await publisher.settled()
    if configure {
        try settings.save(
            SlackSettingsStore.Settings(
                botToken: botToken, appToken: appToken, allowedUsers: [SlackMember(id: "UOK", name: "ゆき")],
                routes: [SlackRoute(channelID: "CROUTE", channelName: "route", taskNumber: task.number)], teamID: "T1", workspace: "ws",
                botUserID: "UBOT", botName: "taskboard"),
            board: board.id)
    }
    let conversations = FakeConversations(orchestrator: orchestrator)
    let bridge = SlackBridge(store: store, state: state, settings: settings, api: api, conversations: conversations)
    return World(store: store, state: state, bridge: bridge, conversations: conversations, board: board, task: task, host: host, settings: settings, publisher: publisher)
}

private func mention(event id: String = "Ev1", user: String = "UOK", channel: String = "CGEN", ts: String = "1700000100.000100", text: String = "<@UBOT> これやっといて", extra: [String: Any] = [:]) -> SlackIncoming {
    var event: [String: Any] = ["type": "app_mention", "user": user, "channel": channel, "ts": ts, "text": text]
    event.merge(extra) { $1 }
    return SlackIncoming(payload: ["event_id": id, "event": event])!
}

@Suite("Slack の知らせの読み方")
struct SlackEventTests {
    @Test("envelope は hello・disconnect・events_api を読み、知らない種類も envelope_id があれば受領だけ返す")
    func envelope() {
        #expect(SlackEnvelope.parse(Data(#"{"type":"hello"}"#.utf8)) == .hello)
        #expect(SlackEnvelope.parse(Data(#"{"type":"disconnect","reason":"refresh_requested"}"#.utf8)) == .disconnect(reason: "refresh_requested"))
        #expect(SlackEnvelope.parse(Data(#"{"type":"slash_commands","envelope_id":"e9"}"#.utf8)) == .other(envelopeID: "e9"))
        #expect(SlackEnvelope.parse(Data("not json".utf8)) == nil)
        let event = #"{"type":"events_api","envelope_id":"e1","payload":{"event_id":"Ev1","event":{"type":"app_mention","user":"U1","channel":"C1","ts":"1.2","text":"hi"}}}"#
        guard case .event(let envelopeID, let request?) = SlackEnvelope.parse(Data(event.utf8)) else { Issue.record("events_api を読めない"); return }
        #expect(envelopeID == "e1")
        #expect(request.user == "U1")
        #expect(request.replyThread == "1.2")
        #expect(SlackEnvelope.acknowledgement("e1") == #"{"envelope_id":"e1"}"#)
    }

    @Test("読むのは app_mention と bot への DM だけ。bot の発言・編集・チャンネルの普通の発言は読まず、ファイル付きは読む")
    func incoming() {
        func read(_ event: [String: Any]) -> SlackIncoming? { SlackIncoming(payload: ["event_id": "E", "event": event]) }
        let base: [String: Any] = ["user": "U1", "channel": "D1", "ts": "1.0", "text": "x"]
        #expect(read(base.merging(["type": "message", "channel_type": "im"]) { $1 })?.isDirectMessage == true)
        #expect(read(base.merging(["type": "message", "channel_type": "channel"]) { $1 }) == nil)
        #expect(read(base.merging(["type": "message", "channel_type": "im", "bot_id": "B1"]) { $1 }) == nil)
        #expect(read(base.merging(["type": "app_mention", "subtype": "message_changed"]) { $1 }) == nil)
        #expect(read(base.merging(["type": "app_mention", "subtype": "file_share"]) { $1 }) != nil)
        #expect(read(base.merging(["type": "app_mention", "thread_ts": "0.5"]) { $1 })?.replyThread == "0.5")
        #expect(read(["type": "app_mention", "channel": "C1", "ts": "1.0"]) == nil)
    }

    @Test("bot へのメンションを外し、転送は is_share・is_msg_unfurl の attachment だけを拾う")
    func text() {
        #expect(SlackText.removingMention("<@UBOT> これやっといて <@U2>", botUserID: "UBOT") == "これやっといて <@U2>")
        #expect(SlackText.removingMention("  ", botUserID: nil) == "")
        let event = #"{"attachments":[{"is_share":true,"text":"転送の本文","author_name":"佐藤","from_url":"https://ws.slack.com/archives/C1/p1700000000000100","channel_id":"C1","ts":"1700000000.000100"},{"text":"ただのリンクの展開"}]}"#
        let shared = SlackText.shared(eventJSON: event)
        #expect(shared == [SlackText.SharedMessage(author: "佐藤", authorID: nil, text: "転送の本文", permalink: "https://ws.slack.com/archives/C1/p1700000000000100", channel: "C1", ts: "1700000000.000100")])
        #expect(SlackText.shared(eventJSON: "{}").isEmpty)
        #expect(SlackText.shared(eventJSON: "壊れた").isEmpty)
    }

    @Test("メッセージのリンクは p の 16 桁を ts にし、thread_ts を読み、同じ発言は 1 回だけ数える")
    func messageLinks() {
        let text = "見て <https://ws.slack.com/archives/C01AB/p1700000000000100?thread_ts=1699999999.000200&cid=C01AB|これ> と https://ws.slack.com/archives/C01AB/p1700000000000100 と https://ws.slack.com/archives/C02/p1700000001000300"
        let links = SlackText.messageLinks(in: text)
        #expect(links.map(\.channel) == ["C01AB", "C02"])
        #expect(links[0].ts == "1700000000.000100")
        #expect(links[0].threadTs == "1699999999.000200")
        #expect(links[1].ts == "1700000001.000300")
        #expect(links[1].threadTs == nil)
        #expect(SlackText.messageLinks(in: "https://example.com/archives/C1/p1700000000000100").isEmpty)
        #expect(SlackText.messageLinks(in: "").isEmpty)
    }
}

@Suite("Slack からの依頼の届け方")
struct SlackBridgeTests {
    @Test("許していない人の依頼は記録も送信もしない")
    func ignoresOthers() async throws {
        let w = try await world()
        await w.bridge.receive(mention(user: "UNG"), board: w.board.id)
        #expect(await w.conversations.sent.isEmpty)
        #expect(try w.store.receivedSlackRequests().isEmpty)
        #expect(w.calls.isEmpty)
    }

    @Test("対応表に無いチャンネルの依頼はオーケストレーターに届け、印と本文を入れて 👀 を付ける。同じ event_id は 1 回だけ")
    func toOrchestrator() async throws {
        let w = try await world()
        await w.bridge.receive(mention(), board: w.board.id)
        await w.bridge.receive(mention(), board: w.board.id)
        let sent = await w.conversations.sent
        #expect(sent.count == 1)
        #expect(sent.first?.conversation == "orch")
        let text = try #require(sent.first?.text)
        #expect(text.hasPrefix(TaskboardNotice.marker(.slack, ["id": "1"])))
        #expect(text.hasSuffix(TaskboardNotice.slackRequestHeading + "\nこれやっといて"))
        #expect(text.contains("ゆき"))
        #expect(text.contains(Copy.text("agent.notice.slack.intake")))
        #expect(!text.contains(botToken))
        let reactions = w.calls.filter { $0.method == "reactions.add" }
        #expect(reactions.map { $0.form["name"] } == ["eyes"])
        #expect(reactions.first?.form["timestamp"] == "1700000100.000100")
        #expect(reactions.first?.authorization == "Bearer \(botToken)")
        #expect(try w.store.slackRequest(id: 1)?.state == Store.SlackRequestRow.State.delivered.rawValue)
    }

    @Test("対応表のチャンネルの依頼は、タスクの lead の会話へ。lead が無ければ起こし、端末で止まっていれば理由をスレッドに返す")
    func toTask() async throws {
        let w = try await world()
        await w.conversations.setLead(.conversation("lead-1"), task: w.task.number)
        await w.bridge.receive(mention(event: "Ev1", channel: "CROUTE"), board: w.board.id)
        #expect(await w.conversations.sent.map(\.conversation) == ["lead-1"])
        #expect(await w.conversations.sent.first?.text.contains(Copy.text("agent.notice.slack.intake")) == true)

        let fresh = try await world()
        await fresh.bridge.receive(mention(event: "Ev2", channel: "CROUTE"), board: fresh.board.id)
        let started = await fresh.conversations.started
        #expect(started.map(\.task) == [fresh.task.number])
        #expect(started.first?.id == SlackBridge.conversationID(eventID: "Ev2"))

        let stopped = try await world()
        await stopped.conversations.setLead(.stoppedTerminal(agentSessionID: "s"), task: stopped.task.number)
        await stopped.bridge.receive(mention(event: "Ev3", channel: "CROUTE", ts: "1700000200.000100"), board: stopped.board.id)
        #expect(await stopped.conversations.sent.isEmpty)
        let posts = stopped.calls.filter { $0.method == "chat.postMessage" }
        #expect(posts.count == 1)
        #expect(posts.first?.form["channel"] == "CROUTE")
        #expect(posts.first?.form["thread_ts"] == "1700000200.000100")
        #expect(posts.first?.form["text"]?.contains("端末で止まっています") == true)
        #expect(try stopped.store.slackRequest(id: 1)?.state == Store.SlackRequestRow.State.failed.rawValue)
    }

    @Test("オーケストレーターが動いていなければ、スレッドに理由を返す")
    func noOrchestrator() async throws {
        let w = try await world(orchestrator: nil)
        await w.bridge.receive(mention(extra: ["thread_ts": "1700000000.000100"]), board: w.board.id)
        let post = try #require(w.calls.first { $0.method == "chat.postMessage" })
        #expect(post.form["thread_ts"] == "1700000000.000100")
        #expect(post.form["text"]?.contains("オーケストレーターが動いていません") == true)
    }

    @Test("返信は受けた依頼のスレッドにだけ送り、空や長すぎる文・知らない依頼は送らない")
    func reply() async throws {
        let w = try await world()
        await w.bridge.receive(mention(extra: ["thread_ts": "1700000000.000100"]), board: w.board.id)
        let result = try await w.bridge.reply(id: 1, text: " 終わりました ")
        #expect(result.permalink == "https://ws.slack.com/archives/CGEN/p1")
        let post = try #require(w.calls.last { $0.method == "chat.postMessage" })
        #expect(post.form == ["channel": "CGEN", "thread_ts": "1700000000.000100", "text": "終わりました", "unfurl_links": "false"])
        await #expect(throws: StoreError.self) { try await w.bridge.reply(id: 1, text: "  ") }
        await #expect(throws: StoreError.self) { try await w.bridge.reply(id: 1, text: String(repeating: "あ", count: SlackReplyRequest.maxCharacters + 1)) }
        await #expect(throws: StoreError.self) { try await w.bridge.reply(id: 99, text: "x") }
    }

    @Test("slack_get はスレッドの前の発言とリンクされた発言を返し、依頼の後の発言は含めない")
    func detail() async throws {
        let w = try await world()
        let link = "https://ws.slack.com/archives/C9/p1700000000000100"
        await w.bridge.receive(mention(text: "<@UBOT> これ \(link)", extra: ["thread_ts": "1700000000.000100"]), board: w.board.id)
        let detail = try await w.bridge.detail(id: 1)
        #expect(detail.text == "これ \(link)")
        #expect(detail.thread.map(\.text) == ["親の発言"])
        #expect(detail.shared.map(\.text) == ["親の発言"])
        #expect(detail.shared.first?.permalink == link)
    }

    @Test("設定の読み出しは token を返さない。token の形が違えば保存しない")
    func settings() async throws {
        let w = try await world(configure: false)
        #expect(try await w.bridge.info(board: w.board.id).configured == false)
        await #expect(throws: StoreError.self) {
            try await w.bridge.update(board: w.board.id, BoardSlackUpdate(botToken: "xapp-wrong", appToken: appToken, allowedUsers: [], routes: []))
        }
        let saved = try await w.bridge.update(
            board: w.board.id,
            BoardSlackUpdate(botToken: botToken, appToken: appToken, allowedUsers: ["uok"], routes: [SlackRouteUpdate(channelID: "CROUTE", taskNumber: w.task.number)]))
        #expect(saved.configured)
        #expect(saved.workspace == "ws")
        #expect(saved.allowedUsers == [SlackMember(id: "UOK", name: "ゆき")])
        #expect(saved.routes == [SlackRoute(channelID: "CROUTE", channelName: "dev", taskNumber: w.task.number)])
        let json = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!json.contains("xoxb-") && !json.contains("xapp-"))
        let file = w.settings.directory.appending(path: "\(w.board.id).json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        await #expect(throws: StoreError.self) {
            try await w.bridge.update(board: w.board.id, BoardSlackUpdate(allowedUsers: ["C123"], routes: []))
        }
        await w.bridge.remove(board: w.board.id)
        #expect(try await w.bridge.info(board: w.board.id).configured == false)
    }

    // MARK: メッセージのショートカット

    private func shortcut(user: String = "UOK", channel: String = "CROUTE", host: String, message: [String: Any] = [:]) -> SlackInteraction.Shortcut {
        var target: [String: Any] = ["type": "message", "user": "U2", "ts": "1700000000.000100", "text": "見てほしいメッセージ"]
        target.merge(message) { $1 }
        let payload: [String: Any] = [
            "type": "message_action", "callback_id": SlackInteraction.shortcutCallbackID, "trigger_id": "trig", "user": ["id": user],
            "channel": ["id": channel, "name": "route"], "message": target, "response_url": "https://\(host)/actions/respond",
        ]
        guard case .shortcut(let shortcut)? = SlackInteraction(payload: payload) else { fatalError("ショートカットを読めない") }
        return shortcut
    }

    private func submission(key: String, user: String = "UOK", option: String, instruction: String = "要約して") -> SlackInteraction {
        let payload: [String: Any] = [
            "type": "view_submission", "user": ["id": user],
            "view": [
                "id": "V1", "callback_id": SlackInteraction.viewCallbackID, "private_metadata": key,
                "state": [
                    "values": [
                        SlackInteraction.destinationBlock: [SlackInteraction.valueAction: ["selected_option": ["value": option]]],
                        SlackInteraction.instructionBlock: [SlackInteraction.valueAction: ["value": " \(instruction) "]],
                    ]
                ],
            ],
        ]
        return SlackInteraction(payload: payload)!
    }

    private func openedView(_ w: World) throws -> [String: Any] {
        let call = try #require(w.calls.last { $0.method == "views.open" })
        return try #require(try JSONSerialization.jsonObject(with: Data((call.form["view"] ?? "").utf8)) as? [String: Any])
    }

    private func initialOption(_ view: [String: Any]) -> String? {
        let blocks = view["blocks"] as? [[String: Any]] ?? []
        let element = blocks.first { $0["block_id"] as? String == SlackInteraction.destinationBlock }?["element"] as? [String: Any]
        return (element?["initial_option"] as? [String: Any])?["value"] as? String
    }

    @Test("envelope の interactive は、taskboard のショートカットと確認の画面の送信だけを読む")
    func interactiveEnvelope() {
        let raw = #"{"type":"interactive","envelope_id":"e2","payload":{"type":"message_action","callback_id":"taskboard_send_message","trigger_id":"t","user":{"id":"U1"},"channel":{"id":"C1","name":"dev"},"message":{"ts":"1.0","text":"x","thread_ts":"0.5"},"response_url":"http://insecure.example/x"}}"#
        guard case .interactive("e2", .shortcut(let shortcut)?) = SlackEnvelope.parse(Data(raw.utf8)) else { Issue.record("ショートカットを読めない"); return }
        #expect(shortcut.threadTs == "0.5")
        #expect(shortcut.responseURL == nil)
        let other = #"{"type":"interactive","envelope_id":"e3","payload":{"type":"message_action","callback_id":"someone_else","trigger_id":"t","user":{"id":"U1"},"channel":{"id":"C1"},"message":{"ts":"1.0"}}}"#
        #expect(SlackEnvelope.parse(Data(other.utf8)) == .interactive(envelopeID: "e3", interaction: nil))
        #expect(SlackInteraction.taskNumber(option: SlackInteraction.option(task: 172)) == 172)
        #expect(SlackInteraction.taskNumber(option: SlackInteraction.orchestratorOption) == nil)
    }

    @Test("許していない人のショートカットは画面を開かず、本人にだけメンバーIDを添えて断る")
    func shortcutFromOthers() async throws {
        let w = try await world()
        await w.bridge.interact(.shortcut(shortcut(user: "UNG", host: w.host)), board: w.board.id)
        #expect(!w.calls.contains { $0.method == "views.open" })
        let respond = try #require(w.calls.first { $0.method == "respond" })
        #expect(respond.authorization == nil)
        #expect(respond.body.contains("UNG"))
        #expect(respond.body.contains("ephemeral"))
    }

    @Test("確認の画面の送り先は、チャンネルの届け先があればそのタスク、無ければオーケストレーター。終わりの列のタスクは出さない")
    func confirmationDefaults() async throws {
        let w = try await world()
        let done = try w.store.createTask(TaskCreateRequest(boardID: w.board.id, columnID: "done", title: "終わった"))
        await w.publisher.settled()
        await w.bridge.interact(.shortcut(shortcut(host: w.host)), board: w.board.id)
        let routed = try openedView(w)
        #expect(initialOption(routed) == SlackInteraction.option(task: w.task.number))
        let raw = try #require(w.calls.last { $0.method == "views.open" }?.form["view"])
        #expect(raw.contains("> 見てほしいメッセージ"))
        #expect(raw.contains(#""value":"\#(SlackInteraction.option(task: w.task.number))""#))
        #expect(!raw.contains(#""value":"\#(SlackInteraction.option(task: done.number))""#))
        await w.bridge.interact(.shortcut(shortcut(channel: "CGEN", host: w.host)), board: w.board.id)
        #expect(initialOption(try openedView(w)) == SlackInteraction.orchestratorOption)
    }

    @Test("送信すると DM に受付を置いて選んだ送り先に届け、対象のメッセージは slack_get で読み、返信は DM のスレッドへ")
    func shortcutDelivery() async throws {
        let w = try await world()
        await w.conversations.setLead(.conversation("lead-1"), task: w.task.number)
        await w.bridge.interact(.shortcut(shortcut(host: w.host, message: ["reply_count": 2])), board: w.board.id)
        let key = try #require(try openedView(w)["private_metadata"] as? String)
        await w.bridge.interact(submission(key: key, option: SlackInteraction.option(task: w.task.number)), board: w.board.id)
        await w.bridge.interact(submission(key: key, option: SlackInteraction.option(task: w.task.number)), board: w.board.id)

        let sent = await w.conversations.sent
        #expect(sent.map(\.conversation) == ["lead-1"])
        let text = try #require(sent.first?.text)
        #expect(text.contains("#route のメッセージ"))
        #expect(text.contains("転送・リンクされたメッセージ: 1 件"))
        #expect(text.hasSuffix(TaskboardNotice.slackRequestHeading + "\n要約して"))
        let receipt = try #require(w.calls.first { $0.method == "chat.postMessage" })
        #expect(receipt.form["channel"] == "UOK")
        #expect(receipt.form["text"]?.contains("#\(w.task.number) t") == true)
        #expect(w.calls.filter { $0.method == "reactions.add" }.map { $0.form["channel"] } == ["DIM"])
        // 2 回目の送信は控えが無いので、届けずに DM で断る
        #expect(w.calls.filter { $0.method == "chat.postMessage" }.last?.form["text"]?.contains("もう一度") == true)

        let detail = try await w.bridge.detail(id: 1)
        #expect(detail.shared.map(\.text) == ["見てほしいメッセージ"])
        #expect(detail.shared.first?.author == "ゆき")
        #expect(detail.thread.map(\.text) == ["依頼"])
        _ = try await w.bridge.reply(id: 1, text: "要約です")
        let reply = try #require(w.calls.last { $0.method == "chat.postMessage" })
        #expect(reply.form["channel"] == "DIM")
        #expect(reply.form["thread_ts"] == "1700000999.000100")
    }

    @Test("送り先にオーケストレーターを選べばオーケストレーターに届ける")
    func shortcutToOrchestrator() async throws {
        let w = try await world()
        await w.bridge.interact(.shortcut(shortcut(host: w.host)), board: w.board.id)
        let key = try #require(try openedView(w)["private_metadata"] as? String)
        await w.bridge.interact(submission(key: key, option: SlackInteraction.orchestratorOption, instruction: ""), board: w.board.id)
        #expect(await w.conversations.sent.map(\.conversation) == ["orch"])
        #expect(try w.store.slackRequest(id: 1)?.taskNumber == nil)
    }
}

/// Agents を有効にしたアプリ（`agents.sessions.setStatus` が通る）。チャンネルの新しい発言は新しい順に返る
private func agentReply(_ method: String, _ form: [String: String]) -> String {
    switch method {
    case "agents.sessions.setStatus": #"{"ok":true,"status":"\#(form["status"] ?? "")"}"#
    case "conversations.history": #"{"ok":true,"messages":[{"ts":"1700000300.000100","user":"U2","text":"新しい発言"},{"ts":"1700000200.000100","user":"U2","text":"古い発言"}]}"#
    default: standardReply(method, form)
    }
}

/// アプリとの DM の発言。`viewing` は Slack が付ける、依頼した人が開いているチャンネル
private func direct(
    event id: String, ts: String, threadTs: String? = nil, viewing: String? = nil, text: String = "これ調べて"
) -> SlackIncoming {
    var event: [String: Any] = ["type": "message", "channel_type": "im", "user": "UOK", "channel": "DAPP", "ts": ts, "text": text]
    if let threadTs { event["thread_ts"] = threadTs }
    if let viewing { event["app_context"] = ["entities": [["type": "slack#/types/channel_id", "value": viewing, "team_id": "T1"]]] }
    return SlackIncoming(payload: ["event_id": id, "event": event])!
}

@Suite("Slack の Agents の機能")
struct SlackAgentTests {
    @Test("Agents の使えるアプリは 👀 の代わりに返信のスレッドを作業中にし、slack_reply の status で終わった・途中・答え待ちにする")
    func sessionStatus() async throws {
        let w = try await world(reply: agentReply)
        await w.bridge.receive(mention(extra: ["thread_ts": "1700000000.000100"]), board: w.board.id)
        let started = try #require(w.calls.first { $0.method == "agents.sessions.setStatus" })
        #expect(
            started.form == [
                "channel_id": "CGEN", "thread_ts": "1700000000.000100", "status": "processing", "initiator_user_id": "UOK", "title": "これやっといて",
            ])
        #expect(w.calls.allSatisfy { $0.method != "reactions.add" })

        _ = try await w.bridge.reply(id: 1, text: "途中です", status: .working)
        _ = try await w.bridge.reply(id: 1, text: "確認させてください", status: .waiting)
        _ = try await w.bridge.reply(id: 1, text: "終わりました")
        let statuses = w.calls.filter { $0.method == "agents.sessions.setStatus" }.map { $0.form["status"] }
        #expect(statuses == ["processing", "processing", "suspended", "active"])
        #expect(w.calls.filter { $0.method == "agents.sessions.setStatus" }.dropFirst().allSatisfy { $0.form["thread_ts"] == "1700000000.000100" })
    }

    @Test("Agents の使えないアプリでも slack_reply は返信できる")
    func replyWithoutAgents() async throws {
        let w = try await world()
        await w.bridge.receive(mention(), board: w.board.id)
        let result = try await w.bridge.reply(id: 1, text: "終わりました", status: .waiting)
        #expect(result.permalink != nil)
        #expect(w.calls.filter { $0.method == "reactions.add" }.count == 1)
    }

    @Test("DM の依頼は、開いていたチャンネルに届け先があればそのタスクへ。会話の文と slack_get に開いていたチャンネルを出す")
    func viewingRoute() async throws {
        let w = try await world(reply: agentReply)
        await w.conversations.setLead(.conversation("lead-1"), task: w.task.number)
        await w.bridge.receive(direct(event: "Ev1", ts: "1700000400.000100", viewing: "CROUTE"), board: w.board.id)
        #expect(await w.conversations.sent.map(\.conversation) == ["lead-1"])
        let text = try #require(await w.conversations.sent.first?.text)
        #expect(text.contains("開いていたチャンネル: #route"))
        let detail = try await w.bridge.detail(id: 1)
        #expect(detail.viewing?.channelID == "CROUTE")
        #expect(detail.viewing?.channelName == "route")
        #expect(detail.viewing?.readable == true)
        #expect(detail.viewing?.recent.map(\.text) == ["古い発言", "新しい発言"])
        let history = try #require(w.calls.first { $0.method == "conversations.history" })
        #expect(history.form["channel"] == "CROUTE")
    }

    @Test("届け先の無いチャンネルを開いていた DM の依頼はオーケストレーターへ。名前は Slack から取り、読めなければ読めないと返す")
    func viewingUnrouted() async throws {
        let w = try await world()
        await w.bridge.receive(direct(event: "Ev1", ts: "1700000400.000100", viewing: "COTHER"), board: w.board.id)
        #expect(await w.conversations.sent.map(\.conversation) == ["orch"])
        #expect(await w.conversations.sent.first?.text.contains("開いていたチャンネル: #dev") == true)
        let detail = try await w.bridge.detail(id: 1)
        #expect(detail.viewing?.channelName == "dev")
        #expect(detail.viewing?.readable == false)
        #expect(detail.viewing?.recent.isEmpty == true)
    }

    @Test("アプリとの DM 自身しか開いていない・context が無い DM の依頼は、開いていたチャンネルを出さない")
    func viewingNone() async throws {
        let w = try await world()
        await w.bridge.receive(direct(event: "Ev1", ts: "1700000400.000100", viewing: "DAPP"), board: w.board.id)
        await w.bridge.receive(direct(event: "Ev2", ts: "1700000500.000100"), board: w.board.id)
        #expect(await w.conversations.sent.allSatisfy { !$0.text.contains("開いていたチャンネル") })
        #expect(try await w.bridge.detail(id: 1).viewing == nil)
    }

    @Test("スレッドの続きは、開いているチャンネルが変わっても最初の依頼と同じ届け先へ。最初の依頼の無いスレッドはふだんの届け先")
    func threadFollowUp() async throws {
        let w = try await world()
        await w.conversations.setLead(.conversation("lead-1"), task: w.task.number)
        await w.bridge.receive(direct(event: "Ev1", ts: "1700000400.000100", viewing: "CROUTE"), board: w.board.id)
        await w.bridge.receive(direct(event: "Ev2", ts: "1700000410.000100", threadTs: "1700000400.000100", viewing: "COTHER"), board: w.board.id)
        await w.bridge.receive(direct(event: "Ev3", ts: "1700000420.000100", threadTs: "1700000400.000100"), board: w.board.id)
        await w.bridge.receive(direct(event: "Ev4", ts: "1700000510.000100", threadTs: "1700000500.000100"), board: w.board.id)
        #expect(await w.conversations.sent.map(\.conversation) == ["lead-1", "lead-1", "lead-1", "orch"])
        #expect(try w.store.slackRequest(id: 2)?.threadTs == "1700000400.000100")
    }

    @Test("Slack の会話の題は依頼の 1 行目を 60 字まで。空なら決まった題")
    func sessionTitle() {
        #expect(SlackBridge.sessionTitle("") == "taskboardへの依頼")
        #expect(SlackBridge.sessionTitle(" \n ") == "taskboardへの依頼")
        #expect(SlackBridge.sessionTitle("  ログ調べて \n詳しくは下") == "ログ調べて")
        #expect(SlackBridge.sessionTitle(String(repeating: "あ", count: 60)) == String(repeating: "あ", count: 60))
        #expect(SlackBridge.sessionTitle(String(repeating: "a", count: 61)) == String(repeating: "a", count: 60) + "…")
    }
}

@Suite("Slack の接続の見張り")
struct SlackSocketTests {
    /// 接続は受けるが何も返さない相手（listen だけして accept しない）
    private final class SilentListener {
        let fd: Int32
        let port: UInt16

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
            guard bound == 0, listen(fd, 4) == 0 else {
                close(fd)
                throw POSIXError(.EADDRINUSE)
            }
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            self.fd = fd
            port = UInt16(bigEndian: address.sin_port)
        }

        deinit { close(fd) }
    }

    @Test("hello が来ない接続は期限で切ってつなぎ直す")
    func helloTimeout() async throws {
        let listener = try SilentListener()
        let host = "socket-hello.test"
        let port = listener.port
        let api = StubSlack.api(host: host) { method, _ in
            method == "apps.connections.open" ? #"{"ok":true,"url":"wss://127.0.0.1:\#(port)/link"}"# : #"{"ok":false,"error":"unknown_method"}"#
        }
        let states = Mutex<[SlackConnection]>([])
        let socket = SlackSocket(
            api: api, appToken: "xapp-test", liveness: .init(helloTimeout: .milliseconds(300), pingInterval: .seconds(30), pongTimeout: .seconds(10)),
            onState: { state in states.withLock { $0.append(state) } }, onRequest: { _ in }, onInteraction: { _ in })
        let running = Task { await socket.run() }
        defer {
            running.cancel()
            withExtendedLifetime(listener) {}
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !states.withLock({ $0.contains { if case .failed = $0 { true } else { false } } }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(states.withLock { $0.contains { if case .failed = $0 { true } else { false } } })
    }

    @Test("Slack に届かない間は間隔を延ばさずに試し続ける（眠りから起きた直後に VPN が張り直されるまで）")
    func unreachableRetriesWithoutBackoff() async throws {
        // 閉じた port なので、接続の URL を取る HTTP がすぐ失敗する
        let api = SlackWebAPI(session: URLSession(configuration: .ephemeral), base: URL(string: "https://127.0.0.1:1/api")!)
        let failures = Mutex(0)
        let socket = SlackSocket(
            // 倍にしていく間隔の側を使えば、1 回目の失敗の後 60 秒待つ
            api: api, appToken: "xapp-test", retry: .init(first: .seconds(60), max: .seconds(300), unreachable: .milliseconds(50)),
            onState: { state in if case .failed = state { failures.withLock { $0 += 1 } } }, onRequest: { _ in }, onInteraction: { _ in })
        let running = Task { await socket.run() }
        defer { running.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, failures.withLock({ $0 }) < 3 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(failures.withLock { $0 } >= 3)
    }
}
