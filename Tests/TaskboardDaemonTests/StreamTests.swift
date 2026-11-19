import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("1 本の接続（/v1/stream）：状態の控えと続き")
struct StreamTests {
    private let machine = MachineID(rawValue: "m-stream")

    private func makeState(journal: StreamJournal = StreamJournal()) -> DaemonState {
        DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"), journal: journal, epoch: "e1")
    }

    /// 送り口を閉じて、積まれた分を全部読む
    private func drain(_ outbox: StreamOutbox) async throws -> [StreamServerFrame] {
        outbox.finish()
        var frames: [StreamServerFrame] = []
        for await frame in outbox.frames { frames.append(try WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data)) }
        return frames
    }

    private func text(_ values: String...) -> [Data] { values.map { Data($0.utf8) } }

    // MARK: 控え

    @Test("控え：番号は 1 ずつ増え、続きは after より後だけ。件数の上限で古い方から落とし、今より先と落ちた所より前は nil")
    func journalCount() {
        var journal = StreamJournal(countLimit: 3, byteLimit: 1 << 20)
        #expect(journal.frames(after: 0) == [])
        for n in 1...5 {
            #expect(journal.nextRev() == n)
            journal.append(Data("f\(n)".utf8))
        }
        #expect(journal.rev == 5 && journal.base == 2)
        #expect(journal.frames(after: 2) == text("f3", "f4", "f5"))
        #expect(journal.frames(after: 4) == text("f5"))
        #expect(journal.frames(after: 5) == [])
        #expect(journal.frames(after: 1) == nil)
        #expect(journal.frames(after: 6) == nil)
    }

    @Test("控え：大きさの上限を超えたら古い方から落とし、上限より大きい 1 通は残さない。空にした後は、その番号より前の続きを返さない")
    func journalBytes() {
        var journal = StreamJournal(countLimit: 100, byteLimit: 10)
        journal.append(Data(repeating: 1, count: 4))
        journal.append(Data(repeating: 2, count: 4))
        journal.append(Data(repeating: 3, count: 4))
        #expect(journal.base == 1 && journal.frames(after: 1)?.count == 2)
        journal.append(Data(repeating: 4, count: 11))
        #expect(journal.base == 4 && journal.frames(after: 4) == [] && journal.frames(after: 3) == nil)
        journal.reset()
        #expect(journal.rev == 5 && journal.frames(after: 4) == nil && journal.frames(after: 5) == [])
        journal.append(Data("後".utf8))
        #expect(journal.frames(after: 5) == text("後"))
    }

    // MARK: DaemonState

    @Test("hello に番号が無ければ全体。同じ起動の番号なら resume と続き。起動が違う番号は全体")
    func open() async throws {
        let state = makeState()
        await state.setAgentHost(AgentHostInfo(connected: false))
        await state.setAgentHost(AgentHostInfo(connected: true))

        let fresh = StreamOutbox()
        _ = await state.openStream(epoch: nil, after: nil, outbox: fresh)
        let first = try await drain(fresh)
        guard case .state(let epoch, let rev, let snapshot)? = first.first, first.count == 1 else {
            Issue.record("\(first)")
            return
        }
        #expect(epoch == "e1" && rev == 2 && snapshot.machine.agentHost?.connected == true)

        let resumed = StreamOutbox()
        _ = await state.openStream(epoch: "e1", after: 1, outbox: resumed)
        let frames = try await drain(resumed)
        #expect(frames.first == .resume(epoch: "e1", rev: 1) && frames.count == 2)
        if case .event(let rev, .machineUpdated(let info))? = frames.last {
            #expect(rev == 2 && info.agentHost?.connected == true)
        } else {
            Issue.record("\(frames)")
        }

        let otherBoot = StreamOutbox()
        _ = await state.openStream(epoch: "e0", after: 1, outbox: otherBoot)
        #expect(try await drain(otherBoot).map(\.kind) == ["state"])

        let current = StreamOutbox()
        _ = await state.openStream(epoch: "e1", after: 2, outbox: current)
        #expect(try await drain(current) == [.resume(epoch: "e1", rev: 2)])
    }

    @Test("繋いだ後の出来事は番号の順に届く。読まずに送り口の上限を超えたら閉じて、配り先から外れる")
    func live() async throws {
        let state = makeState()
        let outbox = StreamOutbox(byteLimit: 4096)
        _ = await state.openStream(epoch: nil, after: nil, outbox: outbox)
        var iterator = outbox.frames.makeAsyncIterator()
        func next() async throws -> StreamServerFrame? {
            guard let frame = await iterator.next() else { return nil }
            outbox.sent(frame)
            return try WireJSON.decoder().decode(StreamServerFrame.self, from: frame.data)
        }
        #expect(try await next()?.kind == "state")
        await state.setAgentHost(AgentHostInfo(connected: false))
        await state.setAgentHost(AgentHostInfo(connected: true))
        #expect(try await next()?.rev == 1)
        #expect(try await next()?.rev == 2)
        #expect(await state.streamCount == 1)

        for n in 0..<200 { await state.setAgentHost(AgentHostInfo(connected: n % 2 == 0)) }
        #expect(outbox.isOverflowed)
        #expect(await state.streamCount == 0)
    }

    @Test("空の送り口には上限より大きい 1 通も積み、積んだまま次が来て上限を超えたら閉じる")
    func outboxLimit() {
        let outbox = StreamOutbox(byteLimit: 10)
        #expect(outbox.push(Data(repeating: 0, count: 20)))
        #expect(!outbox.push(Data(repeating: 0, count: 1)))
        #expect(outbox.isClosed && outbox.isOverflowed)

        let conversations = StreamOutbox(byteLimit: 100)
        conversations.push(Data("a".utf8), conversation: "c1")
        conversations.push(Data("b".utf8), conversation: "c1")
        conversations.push(Data("c".utf8))
        #expect(conversations.pending(conversation: "c1") == 2)
        conversations.sent(.init(data: Data("a".utf8), conversation: "c1"))
        #expect(conversations.pending(conversation: "c1") == 1 && conversations.pending(conversation: "c2") == 0)
    }

    // MARK: WebSocket

    private func socket(port: Int, token: String?) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "ws://localhost:\(port)/v1/stream")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        return task
    }

    private func send(_ task: URLSessionWebSocketTask, _ message: StreamClientMessage) async throws {
        try await task.send(.string(String(decoding: try WireJSON.encoder().encode(message), as: UTF8.self)))
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> StreamServerFrame {
        guard case .string(let text) = try await task.receive() else { throw CancellationError() }
        return try WireJSON.decoder().decode(StreamServerFrame.self, from: Data(text.utf8))
    }

    @Test("hello の前の subscribe は読み捨て、hello で state を送る。会話の host が無ければ subscribe に missing を返す。同じ起動の番号で繋ぎ直すと resume と続き")
    func webSocket() async throws {
        let state = makeState()
        let app = APIServer.application(state: state, token: "secret-token", port: 0, dependencies: testDependencies)
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let first = socket(port: port, token: "secret-token")
            try await send(first, .subscribe(conversation: "c-early", epoch: nil, after: 0))
            try await send(first, .hello(epoch: nil, rev: nil))
            let opened = try await receive(first)
            #expect(opened.kind == "state" && opened.rev == 0)
            try await send(first, .subscribe(conversation: "c1", epoch: nil, after: 0))
            #expect(try await receive(first) == .unsubscribed(conversation: "c1", reason: StreamServerFrame.missing))
            await state.setAgentHost(AgentHostInfo(connected: false))
            #expect(try await receive(first).rev == 1)
            first.cancel(with: .goingAway, reason: nil)

            await state.setAgentHost(AgentHostInfo(connected: true))
            let second = socket(port: port, token: "secret-token")
            try await send(second, .hello(epoch: "e1", rev: 1))
            #expect(try await receive(second) == .resume(epoch: "e1", rev: 1))
            #expect(try await receive(second).rev == 2)
            second.cancel(with: .goingAway, reason: nil)
        }
    }
}

extension StreamServerFrame {
    fileprivate var kind: String {
        switch self {
        case .state: "state"
        case .resume: "resume"
        case .event: "event"
        case .subscribed: "subscribed"
        case .conversation: "conversation"
        case .unsubscribed: "unsubscribed"
        }
    }

    fileprivate var rev: Int? {
        switch self {
        case .state(_, let rev, _), .resume(_, let rev), .event(let rev, _): rev
        default: nil
        }
    }
}
