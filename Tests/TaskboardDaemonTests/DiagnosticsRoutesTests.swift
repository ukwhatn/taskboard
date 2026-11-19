import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("止まりの記録の口")
struct DiagnosticsRoutesTests {
    private let machine = MachineID(rawValue: "m-diagnostics-api")
    private let daemonToken = "daemon-token"

    private func app() async throws -> APIServer.App {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        var dependencies = APIServer.Dependencies()
        dependencies.store = store
        try store.insertDevice(DeviceInfo(id: "d1", name: "iPhone", platform: .ios, createdAt: Date()), tokenHash: DeviceAuth.hash(token: "token-d1"))
        await dependencies.deviceAuth.load(try store.devices())
        return APIServer.application(state: state, token: daemonToken, port: 0, dependencies: dependencies)
    }

    private func report(_ id: String, frames: [String] = ["Taskboard+0x1f2c", "SwiftUI+0x88"]) -> AppDiagnosticReport {
        AppDiagnosticReport(
            id: id, kind: .stall, at: Date(timeIntervalSince1970: 1_800_000_000), durationMS: 4_200, screen: "task.side.chat", appVersion: "0.1.0 (1)",
            osVersion: "iOS 26.0", frames: frames)
    }

    private func post(_ client: some TestClientProtocol, token: String, _ reports: [AppDiagnosticReport]) async throws -> TestResponse {
        let body = ByteBuffer(bytes: try WireJSON.encoder().encode(AppDiagnosticsUpload(reports: reports)))
        return try await client.execute(
            uri: "/v1/devices/current/diagnostics", method: .post, headers: [.authorization: "Bearer \(token)", .contentType: "application/json"], body: body)
    }

    private func result(_ response: TestResponse) throws -> AppDiagnosticsResult {
        try WireJSON.decoder().decode(AppDiagnosticsResult.self, from: response.body)
    }

    @Test("端末の token なら残した数を返し、同じ id をもう一度送っても残さない")
    func logsOncePerID() async throws {
        try await app().test(.router) { client in
            let first = try await post(client, token: "token-d1", [report("a"), report("b"), report("a")])
            #expect(first.status == .ok)
            #expect(try result(first) == AppDiagnosticsResult(logged: 2, skipped: 1))
            let again = try await post(client, token: "token-d1", [report("b"), report("c")])
            #expect(try result(again) == AppDiagnosticsResult(logged: 1, skipped: 1))
        }
    }

    @Test("daemon の token、空の reports、上限を越えた件数と欄は 400")
    func rejectsInvalid() async throws {
        try await app().test(.router) { client in
            let byDaemon = try await post(client, token: daemonToken, [report("a")])
            #expect(byDaemon.status == .badRequest)
            #expect(String(buffer: byDaemon.body).contains("端末の token で呼ぶ"))
            let tooMany = (0...AppDiagnosticsUpload.reportLimit).map { report("r\($0)") }
            for reports in [
                [], tooMany, [report("")], [report(String(repeating: "x", count: 65))],
                [report("f", frames: Array(repeating: "Taskboard+0x1", count: 41))], [report("g", frames: [String(repeating: "あ", count: 161)])],
            ] {
                #expect(try await post(client, token: "token-d1", reports).status == .badRequest)
            }
            #expect(try await post(client, token: "token-x", [report("a")]).status == .unauthorized)
        }
    }

    @Test("端末ごとに 1 時間に 30 件まで残し、1 時間たつとまた残す。別の端末は別に数える")
    func limitsPerDeviceAndHour() async {
        final class Now: @unchecked Sendable {
            var date = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let now = Now()
        let gate = AppDiagnosticsGate(now: { now.date })
        let first = await gate.admit((0..<20).map { report("a\($0)") }, device: "d1")
        let second = await gate.admit((0..<20).map { report("b\($0)") }, device: "d1")
        #expect(first.admitted.count == 20)
        #expect(second.admitted.count == 10)
        #expect(second.skipped == 10)
        #expect(await gate.admit([report("other")], device: "d2").admitted.count == 1)
        now.date += 3601
        #expect(await gate.admit([report("b19")], device: "d1").admitted.map(\.id) == ["b19"], "上限で残さなかった id は、後で届けば残す")
    }

    @Test("ログの欄は 1 行に収め、改行と制御文字を空白にする")
    func metadataStaysOnOneLine() {
        let metadata = APIServer.diagnosticsMetadata(report("x\ny", frames: ["Taskboard+0x1\n", "UIKit\t+0x2"]), device: "d1")
        let text = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        #expect(!text.contains("\n") && !text.contains("\t"))
        #expect(metadata["frames"] == .string("Taskboard+0x1  < UIKit +0x2"))
        #expect(metadata["ms"] == .stringConvertible(4_200))
        #expect(metadata["device"] == .string("d1"))
    }
}
