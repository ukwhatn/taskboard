import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// オーケストレーターの画面の、止まっているときの 2 つの形。fixtures `stress` に Mac mini を足す。
/// `machine-second-resident`（常駐がオンで起きておらず、常駐の見張りが起こせなかった: 失敗の帯と空状態）、
/// `machine-second-off`（常駐オフで、Ctrl+C の後にシェルに戻った pane だけが残る: 「常駐オフ・未起動」と空状態）。
/// TUI で動いているときの中身は `SessionBody`（チャット・端末）で、fixtures は端末を持たないので撮らない。会話で動いているときは fixtures `conversations` の `c-orch`
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct OrchestratorScreenSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests
    private let secondMac = MachineID(rawValue: "fixture-second")

    private func model(_ scenario: String) async throws -> AppModel {
        AppDefaults.useScratch("snapshot-orchestrator-screen")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.orchestratorRows.count < 2 {
            try #require(ContinuousClock.now < deadline, "fixtures \(scenario) を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(model.fleet.orchestratorConversation(on: secondMac) == nil, "fixtures の Mac mini でオーケストレーターが動いている")
        return model
    }

    @Test("常駐がオンで起こせなかったとき（失敗の帯・空状態と［起動］）", arguments: Matrix.cases([420, 1000]))
    func residentFailed(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await model("stress+machine-second-resident")
        let view = NavigationStack { OrchestratorScreen(machine: secondMac) }.environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 560), variant: appearance), named: name)
    }

    @Test("常駐オフで止まっているとき（「常駐オフ・未起動」・常駐の切り替えはオフ）", arguments: Matrix.cases([420, 1000]))
    func residentOff(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await model("stress+machine-second-off")
        let view = NavigationStack { OrchestratorScreen(machine: secondMac) }.environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 560), variant: appearance), named: name)
    }

    @Test("会話で動いているとき（fixtures conversations の c-orch。会話の画面を載せる）", arguments: Matrix.cases([560]))
    func conversation(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await ConversationSnapshotTests.loadedModel()
        let machine = try #require(model.fleet.allBoards.first?.machine)
        try #require(model.orchestratorConversation(on: machine)?.id == "c-orch", "fixtures のオーケストレーターが会話で動いていない")
        let view = NavigationStack { OrchestratorScreen(machine: machine) }.environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }
}
