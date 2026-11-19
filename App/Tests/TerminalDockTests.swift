import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 端末の欄（会話の作業フォルダのシェル）の開け閉め。fixtures `stress` の 1 台を、会話のシェルだけ受ける供給元に替えて回す
@MainActor
@Suite(.serialized) struct TerminalDockTests {
    private func model() async throws -> (AppModel, ConversationRecorder) {
        AppDefaults.useScratch("test-terminal-dock")
        let model = AppModel(options: LaunchOptions(scenario: "stress"))
        let recorder = ConversationRecorder(base: try FixtureSource.named("stress"))
        model.fleet.add(id: "fixture:stress", source: recorder)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.conversationSource(for: recorder.base.initial.machine.id) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return (model, recorder)
    }

    private let machine = MachineID(rawValue: "fixture-studio")
    private var owner: ConversationKey { ConversationKey(machine: machine, id: "c-1") }
    private var shell: TerminalDockState { .shown(TerminalKey(machine: machine, pane: PaneID(rawValue: "w1:p2"))) }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "待っている様子にならない")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("会話の端末の欄を開くと作業フォルダのシェルを起こして出し、もう一度押すと閉じてシェルを止める。次に開くと起こし直す")
    func toggleStartsAndStopsShell() async throws {
        let (model, recorder) = try await model()
        model.toggleTerminal(for: owner)
        #expect({ if case .starting = model.terminalDock(for: owner) { true } else { false } }())
        try await waitFor { model.terminalDock(for: owner) == shell }
        #expect(recorder.shells == ["c-1"])

        model.toggleTerminal(for: owner)
        #expect(model.terminalDock(for: owner) == nil)
        try await waitFor { recorder.stoppedShells == ["c-1"] }

        model.openTerminal(for: owner)
        try await waitFor { model.terminalDock(for: owner) == shell }
        #expect(recorder.shells == ["c-1", "c-1"])
    }

    @Test("起こせなければわけを出し、［やり直す］で起こし直す。起こしている間に閉じると、届いたシェルを出さずに止める")
    func failureAndCloseWhileStarting() async throws {
        let (model, recorder) = try await model()
        recorder.shellFailure = URLError(.timedOut)
        model.openTerminal(for: owner)
        try await waitFor { if case .failed = model.terminalDock(for: owner) { true } else { false } }
        guard case .failed(let failure) = model.terminalDock(for: owner) else { return }
        #expect(failure.event == "シェルを起動できませんでした")

        recorder.shellFailure = nil
        model.openTerminal(for: owner)
        try await waitFor { model.terminalDock(for: owner) == shell }

        model.closeTerminal(of: owner)
        recorder.shellDelay = .milliseconds(200)
        model.openTerminal(for: owner)
        model.closeTerminal(of: owner)
        try await waitFor { recorder.stoppedShells.count == 2 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.terminalDock(for: owner) == nil)
        #expect(model.terminalDocks[owner] == nil)
    }
}
