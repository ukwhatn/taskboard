import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("セッションの紐づけを外す")
struct SessionUnlinkRoutesTests {
    private let machine = MachineID(rawValue: "m-unlink")
    private let daemonToken = "daemon-token"

    private func fixture() throws -> (DaemonState, Store, BoardTask, APIServer.App) {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let created = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x"))
        _ = try store.linkSession(task: created.number, agent: "claude", sessionID: "s-keep", cwd: "/w", label: "")
        let task = try store.linkSession(task: created.number, agent: "claude", sessionID: "s-drop", cwd: "/w", label: "")
        var dependencies = testDependencies
        dependencies.store = store
        return (state, store, task, APIServer.application(state: state, token: daemonToken, port: 0, dependencies: dependencies))
    }

    @Test("Store: 指定したセッションの行だけを消し、無い紐づけと無いタスクは断る")
    func storeUnlinks() throws {
        let (_, store, task, _) = try fixture()
        let left = try store.unlinkSession(task: task.number, sessionID: "s-drop")
        #expect(left.sessions.map(\.sessionID) == ["s-keep"])
        #expect(try store.task(linkedToSession: "s-drop") == nil)
        #expect(throws: StoreError.self) { try store.unlinkSession(task: task.number, sessionID: "s-drop") }
        #expect(throws: StoreError.taskNotFound(999)) { try store.unlinkSession(task: 999, sessionID: "s-keep") }
    }

    @Test("DELETE /v1/tasks/{n}/sessions/{id} は外した後のタスクを返して state に載せる。無い紐づけは 404")
    func routeUnlinks() async throws {
        let (state, _, task, app) = try fixture()
        await state.upsert(task)
        let token = daemonToken
        try await app.test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/tasks/\(task.number)/sessions/s-drop", method: .delete, headers: [.authorization: "Bearer \(token)"])
            #expect(response.status == .ok)
            #expect(try WireJSON.decoder().decode(BoardTask.self, from: response.body).sessions.map(\.sessionID) == ["s-keep"])
            #expect(await state.task(number: task.number)?.sessions.map(\.sessionID) == ["s-keep"])

            let again = try await client.execute(
                uri: "/v1/tasks/\(task.number)/sessions/s-drop", method: .delete, headers: [.authorization: "Bearer \(token)"])
            #expect(again.status == .notFound)
        }
    }
}
