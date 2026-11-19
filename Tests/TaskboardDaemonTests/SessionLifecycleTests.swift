import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Synchronization
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-test")

private func makeState(clock: @escaping @Sendable () -> Date = { Date() }) -> DaemonState {
    DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"), clock: clock)
}

@Suite("マシンの設定（setting 表）")
struct MachineSettingsStoreTests {
    @Test("行が無ければ Kit の既定。省略した項目は変えず、idleStopMinutes は選択肢以外を弾く")
    func defaultsAndPartialUpdate() throws {
        let store = try Store(inMemory: machine)
        #expect(try store.settings() == MachineSettings.defaults)
        let updated = try store.updateSettings(MachineSettingsUpdate(idleStopMinutes: 30))
        #expect(updated.idleStopMinutes == 30)
        #expect(updated.orchestrator == MachineSettings.defaults.orchestrator)
        let off = try store.updateSettings(MachineSettingsUpdate(orchestratorEnabled: false, orchestratorAgentArgs: ["--model", "sonnet"]))
        #expect(off.orchestrator == .init(enabled: false, agentArgs: ["--model", "sonnet"]))
        #expect(off.idleStopMinutes == 30)
        #expect(try store.settings() == off)
        for bad in [1, -30, 45, 241] {
            #expect(throws: StoreError.self) { try store.updateSettings(MachineSettingsUpdate(idleStopMinutes: bad)) }
        }
        #expect(try store.settings() == off, "弾いた更新は何も書かない")
    }

    @Test("利用枠で区切る使用率は既定が 5 時間 90%・7 日 99%。片方だけ変えられ、1〜100 の外は弾く")
    func usagePauseSettings() throws {
        let store = try Store(inMemory: machine)
        #expect(try store.settings().usagePause == MachineSettings.UsagePause(fiveHourPercent: 90, sevenDayPercent: 99))
        let updated = try store.updateSettings(MachineSettingsUpdate(usagePauseFiveHourPercent: 80))
        #expect(updated.usagePause == MachineSettings.UsagePause(fiveHourPercent: 80, sevenDayPercent: 99))
        #expect(try store.settings().usagePause.sevenDayPercent == 99)
        #expect(try store.updateSettings(MachineSettingsUpdate(usagePauseSevenDayPercent: 100)).usagePause.sevenDayPercent == 100)
        for bad in [0, 101, -1] {
            #expect(throws: StoreError.self) { try store.updateSettings(MachineSettingsUpdate(usagePauseFiveHourPercent: bad)) }
            #expect(throws: StoreError.self) { try store.updateSettings(MachineSettingsUpdate(usagePauseSevenDayPercent: bad)) }
        }
        #expect(try store.settings().usagePause == MachineSettings.UsagePause(fiveHourPercent: 80, sevenDayPercent: 100))
    }

    @Test("紐づけの launchArgs は既定で空。引数付きの紐づけは既存の行の引数をそれにし、引数なしの紐づけは残す")
    func launchArgsOnLinks() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "x"))
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: "/r", label: "")
        #expect(try store.task(number: task.number)?.sessions.first?.launchArgs == [])
        let filled = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: "/r", label: "", launchArgs: ["--model", "opus"])
        #expect(filled.sessions.map(\.launchArgs) == [["--model", "opus"]])
        let replaced = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: "/r", label: "", launchArgs: ["--model", "haiku"])
        #expect(replaced.sessions.map(\.launchArgs) == [["--model", "haiku"]])
        let kept = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: "/r", label: "")
        #expect(kept.sessions.map(\.launchArgs) == [["--model", "haiku"]])
    }
}

@Suite("設定・再開の API")
struct SessionControlAPITests {
    private let auth: HTTPFields = [.authorization: "Bearer t", .contentType: "application/json"]

    private func app(store: Store, state: DaemonState, conversations: ConversationService? = nil) -> APIServer.App {
        var dependencies = testDependencies
        dependencies.store = store
        dependencies.conversations = conversations
        return APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies)
    }

    @Test("GET / PATCH settings。不正な idleStopMinutes は 400 で、更新は state にも載って配られる")
    func settingsRoutes() async throws {
        let store = try Store(inMemory: machine)
        let state = makeState()
        let (id, stream) = await state.subscribe()
        try await app(store: store, state: state).test(.router) { client in
            let get = try await client.execute(uri: "/v1/settings", method: .get, headers: auth)
            #expect(try WireJSON.decoder().decode(MachineSettings.self, from: get.body) == .defaults)
            let bad = try await client.execute(uri: "/v1/settings", method: .patch, headers: auth, body: ByteBuffer(string: #"{"idleStopMinutes":15}"#))
            #expect(bad.status == .badRequest)
            let ok = try await client.execute(uri: "/v1/settings", method: .patch, headers: auth, body: ByteBuffer(string: #"{"idleStopMinutes":0}"#))
            #expect(ok.status == .ok)
            #expect(try WireJSON.decoder().decode(MachineSettings.self, from: ok.body).idleStopMinutes == 0)
        }
        await state.unsubscribe(id)
        var events: [DaemonEvent] = []
        for await event in stream { events.append(event) }
        var expected = MachineSettings.defaults
        expected.idleStopMinutes = 0
        #expect(events == [.settingsUpdated(expected)])
        #expect(await state.snapshot().settings == expected)
    }

    @Test("再開: 紐づけの記録が無ければ 404、タスクが無ければ 404")
    func resumeNotFound() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let body = ByteBuffer(data: try WireJSON.encoder().encode(SessionResumeRequest(agentSessionID: "nope")))
        try await app(store: world.store, state: world.state, conversations: world.service).test(.router) { client in
            let missingRef = try await client.execute(uri: "/v1/tasks/\(world.task)/sessions/resume", method: .post, headers: auth, body: body)
            let missingTask = try await client.execute(uri: "/v1/tasks/999/sessions/resume", method: .post, headers: auth, body: body)
            #expect(missingRef.status == .notFound && missingTask.status == .notFound)
        }
    }
}
