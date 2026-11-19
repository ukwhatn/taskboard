import Foundation
import Logging
import TaskboardKit

@testable import TaskboardDaemon

/// agent host の偽物。書かれた行を残し、CLI の代わりに行を出す。initialize には `pendingOnInitialize` を待っている問いとして返す
actor FakeHost: AgentHostTransport {
    private(set) var requests: [AgentHostRequest] = []
    private(set) var lines: [String] = []
    private var inbox: AsyncStream<AgentHostNotice>.Continuation?
    private var key = ""
    private(set) var seq = 0
    /// 出した行（host の控え）。subscribe で、その key の `after` より後を送り直す
    private var buffer: [(key: String, seq: Int, line: String)] = []
    /// 要求の key に知らせを送る（会話の service を通して何本も起こすテスト）。false なら `connect` の key だけ
    private var followsKeys = false
    /// subscribe で控えを送った後に exit を送る（daemon が止まっている間に終わった子）
    var exitedBeforeSubscribe = false
    var pendingOnInitialize: [String] = []
    var sessionState = "idle"
    /// initialize の応答に入れる `commands`（JSON の配列）
    var commandsOnInitialize: String?
    /// initialize の応答に入れる `models`（JSON の配列）と `claude_code_version`
    var modelsOnInitialize: String?
    /// 制御要求の subtype → 応答の `response`（JSON）。無い subtype には答えない
    private var replies: [String: String] = [:]
    /// 制御要求の subtype → 断る文（`replies` より先に見る）
    private var refusals: [String: String] = [:]
    var capabilities = ClaudeConversation.requiredCapabilities
    var processes: [AgentHostProcessInfo] = []
    /// この要求は接続が切れたとして失敗させる
    private var failing: Set<AgentHostRequest.Op> = []
    /// 本物と同じく、子の終わりは購読している key にだけ送り、まだ購読していない key には購読したときに送る
    private var subscribed: Set<String> = []
    private var exitedUnseen: Set<String> = []
    /// 次の closeInput は、入力を閉じた後、応答だけを `releaseCloseInput` まで返さない
    private var holdsCloseInput = false
    private var closeInputGate: CheckedContinuation<Void, Never>?

    /// 書き込みの応答をこれだけ遅らせる（同じ答えが重なる場面を作る）
    private var writeDelay: Duration?
    /// 書かれた 1 行に返す行（codex の偽の app-server）。nil なら Claude の制御要求に答える
    private var responder: (@Sendable (String) -> [String])?

    func setResponder(_ responder: (@Sendable (String) -> [String])?) { self.responder = responder }

    func setWriteDelay(_ delay: Duration?) { writeDelay = delay }
    func holdNextCloseInput() { holdsCloseInput = true }
    func releaseCloseInput() {
        closeInputGate?.resume()
        closeInputGate = nil
    }

    func setFailing(_ ops: Set<AgentHostRequest.Op>) { failing = ops }

    func connect(_ inbox: AsyncStream<AgentHostNotice>.Continuation, key: String) {
        self.inbox = inbox
        self.key = key
    }

    func setPending(_ requests: [String], state: String = "requires_action") {
        pendingOnInitialize = requests
        sessionState = state
    }
    func setCapabilities(_ values: [String]) { capabilities = values }
    func setCommands(_ json: String?) { commandsOnInitialize = json }
    func setModels(_ json: String?) { modelsOnInitialize = json }
    func setReply(_ subtype: String, _ json: String) { replies[subtype] = json }
    func setRefusal(_ subtype: String, _ message: String?) { refusals[subtype] = message }
    func setProcesses(_ values: [AgentHostProcessInfo]) { processes = values }
    /// 次の list から 1 回ずつ返す一覧（使い切ったら `processes`）
    private var queuedLists: [[AgentHostProcessInfo]] = []
    func queueLists(_ lists: [[AgentHostProcessInfo]]) { queuedLists = lists }
    func setFollowsKeys() { followsKeys = true }

    func call(
        _ op: AgentHostRequest.Op, key: String?, argv: [String]?, env: [String: String]?, cwd: String?, data: String?, signal: String?, after: Int?,
        through: Int?, cols: Int?, rows: Int?
    ) async throws -> AgentHostReply {
        requests.append(AgentHostRequest(id: requests.count + 1, op: op, key: key, argv: argv, env: env, cwd: cwd, data: data, signal: signal, after: after, through: through, cols: cols, rows: rows))
        if failing.contains(op) { throw AgentHostClient.Failure.disconnected }
        if let key, key.hasPrefix(ConversationRuns.keyPrefix) {
            return try await runShellHost().call(op, key: key, argv: argv, env: env, cwd: cwd, data: data, signal: signal, after: after, through: through, cols: cols, rows: rows)
        }
        if op == .shellList, let runShells {
            let real = try await runShells.call(.shellList, key: nil, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
            let fake = shellCall(op, key: key, argv: argv, cwd: cwd)?.shells ?? []
            return AgentHostReply(id: requests.count, ok: true, shells: fake + (real.shells ?? []))
        }
        if let reply = shellCall(op, key: key, argv: argv, cwd: cwd) { return reply }
        if followsKeys, let key { self.key = key }
        switch op {
        case .write:
            if let writeDelay { try? await Task.sleep(for: writeDelay) }
            for line in (data ?? "").split(separator: "\n") {
                lines.append(String(line))
                if let responder {
                    for reply in responder(String(line)) { emit(reply) }
                } else {
                    respond(to: String(line))
                }
            }
        case .closeInput, .signal:
            exit()
            if op == .closeInput, holdsCloseInput {
                holdsCloseInput = false
                await withCheckedContinuation { closeInputGate = $0 }
            }
        case .subscribe:
            for entry in buffer where entry.key == self.key && entry.seq > (after ?? 0) {
                inbox?.yield(AgentHostNotice(event: .output, key: self.key, seq: entry.seq, line: entry.line))
            }
            subscribed.insert(self.key)
            if exitedBeforeSubscribe || exitedUnseen.remove(self.key) != nil { exit() }
        case .unsubscribe:
            subscribed.remove(self.key)
        case .spawn:
            // 本物も、起こし直すと前の子の購読を持ち越さない
            subscribed.remove(self.key)
            exitedUnseen.remove(self.key)
        default:
            break
        }
        if op == .list, !queuedLists.isEmpty { return AgentHostReply(id: requests.count, ok: true, pid: 42, processes: queuedLists.removeFirst()) }
        return AgentHostReply(id: requests.count, ok: true, pid: 42, processes: processes)
    }

    /// 生きているシェル（key → pid）と、起こしたシェルの数
    private(set) var shells: [String: Int32] = [:]
    private(set) var openedShells: [(key: String, argv: [String], cwd: String)] = []

    /// 本物と同じく、閉じたシェルは終わりを知らせる
    func endShell(_ key: String) {
        guard shells.removeValue(forKey: key) != nil else { return }
        inbox?.yield(AgentHostNotice(event: .shellExit, key: key, exit: AgentHostExit(status: 0, signal: nil)))
    }

    /// コードブロックの実行のシェル（`run-` の key）は、本物の擬似端末で動かす（出力の目印を読むので、偽物では足りない）
    private var runShells: InProcessAgentHost?

    private func runShellHost() async -> InProcessAgentHost {
        if let runShells { return runShells }
        let host = InProcessAgentHost(
            logDirectory: FileManager.default.temporaryDirectory.appending(path: "tb-fake-run-\(UUID().uuidString)"), logger: Logger(label: "fake"))
        runShells = host
        await host.start { [weak self] notice in await self?.forward(notice) }
        return host
    }

    private func forward(_ notice: AgentHostNotice) { inbox?.yield(notice) }

    private func shellCall(_ op: AgentHostRequest.Op, key: String?, argv: [String]?, cwd: String?) -> AgentHostReply? {
        let id = requests.count
        switch op {
        case .shellOpen:
            guard let key else { return nil }
            if shells[key] == nil {
                openedShells.append((key, argv ?? [], cwd ?? ""))
                shells[key] = Int32(1000 + openedShells.count)
            }
            return AgentHostReply(id: id, ok: true, pid: shells[key])
        case .shellList:
            return AgentHostReply(id: id, ok: true, shells: shells.map { AgentHostShellInfo(key: $0.key, pid: $0.value, cols: 80, rows: 24, startedAt: 0) })
        case .shellClose:
            if let key { endShell(key) }
            return AgentHostReply(id: id, ok: true)
        case .shellSubscribe:
            guard let key, shells[key] != nil else { return AgentHostReply(id: id, ok: false, error: "unknown") }
            return AgentHostReply(id: id, ok: true, data: "", offset: 0)
        case .shellInput, .shellResize, .shellUnsubscribe:
            return AgentHostReply(id: id, ok: true)
        default:
            return nil
        }
    }

    private func respond(to line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "control_request",
            let id = object["request_id"] as? String, let subtype = (object["request"] as? [String: Any])?["subtype"] as? String
        else { return }
        switch subtype {
        case "initialize":
            emit(
                #"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"session_state":"\#(sessionState)","capabilities":[]\#(commandsOnInitialize.map { ",\"commands\":\($0)" } ?? "")\#(modelsOnInitialize.map { ",\"models\":\($0),\"claude_code_version\":\"2.1.304\"" } ?? "")},"pending_permission_requests":[\#(pendingOnInitialize.joined(separator: ","))]}}"#
            )
        case "interrupt" where replies[subtype] == nil:
            emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"still_queued":[],"cancelled":["m2"]}}}"#)
            emit(#"{"type":"result","subtype":"error_during_execution","is_error":false,"stop_reason":"interrupted","session_id":"s1"}"#)
        case "get_usage" where replies[subtype] == nil:
            emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":{"rate_limits":{}}}}"#)
        case _ where refusals[subtype] != nil:
            emit(#"{"type":"control_response","response":{"subtype":"error","request_id":"\#(id)","error":"\#(refusals[subtype] ?? "")"}}"#)
        default:
            if let reply = replies[subtype] {
                emit(#"{"type":"control_response","response":{"subtype":"success","request_id":"\#(id)","response":\#(reply)}}"#)
            }
        }
    }

    func emit(_ line: String) {
        emit(line, key: key)
    }

    /// 今の key でなく、決めた会話に流す（ほかの会話の書き込みで key が替わったとき）
    func emit(_ line: String, key: String) {
        seq += 1
        buffer.append((key, seq, line))
        inbox?.yield(AgentHostNotice(event: .output, key: key, seq: seq, line: line))
    }

    /// daemon が止まっている間に出た行（控えにだけ残る）
    func keep(_ line: String) {
        seq += 1
        buffer.append((key, seq, line))
    }

    func setExitedBeforeSubscribe() { exitedBeforeSubscribe = true }

    /// host が起き直した：控えと購読を捨て、行の番号を 1 から振り直す（本物も番号をメモリにだけ持つ）
    func restart() {
        seq = 0
        buffer.removeAll()
        shells.removeAll()
        subscribed.removeAll()
        exitedUnseen.removeAll()
    }

    func emitInit(session: String = "s1") {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        emit(#"{"type":"system","subtype":"init","session_id":"\#(session)","model":"claude-haiku-5-5","capabilities":[\#(caps)],"tools":[],"mcp_servers":[]}"#)
    }

    func gap(through: Int) {
        inbox?.yield(AgentHostNotice(event: .gap, key: key, through: through))
    }

    func exit() {
        guard subscribed.contains(key) else {
            exitedUnseen.insert(key)
            return
        }
        inbox?.yield(AgentHostNotice(event: .exit, key: key, exit: AgentHostExit(status: 0, signal: nil)))
    }

    /// 書かれた行（JSON の辞書）。`subtype` を渡すと、その制御要求だけ
    nonisolated func written(_ subtype: String? = nil) async -> [[String: Any]] {
        await lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.filter { object in
            guard let subtype else { return true }
            return (object["request"] as? [String: Any])?["subtype"] as? String == subtype
        }
    }

    nonisolated func controlResponses() async -> [[String: Any]] {
        await written().filter { $0["type"] as? String == "control_response" }.compactMap { $0["response"] as? [String: Any] }
    }

    func ops() -> [AgentHostRequest.Op] { requests.map(\.op) }
}
