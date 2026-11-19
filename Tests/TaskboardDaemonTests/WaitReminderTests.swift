import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("待ちのままの作業項目の見直し")
struct WaitReminderTests {
    private let machine = MachineID(rawValue: "m-wait")

    private func line(_ json: String) -> Data { Data(json.utf8) }

    private func human(_ at: String) -> Data {
        line(#"{"type":"user","origin":{"kind":"human"},"timestamp":"\#(at)","message":{"role":"user","content":"進めて"}}"#)
    }

    private func tool(_ name: String, _ at: String) -> Data {
        line(#"{"type":"assistant","timestamp":"\#(at)","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"\#(name)","input":{}}]}}"#)
    }

    private func result(_ at: String) -> Data {
        line(#"{"type":"user","timestamp":"\#(at)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#)
    }

    @Test("ターンの始まりは最後の人の発話。その後に taskboard 以外のツールを呼んでいれば作業した。前のターンのツールと meta の行は数えない")
    func turnFromTranscript() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = try #require(formatter.date(from: "2026-10-06T05:00:00.000Z"))
        let lines = [
            human("2026-10-06T04:00:00.000Z"), tool("Bash", "2026-10-06T04:00:01.000Z"), result("2026-10-06T04:00:02.000Z"),
            human("2026-10-06T05:00:00.000Z"),
            line(#"{"type":"user","isMeta":true,"timestamp":"2026-10-06T05:00:00.500Z","message":{"role":"user","content":"<system-reminder>"}}"#),
            tool("mcp__taskboard__work_list", "2026-10-06T05:00:01.000Z"), result("2026-10-06T05:00:02.000Z"),
        ]
        #expect(TranscriptTurn.parse(lines) == TranscriptTurn(startedAt: start, usedTools: false))
        #expect(TranscriptTurn.parse(lines + [tool("Edit", "2026-10-06T05:00:03.000Z")]) == TranscriptTurn(startedAt: start, usedTools: true))
        #expect(TranscriptTurn.parse([tool("Bash", "2026-10-06T05:00:03.000Z"), line("壊れた行")]) == nil)
        #expect(TranscriptTurn.parse([]) == nil)
    }

    @Test("transcript の末尾だけを読み、途中で切れた先頭の行は捨てる")
    func readsTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let filler = String(repeating: "x", count: 300)
        var text = (0..<20).map { _ in #"{"type":"assistant","message":{"content":"\#(filler)"}}"# }.joined(separator: "\n") + "\n"
        text += String(decoding: human("2026-10-06T05:00:00.000Z"), as: UTF8.self) + "\n"
        text += String(decoding: tool("Bash", "2026-10-06T05:00:01.000Z"), as: UTF8.self) + "\n"
        try Data(text.utf8).write(to: url)
        let turn = try #require(TranscriptTurn.read(url, tailBytes: 1_000))
        #expect(turn.usedTools)
        #expect(TranscriptTurn.read(url.appendingPathExtension("missing")) == nil)
    }

    private func makeHooks() throws -> (HookService, Store, BoardTask) {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let github = GitHubSync(store: store, state: state, cli: GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: URL(fileURLWithPath: "/usr/bin/false")))
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "受信箱を作り直す"))
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: "/tmp", label: "")
        return (HookService(store: store, state: state, github: github), store, task)
    }

    private func stop(_ hooks: HookService, startedAt: Date?, usedTools: Bool) async throws -> HookStopResponse {
        try await hooks.stop(
            HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "s-1", cwd: "/tmp", turnStartedAt: startedAt, turnUsedTools: usedTools))
    }

    @Test("待ちにした後に始まったターンで作業したのに待ちのままの項目を、1 回だけ挙げる。ターン中に動かした項目・作業しなかったターンは挙げない")
    func remindsOnce() async throws {
        let (hooks, store, task) = try makeHooks()
        let waiting = try store.createWorkItem(
            task: task.number, WorkItemCreateRequest(title: "設計の承認", state: .wait, blockerKind: .approval, blockerText: "計画の承認待ち"))
        _ = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "実装", state: .doing))
        let later = waiting.updatedAt.addingTimeInterval(60)

        #expect(try await stop(hooks, startedAt: later, usedTools: false).reminder == nil)
        #expect(try await stop(hooks, startedAt: waiting.updatedAt.addingTimeInterval(-60), usedTools: true).reminder == nil)
        #expect(try await stop(hooks, startedAt: nil, usedTools: true).reminder == nil)

        let reminder = try #require(try await stop(hooks, startedAt: later, usedTools: true).reminder)
        #expect(reminder.contains("[\(waiting.itemID)] 設計の承認"))
        #expect(reminder.contains("計画の承認待ち"))
        #expect(reminder.hasPrefix("[taskboard] タスク #") && reminder.contains("work_update") && reminder.hasSuffix("返信は不要\n"), "日本語の常体で、動かし方と返信が不要ことを書く")
        #expect(!reminder.contains("実装"))
        #expect(try await stop(hooks, startedAt: later.addingTimeInterval(60), usedTools: true).reminder == nil)

        // 待ちを付け直したら、その待ちについてはもう一度挙げる
        let rewaited = try store.updateWorkItem(id: waiting.itemID, WorkItemUpdateRequest(state: .wait, blockerKind: .review, blockerText: "レビュー待ち"))
        #expect(try await stop(hooks, startedAt: rewaited.updatedAt.addingTimeInterval(60), usedTools: true).reminder?.contains("レビュー待ち") == true)
    }

    @Test("待ちの見直しは、lead には owner が空か自分の項目を、委譲先には owner が自分の項目だけを頼む")
    func remindsOwners() async throws {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let github = GitHubSync(store: store, state: state, cli: GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: URL(fileURLWithPath: "/usr/bin/false")))
        let board = try store.createBoard(name: "a", columns: nil)
        var task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "受信箱を作り直す"))
        for id in ["lead-1", "dele-1", "dele-2"] {
            task = try store.linkSession(task: task.number, agent: "claude", sessionID: "a-\(id)", cwd: "/tmp", label: "")
        }
        await state.upsert(task)
        func conversation(_ id: String, parent: String? = nil) -> Conversation {
            Conversation(
                id: id, machine: machine, taskNumber: task.number, agentSessionID: "a-\(id)", cwd: "/tmp", runner: .host, phase: .idle,
                parentConversationID: parent, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
        await state.upsert(conversation("lead-1"))
        await state.upsert(conversation("dele-1", parent: "lead-1"))
        await state.upsert(conversation("dele-2", parent: "lead-1"))
        let hooks = HookService(store: store, state: state, github: github)

        let mine = try store.createWorkItem(
            task: task.number, WorkItemCreateRequest(title: "段 1 の取り込み", state: .wait, blockerKind: .approval, owner: "dele-1"))
        let lead = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "入れ替え", state: .wait, blockerKind: .item))
        let later = max(mine.updatedAt, lead.updatedAt).addingTimeInterval(60)
        func stop(_ id: String) async throws -> String? {
            try await hooks.stop(
                HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "a-\(id)", cwd: "/tmp", turnStartedAt: later, turnUsedTools: true)
            ).reminder
        }

        let first = try #require(try await stop("lead-1"))
        #expect(first.contains("入れ替え") && !first.contains("段 1 の取り込み"), "委譲先が担当する待ちは lead に頼まない")
        #expect(try await stop("dele-2") == nil, "owner でない委譲先には頼まない")
        let delegate = try #require(try await stop("dele-1"))
        #expect(delegate.contains("段 1 の取り込み") && !delegate.contains("入れ替え"))
    }
}
