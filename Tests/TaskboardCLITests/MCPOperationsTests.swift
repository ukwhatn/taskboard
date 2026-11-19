import Foundation
import MCP
import Synchronization
import TaskboardKit
import Testing

@testable import taskboard

/// daemon の HTTP の代わり。`GET /v1/state` は `snapshot` を、ほかは `routes`（"METHOD path" → 状態と本文）を返し、届いた要求を残す。
/// 表に無い DELETE と POST は 204、ほかは 404。テストごとに別の host を使う
final class RecordingDaemon: URLProtocol {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: [URLQueryItem]
        var body: Data

        func decode<T: Decodable>(_ type: T.Type) throws -> T { try WireJSON.decoder().decode(type, from: body) }
    }

    struct World: Sendable {
        var snapshot: StateSnapshot
        var routes: [String: (Int, Data)] = [:]
        var requests: [Request] = []
    }

    private static let worlds = Mutex<[String: World]>([:])

    static func tools(_ world: World, environment: [String: String] = ["CLAUDE_CODE_SESSION_ID": "s-self"], apns: URL? = nil) -> (TaskboardTools, String) {
        let host = "ops-\(UUID().uuidString.prefix(8).lowercased())"
        worlds.withLock { $0[host] = world }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingDaemon.self]
        let client = DaemonClient(endpoint: DaemonEndpoint(baseURL: URL(string: "http://\(host)")!, token: "t"), session: URLSession(configuration: configuration))
        let tools = TaskboardTools(client: client, environment: environment, cwd: "/w", apnsDirectory: apns)
        return (tools, host)
    }

    static func requests(_ host: String, _ method: String? = nil, _ path: String? = nil) -> [Request] {
        worlds.withLock { $0[host]!.requests }.filter { (method == nil || $0.method == method) && (path == nil || $0.path == path) }
    }

    /// state を読むだけの要求を除いた、書き込みの要求
    static func writes(_ host: String) -> [Request] { requests(host).filter { $0.method != "GET" } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host()!
        let method = request.httpMethod ?? "GET"
        let body = Self.body(of: request)
        let (status, data) = Self.worlds.withLock { worlds -> (Int, Data) in
            var world = worlds[host]!
            defer { worlds[host] = world }
            world.requests.append(
                Request(method: method, path: url.path, query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [], body: body))
            if method == "GET", url.path == "/v1/state" { return (200, try! WireJSON.encoder().encode(world.snapshot)) }
            if let route = world.routes["\(method) \(url.path)"] { return route }
            if method == "DELETE" || method == "POST" { return (204, Data()) }
            return (404, Data(#"{"error":{"message":"not found"}}"#.utf8))
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
}

let machine = MachineID(rawValue: "m1")
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func ok(_ value: some Encodable) -> (Int, Data) { (200, try! WireJSON.encoder().encode(value)) }

func board(_ id: String, _ name: String, position: Int = 0, archived: Bool = false) -> Board {
    Board(id: id, machine: machine, name: name, position: position, columns: BoardColumn.standard, createdAt: t0, archived: archived)
}

func task(_ number: Int, board: String = "b1", column: String = "working", sessions: [String] = [], links: [TaskLink] = []) -> BoardTask {
    BoardTask(
        machine: machine, number: number, boardID: board, columnID: column, title: "題\(number)", links: links,
        sessions: sessions.enumerated().map { TaskSessionRef(id: Int64($0.offset + 1), agent: "claude", sessionID: $0.element, cwd: "/w", linkedAt: t0.addingTimeInterval(Double($0.offset))) },
        createdAt: t0, updatedAt: t0)
}

func snapshot(
    boards: [Board] = [board("b1", "default"), board("b2", "DAS", position: 1)], tasks: [BoardTask] = [],
    workItems: [WorkItem] = [], documents: [Document] = [], asks: [Ask] = [], schedules: [Schedule] = [],
    prs: PRSnapshot? = nil, usage: UsageSnapshot? = nil, orchestrator: OrchestratorInfo? = nil
) -> StateSnapshot {
    StateSnapshot(
        machine: MachineInfo(id: machine, name: "この Mac", daemonVersion: "t"),
        boards: boards, tasks: tasks, workItems: workItems, documents: documents, asks: asks, prs: prs, usage: usage,
        schedules: schedules, orchestrator: orchestrator, generatedAt: t0)
}

func schedule(_ id: Int64, task: Int? = 1, lastRun: ScheduleRun? = nil) -> Schedule {
    Schedule(
        scheduleID: id, machine: machine, name: "朝の見回り", enabled: true, rule: .cron("0 9 * * 1-5"), cwd: "/w", kind: .claude, agentArgs: [],
        prompt: "p", taskNumber: task, overlap: .skip, lastRun: lastRun, createdAt: t0, updatedAt: t0)
}

// MARK: - host の会話

let conversationA = "6f1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f01"
let conversationB = "6f1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f02"

func conversation(
    _ id: String, phase: Conversation.Phase, task: Int? = 1, requests: [ConversationRequest] = [], title: String? = nil, background: Int = 0,
    backgroundKnown: Bool = true
) -> Conversation {
    Conversation(
        id: id, machine: machine, taskNumber: task, agentSessionID: "s-\(id.suffix(2))", cwd: "/w", model: "opus", title: title,
        runner: phase == .stopped ? .none : .host, phase: phase, pending: requests, lastExit: phase == .stopped ? "止めた" : nil, backgroundTasks: background,
        backgroundTasksKnown: backgroundKnown, createdAt: t0, updatedAt: t0)
}

func question(_ id: String) -> ConversationRequest {
    ConversationRequest(
        id: id, kind: .question, toolName: "AskUserQuestion", toolUseID: "toolu_q",
        waiting: RequestWaiting(
            id: id, since: t0,
            questions: [AskQuestion(id: "q0", question: "色は？", header: nil, options: [AskOption(label: "赤"), AskOption(label: "青")], multiSelect: false)]))
}

func permission(_ id: String) -> ConversationRequest {
    ConversationRequest(
        id: id, kind: .permission, toolName: "Bash", toolUseID: "toolu_b", waiting: RequestWaiting(id: id, since: t0, permission: .init(tool: "Bash", summary: "ls")))
}

func with(_ conversations: [Conversation], agentHost: AgentHostInfo? = nil, _ base: StateSnapshot = snapshot(tasks: [task(1)])) -> StateSnapshot {
    var snapshot = base
    snapshot.conversations = conversations
    snapshot.machine.agentHost = agentHost
    return snapshot
}
