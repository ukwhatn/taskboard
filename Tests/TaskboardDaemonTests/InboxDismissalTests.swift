import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("受信箱で消した項目の記録")
struct InboxDismissalTests {
    private let machine = MachineID(rawValue: "m-test")
    private let daemonToken = "daemon-token"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ revision: String = "") -> InboxDismissRequest.Item {
        InboxDismissRequest.Item(itemID: id, revision: revision)
    }

    // MARK: Store

    @Test("記録すると全部を返し、同じ項目は revision と時刻を置き換える")
    func dismissUpserts() throws {
        let store = try Store(inMemory: machine)
        let first = try store.dismissInbox([item("blocked/p1", "100"), item("doc/3/1")], now: start)
        #expect(first.map(\.itemID) == ["blocked/p1", "doc/3/1"])
        let later = start.addingTimeInterval(60)
        let second = try store.dismissInbox([item("blocked/p1", "200")], now: later)
        #expect(second.count == 2)
        let blocked = try #require(second.first { $0.itemID == "blocked/p1" })
        #expect(blocked.revision == "200")
        #expect(blocked.dismissedAt == later)
        #expect(try store.inboxDismissals() == second)
    }

    @Test("戻すと記録が消え、記録の無い項目は飛ばす")
    func restoreRemoves() throws {
        let store = try Store(inMemory: machine)
        _ = try store.dismissInbox([item("ask/1"), item("work/2", "50")], now: start)
        let left = try store.restoreInbox(itemIDs: ["ask/1", "ask/999"])
        #expect(left.map(\.itemID) == ["work/2"])
    }

    @Test("30 日より古い記録は次に書くときに捨てる")
    func prunesOldRecords() throws {
        let store = try Store(inMemory: machine)
        _ = try store.dismissInbox([item("old")], now: start)
        let records = try store.dismissInbox([item("new")], now: start.addingTimeInterval(30 * 24 * 3600 + 1))
        #expect(records.map(\.itemID) == ["new"])
    }

    @Test("空・多すぎる・長すぎる要求は断る")
    func rejectsInvalid() throws {
        let store = try Store(inMemory: machine)
        #expect(throws: StoreError.self) { try store.dismissInbox([]) }
        #expect(throws: StoreError.self) { try store.dismissInbox([item("")]) }
        #expect(throws: StoreError.self) { try store.dismissInbox([item(String(repeating: "あ", count: InboxDismissal.itemIDLimit + 1))]) }
        #expect(throws: StoreError.self) { try store.dismissInbox([item("a", String(repeating: "x", count: InboxDismissal.revisionLimit + 1))]) }
        #expect(throws: StoreError.self) {
            try store.dismissInbox((0...InboxDismissal.batchLimit).map { item("doc/\($0)/1") })
        }
        #expect(try store.inboxDismissals().isEmpty)
    }

    @Test("開き直しても記録が残り、migration は 2 回目に走らない")
    func survivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-inbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appending(path: "taskboard.db")
        let backups = dir.appending(path: "backups")
        do {
            let store = try Store(databaseURL: db, backupDirectory: backups, machineID: machine)
            _ = try store.dismissInbox([item("prturn/https://github.com/o/r/pull/1", "reviewRequested@1800000000")], now: start)
            try store.close()
        }
        for _ in 0..<2 {
            let reopened = try Store(databaseURL: db, backupDirectory: backups, machineID: machine)
            #expect(try reopened.inboxDismissals().map(\.revision) == ["reviewRequested@1800000000"])
            #expect(try Store.listBackups(in: backups).isEmpty)
            try reopened.close()
        }
    }

    // MARK: API

    private struct Fixture {
        let state: DaemonState
        let store: Store
        let dependencies: APIServer.Dependencies
    }

    private func makeFixture() throws -> Fixture {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        var dependencies = testDependencies
        dependencies.store = store
        return Fixture(state: state, store: store, dependencies: dependencies)
    }

    private func app(_ fixture: Fixture) -> APIServer.App {
        APIServer.application(state: fixture.state, token: daemonToken, port: 0, dependencies: fixture.dependencies)
    }

    private func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    private func json<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(bytes: try WireJSON.encoder().encode(value)) }

    /// ペアリングして端末の token を取る
    private func deviceToken(_ client: some TestClientProtocol) async throws -> String {
        let created = try await client.execute(uri: "/v1/pairings", method: .post, headers: bearer(daemonToken), body: ByteBuffer(string: "{}"))
        let code = try WireJSON.decoder().decode(PairingCode.self, from: created.body)
        let payload = try JSONSerialization.data(withJSONObject: ["code": code.code, "name": "iPhone", "platform": "ios"])
        let paired = try await client.execute(
            uri: "/v1/pair", method: .post,
            headers: [.contentType: "application/json", HTTPField.Name("CF-Connecting-IP")!: "203.0.113.1"], body: ByteBuffer(bytes: payload))
        #expect(paired.status == .ok)
        return try WireJSON.decoder().decode(PairResponse.self, from: paired.body).token
    }

    @Test("端末の token で記録・戻すができ、/v1/state に載る")
    func deviceTokenRoundTrip() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let token = try await deviceToken(client)
            let dismissed = try await client.execute(
                uri: "/v1/inbox/dismiss", method: .post, headers: bearer(token),
                body: try json(InboxDismissRequest(items: [item("blocked/p1", "100"), item("doc/3/1")])))
            #expect(dismissed.status == .ok)
            #expect(try WireJSON.decoder().decode([InboxDismissal].self, from: dismissed.body).map(\.itemID) == ["blocked/p1", "doc/3/1"])

            let state = try await client.execute(uri: "/v1/state", method: .get, headers: bearer(token))
            let snapshot = try WireJSON.decoder().decode(StateSnapshot.self, from: state.body)
            #expect(Set(snapshot.inboxDismissals.map(\.itemID)) == ["blocked/p1", "doc/3/1"])

            let restored = try await client.execute(
                uri: "/v1/inbox/restore", method: .post, headers: bearer(token), body: try json(InboxRestoreRequest(itemIDs: ["blocked/p1"])))
            #expect(restored.status == .ok)
            #expect(try WireJSON.decoder().decode([InboxDismissal].self, from: restored.body).map(\.itemID) == ["doc/3/1"])

            let listed = try await client.execute(uri: "/v1/inbox/dismissals", method: .get, headers: bearer(token))
            #expect(try WireJSON.decoder().decode([InboxDismissal].self, from: listed.body).map(\.itemID) == ["doc/3/1"])
        }
    }

    @Test("空の要求は 400")
    func emptyRequestIsBadRequest() async throws {
        let fixture = try makeFixture()
        try await app(fixture).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/inbox/dismiss", method: .post, headers: bearer(daemonToken), body: try json(InboxDismissRequest(items: [])))
            #expect(response.status == .badRequest)
        }
    }

    @Test("記録と戻すたびに inbox.dismissals_updated で全部を配る")
    func broadcastsUpdates() async throws {
        let fixture = try makeFixture()
        let (id, stream) = await fixture.state.subscribe()
        try await app(fixture).test(.router) { client in
            _ = try await client.execute(
                uri: "/v1/inbox/dismiss", method: .post, headers: bearer(daemonToken), body: try json(InboxDismissRequest(items: [item("ask/1")])))
            _ = try await client.execute(
                uri: "/v1/inbox/restore", method: .post, headers: bearer(daemonToken), body: try json(InboxRestoreRequest(itemIDs: ["ask/1"])))
        }
        await fixture.state.unsubscribe(id)
        var updates: [[InboxDismissal]] = []
        for await event in stream { if case .inboxDismissalsUpdated(let records) = event { updates.append(records) } }
        #expect(updates.map { $0.map(\.itemID) } == [["ask/1"], []])
    }

    @Test("イベントは名前と中身を往復できる")
    func eventRoundTrip() throws {
        let event = DaemonEvent.inboxDismissalsUpdated([InboxDismissal(itemID: "ask/1", revision: "", dismissedAt: start)])
        let data = try WireJSON.encoder().encode(event)
        #expect(String(decoding: data, as: UTF8.self).contains("\"inbox.dismissals_updated\""))
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: data) == event)
    }
}
