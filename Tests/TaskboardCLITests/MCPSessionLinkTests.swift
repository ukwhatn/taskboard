import Foundation
import MCP
import Synchronization
import TaskboardKit
import Testing

@testable import taskboard

/// daemon の HTTP の代わり。タスクと紐づけを持ち、MCP が使う経路（state・resolve・link・起票・更新）だけに答える。
/// テストごとに別の host を使い、並列に走っても混ざらないようにする
private final class FakeDaemon: URLProtocol {
    struct World: Sendable {
        var board: Board
        var tasks: [BoardTask]
        var links: [SessionLinkRequest] = []
        var resolves: [String] = []
    }

    private static let worlds = Mutex<[String: World]>([:])
    static let machine = MachineID(rawValue: "m1")

    static func client(host: String, _ world: World) -> DaemonClient {
        worlds.withLock { $0[host] = world }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeDaemon.self]
        return DaemonClient(endpoint: DaemonEndpoint(baseURL: URL(string: "http://\(host)")!, token: "t"), session: URLSession(configuration: configuration))
    }

    static func world(_ host: String) -> World { worlds.withLock { $0[host]! } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host()!
        let body = Self.body(of: request)
        let (status, data) = Self.worlds.withLock { worlds -> (Int, Data) in
            var world = worlds[host]!
            defer { worlds[host] = world }
            return Self.answer(request.httpMethod ?? "GET", url, body, &world)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private static func answer(_ method: String, _ url: URL, _ body: Data, _ world: inout World) -> (Int, Data) {
        let encoder = WireJSON.encoder()
        let decoder = WireJSON.decoder()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func encode(_ value: some Encodable) -> (Int, Data) { (200, try! encoder.encode(value)) }
        switch (method, url.path) {
        case ("GET", "/v1/state"):
            return encode(
                StateSnapshot(
                    machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"), boards: [world.board],
                    tasks: world.tasks, generatedAt: Date()))
        case ("GET", "/v1/resolve"):
            let session = query.first { $0.name == "session" }?.value
            world.resolves.append(session ?? "pane:" + (query.first { $0.name == "pane" }?.value ?? ""))
            let task = session.flatMap { id in world.tasks.first { $0.sessions.contains { $0.sessionID == id } } }
            return encode(TaskResolution(task: task, method: task == nil ? "none" : "existing"))
        case ("POST", "/v1/sessions/link"):
            let link = try! decoder.decode(SessionLinkRequest.self, from: body)
            world.links.append(link)
            let index = world.tasks.firstIndex { $0.number == link.taskNumber }!
            world.tasks[index].sessions.append(
                TaskSessionRef(id: Int64(world.links.count), agent: link.agent, sessionID: link.agentSessionID, cwd: link.cwd, linkedAt: Date()))
            return encode(TaskResolution(task: world.tasks[index], method: "explicit", board: world.board))
        case ("POST", "/v1/tasks"):
            let create = try! decoder.decode(TaskCreateRequest.self, from: body)
            let task = BoardTask(
                machine: machine, number: (world.tasks.map(\.number).max() ?? 0) + 1, boardID: create.boardID, columnID: create.columnID,
                title: create.title, createdAt: Date(), updatedAt: Date())
            world.tasks.append(task)
            return encode(task)
        case ("PATCH", let path) where path.hasPrefix("/v1/tasks/"):
            let number = Int(path.split(separator: "/").last!)!
            let update = try! decoder.decode(TaskUpdateRequest.self, from: body)
            let index = world.tasks.firstIndex { $0.number == number }!
            if let column = update.columnID { world.tasks[index].columnID = column }
            return encode(world.tasks[index])
        default:
            return (404, Data(#"{"error":"not found"}"#.utf8))
        }
    }
}

@Suite("taskboard mcp: セッションを結ぶ")
struct MCPSessionLinkTests {
    private static func board(_ columns: [BoardColumn] = BoardColumn.standard) -> Board {
        Board(id: "b", machine: FakeDaemon.machine, name: "Studio", position: 0, columns: columns, createdAt: Date())
    }

    private static func task(_ number: Int, column: String = "working", session: String? = nil) -> BoardTask {
        BoardTask(
            machine: FakeDaemon.machine, number: number, boardID: "b", columnID: column, title: "題\(number)",
            sessions: session.map { [TaskSessionRef(id: 1, agent: "claude", sessionID: $0, cwd: "/w", linkedAt: Date())] } ?? [],
            createdAt: Date(), updatedAt: Date())
    }

    private static func tools(host: String, world: FakeDaemon.World, environment: [String: String]) -> TaskboardTools {
        TaskboardTools(
            client: FakeDaemon.client(host: host, world), environment: environment, cwd: "/Users/u/dev/app")
    }

    @Test("CLAUDE_CODE_SESSION_ID で結ぶ。task_id を省いた呼び出しも同じ ID でタスクを引く")
    func linksByEnvironment() async throws {
        let host = "env-\(UUID().uuidString.prefix(8))"
        let tools = Self.tools(
            host: host, world: .init(board: Self.board(), tasks: [Self.task(1)]), environment: ["CLAUDE_CODE_SESSION_ID": "sess-abcdef123"])

        let updated = try await tools.call("task_update", ["task_id": .int(1), "link_session": .bool(true)])
        #expect(updated.contains("- セッション: このセッション（sess-abc）を紐づけた"))
        let link = try #require(FakeDaemon.world(host).links.first)
        #expect(link.agentSessionID == "sess-abcdef123" && link.taskNumber == 1 && link.paneID == nil && link.cwd == "/Users/u/dev/app")

        let guide = try await tools.call("session_guide", [:])
        #expect(guide.hasPrefix("このセッションは taskboard のタスク #1「題1」"))
        #expect(FakeDaemon.world(host).resolves == ["sess-abcdef123"])
    }

    @Test("task_create は既定でこのセッションを結ぶ。未着手が無い案件では常設とレビュー依頼を除く最初の進行中の列に起票する")
    func createLinksAndFallsBack() async throws {
        let host = "create-\(UUID().uuidString.prefix(8))"
        let columns = BoardColumn.standard.filter { $0.id != "todo" }
        let tools = Self.tools(host: host, world: .init(board: Self.board(columns), tasks: []), environment: ["CLAUDE_CODE_SESSION_ID": "s2"])
        let text = try await tools.call("task_create", ["title": .string("新しい仕事")])
        #expect(text.hasPrefix("タスクを起票した\n- タスク: #1 新しい仕事\n- 列: planning"), "常設とレビュー依頼を飛ばす")
        #expect(FakeDaemon.world(host).links.map(\.agentSessionID) == ["s2"])
    }

    @Test("質問・レビューを頼んだ会話として、host の会話の id と環境のセッション ID を送る。どちらも無ければ送らない")
    func requester() {
        let host = "req-\(UUID().uuidString.prefix(8))"
        let world = FakeDaemon.World(board: Self.board(), tasks: [])
        let inside = Self.tools(host: host, world: world, environment: ["TASKBOARD_CONVERSATION_ID": "conv-1", "CLAUDE_CODE_SESSION_ID": "sess-1"])
        #expect(inside.requester == FeedbackRequester(conversationID: "conv-1", agentSessionID: "sess-1"))
        #expect(Self.tools(host: host, world: world, environment: ["TASKBOARD_CONVERSATION_ID": ""]).requester == nil)
        #expect(Self.tools(host: host, world: world, environment: [:]).requester == nil)
    }

    @Test("起こした側は、host の会話の中ならその会話（と環境の会話 ID）。外なら無い。MCP と CLI で同じ")
    func parentFromEnvironment() throws {
        let conversation = ["TASKBOARD_CONVERSATION_ID": "conv-1", "CLAUDE_CODE_SESSION_ID": "sess-1"]
        #expect(SessionEnvironment(environment: conversation).parent == ConversationParent(conversationID: "conv-1", agentSessionID: "sess-1"))
        #expect(SessionEnvironment(environment: ["TASKBOARD_CONVERSATION_ID": "conv-1"]).parent == ConversationParent(conversationID: "conv-1"))
        #expect(SessionEnvironment(environment: ["HERDR_PANE_ID": "w1:p2", "CLAUDE_CODE_SESSION_ID": "sess-1"]).parent == nil)
        #expect(SessionEnvironment(environment: ["TASKBOARD_CONVERSATION_ID": ""]).parent == nil)

        #expect(try ConversationCommand.Start.parent(environment: conversation) == ConversationParent(conversationID: "conv-1", agentSessionID: "sess-1"))
        do {
            _ = try ConversationCommand.Start.parent(environment: ["CLAUDE_CODE_SESSION_ID": "sess-1"])
            Issue.record("host の会話の外では断る")
        } catch {
            #expect(String(describing: error).hasPrefix("--parent-from-env:"))
        }
    }

    @Test("host の会話の中（TASKBOARD_CONVERSATION_ID がある）では settings.json の hook は何もしない")
    func hookInsideHostConversation() {
        #expect(Hook.insideHostConversation(["TASKBOARD_CONVERSATION_ID": "conv-1"]))
        #expect(!Hook.insideHostConversation(["TASKBOARD_CONVERSATION_ID": ""]))
        #expect(!Hook.insideHostConversation(["CLAUDE_CODE_SESSION_ID": "sess-1"]))
    }

    @Test("CLAUDE_CODE_SESSION_ID も host の会話も無ければ見分けられない文を返し、結んだことにしない")
    func unidentified() async throws {
        let host = "none-\(UUID().uuidString.prefix(8))"
        let tools = Self.tools(host: host, world: .init(board: Self.board(), tasks: [Self.task(1)]), environment: [:])
        await #expect(throws: TaskboardTools.ToolError.unidentified) { try await tools.call("task_get", [:]) }
        let updated = try await tools.call("task_update", ["task_id": .int(1), "link_session": .bool(true)])
        #expect(updated.contains("- セッション: 紐づけられなかった。このセッションがどれか分からない"))
        #expect(FakeDaemon.world(host).links.isEmpty)
    }

    @Test("ID はあるが紐づくタスクが無ければ、結び方を案内する")
    func unresolved() async throws {
        let host = "unres-\(UUID().uuidString.prefix(8))"
        let tools = Self.tools(host: host, world: .init(board: Self.board(), tasks: [Self.task(1)]), environment: ["CLAUDE_CODE_SESSION_ID": "s3"])
        await #expect(throws: TaskboardTools.ToolError.unresolved) { try await tools.call("work_list", [:]) }
        #expect(TaskboardTools.ToolError.unresolved.description.contains("link_session"))
    }

    @Test("task_get は今の列と説明を、task_update で列を移すと移した先の説明を返す。board_overview は列ごとに説明を付ける")
    func columnDescriptions() async throws {
        let host = "desc-\(UUID().uuidString.prefix(8))"
        let tools = Self.tools(
            host: host, world: .init(board: Self.board(), tasks: [Self.task(1, column: "planning", session: "s4")]), environment: ["CLAUDE_CODE_SESSION_ID": "s4"])
        let got = try await tools.call("task_get", [:])
        #expect(got.split(separator: "\n")[2] == "- 列: planning（計画）: 方針・設計を詰めている")

        let moved = try await tools.call("task_update", ["column": .string("standing")])
        #expect(moved.contains("- 移した先の列: standing（常設）: 期限なく続く仕事（定常の運用・問い合わせ対応など）。完了にしない"))

        let overview = try await tools.call("board_overview", [:])
        #expect(overview.contains("- todo（未着手）: 0 件 ・ やると決めたが、まだ始めていない"))
        #expect(overview.contains("このセッションに紐づくタスク: #1 題1（standing）"))
    }

    @Test("一覧の列の説明は 1 行目だけを 80 字までに切る")
    func summarySuffix() {
        #expect(TaskboardTools.summarySuffix(BoardColumn(id: "x", label: "x", kind: .open, position: 0)) == "")
        #expect(TaskboardTools.summarySuffix(BoardColumn(id: "x", label: "x", kind: .open, position: 0, description: "1 行目\n2 行目")) == " ・ 1 行目")
        let long = String(repeating: "あ", count: 90)
        #expect(TaskboardTools.summarySuffix(BoardColumn(id: "x", label: "x", kind: .open, position: 0, description: long)) == " ・ " + String(repeating: "あ", count: 80) + "…")
    }
}
