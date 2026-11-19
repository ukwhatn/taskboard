import Foundation
import Testing

@testable import TaskboardDaemon

/// codex 0.162.1 の app-server の stdio から取った行（作業フォルダのパスは置き換え、配列は頭だけ残した）
private enum Fixture {
    static let initialize =
        #"{"id": "tb-g1-init", "result": {"userAgent": "taskboard-probe/0.162.1 (Mac OS 26.7.1; arm64)", "codexHome": "/Users/test/.codex", "platformFamily": "unix", "platformOs": "macos"}}"#
    static let threadStarted =
        #"{"id": 3, "result": {"thread": {"id": "01a155e3-fd51-7280-b5d9-1aa7373b5880", "cliVersion": "0.162.1", "ephemeral": false, "status": {"type": "idle"}, "turns": []}, "model": "gpt-6-astra", "reasoningEffort": "medium"}}"#
    static let failure = #"{"id": "1-4", "error": {"code": -32600, "message": "thread 01a155e3 already has an active writer"}}"#
    static let approval =
        #"{"method": "item/commandExecution/requestApproval", "id": 0, "params": {"kind": "command", "threadId": "01a155e3-fd51-7280-b5d9-1aa7373b5880", "turnId": "01a155e3-ffe8-72e0-a545-f114e4b3b7d8", "itemId": "exec-4de485c8", "startedAtMs": 1792442373503, "environmentId": "local", "command": "/bin/zsh -lc 'touch probe-a.txt'", "cwd": "/tmp/work", "commandActions": [{"type": "unknown", "command": "touch probe-a.txt"}], "proposedExecpolicyAmendment": ["touch", "probe-a.txt"], "availableDecisions": ["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["touch", "probe-a.txt"]}}, "cancel"]}}"#
    static let delta =
        #"{"method": "item/agentMessage/delta", "params": {"threadId": "01a155e3-fd51-7280-b5d9-1aa7373b5880", "turnId": "01a155e3-ffe8-72e0-a545-f114e4b3b7d8", "itemId": "msg_09d0", "delta": "します"}, "emittedAtMs": 1792442372683}"#
    static let resolved = #"{"method": "serverRequest/resolved", "params": {"threadId": "01a155e3-fd51-7280-b5d9-1aa7373b5880", "requestId": 0}, "emittedAtMs": 1792442373507}"#
}

private struct ThreadStartResult: Decodable, Equatable {
    struct Thread: Decodable, Equatable {
        var id: String
        var cliVersion: String
    }
    var thread: Thread
    var model: String
}

private struct DeltaParams: Decodable, Equatable {
    var threadId: String
    var itemId: String
    var delta: String
}

@Suite("codex app-server の 1 行")
struct CodexRPCTests {
    func line(_ text: String) throws -> CodexRPCLine { try #require(CodexRPCLine(Data(text.utf8))) }

    @Test("応答は文字列と数の id のどちらでも読め、result を method ごとの型で読み直せる")
    func responses() throws {
        #expect(try line(Fixture.initialize).kind == .response(id: .string("tb-g1-init")))
        let started = try line(Fixture.threadStarted)
        #expect(started.kind == .response(id: .number(3)))
        #expect(try started.result(ThreadStartResult.self) == ThreadStartResult(thread: .init(id: "01a155e3-fd51-7280-b5d9-1aa7373b5880", cliVersion: "0.162.1"), model: "gpt-6-astra"))
    }

    @Test("断られた応答は code と message を持つ")
    func failure() throws {
        #expect(try line(Fixture.failure).kind == .failure(id: .string("1-4"), code: -32600, message: "thread 01a155e3 already has an active writer"))
    }

    @Test("server の要求と通知を見分け、params を型で読み直せる")
    func requestsAndNotifications() throws {
        #expect(try line(Fixture.approval).kind == .request(id: .number(0), method: "item/commandExecution/requestApproval"))
        let delta = try line(Fixture.delta)
        #expect(delta.kind == .notification(method: "item/agentMessage/delta"))
        #expect(try delta.params(DeltaParams.self) == DeltaParams(threadId: "01a155e3-fd51-7280-b5d9-1aa7373b5880", itemId: "msg_09d0", delta: "します"))
        #expect(try line(Fixture.resolved).kind == .notification(method: "serverRequest/resolved"))
    }

    @Test("JSON の object でない行と、id も method も無い行は読まない")
    func unreadable() {
        for text in ["", "not json", "[1,2]", #"{"result": {}}"#, #"{"id": true, "result": {}}"#] {
            #expect(CodexRPCLine(Data(text.utf8)) == nil, "\(text)")
        }
    }

    @Test("送る要求・通知・答えは 1 行の JSON で、読み直すと同じ id と method になる")
    func encodes() throws {
        struct Params: Codable, Equatable { var threadId: String }
        let request = try CodexRPC.request(id: .string("2-7"), method: "turn/interrupt", params: Params(threadId: "t1"))
        #expect(request.last == UInt8(ascii: "\n") && request.dropLast().contains(UInt8(ascii: "\n")) == false)
        let read = try #require(CodexRPCLine(request.dropLast()))
        #expect(read.kind == .request(id: .string("2-7"), method: "turn/interrupt"))
        #expect(try read.params(Params.self) == Params(threadId: "t1"))

        let notice = try #require(CodexRPCLine(CodexRPC.notification(method: "initialized").dropLast()))
        #expect(notice.kind == .notification(method: "initialized"))

        struct Decision: Codable, Equatable { var decision: String }
        let reply = try #require(CodexRPCLine(try CodexRPC.reply(to: .number(0), result: Decision(decision: "decline")).dropLast()))
        #expect(reply.kind == .response(id: .number(0)))
        #expect(try reply.result(Decision.self) == Decision(decision: "decline"))
    }

    @Test("こちらが振る id は世代と連番で、世代を読み戻せる。server の振った数の id と、形の違う文字列は世代を持たない")
    func issuedIDs() {
        var ids = CodexRequestIDs(generation: 3)
        #expect(ids.next() == .string("3-1"))
        #expect(ids.next() == .string("3-2"))
        #expect(CodexRequestIDs.generation(of: .string("3-2")) == 3)
        #expect(CodexRequestIDs.generation(of: .string("12-40")) == 12)
        for other: CodexRequestID in [.number(0), .string("tb-g1-init"), .string("3-"), .string("-2"), .string("a-1")] {
            #expect(CodexRequestIDs.generation(of: other) == nil, "\(other)")
        }
    }
}
