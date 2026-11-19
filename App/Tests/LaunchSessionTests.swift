import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 状態は fixtures のまま、会話の起動と会話のシェルだけを受けて要求を控える供給元。端末の起動（`DaemonWriter`）は受けない
final class ConversationRecorder: SnapshotSource, ConversationSource, @unchecked Sendable {
    struct Unused: Error {}

    let base: FixtureSource
    /// マシンが知らせる codex の版（Codex の会話を起こせる daemon か）。nil は古い daemon か codex の無いマシン
    let codexCLI: CLIVersionStatus?
    private let lock = NSLock()
    private var requests: [ConversationStartRequest] = []
    private var shellRequests: [String] = []
    private var shellStops: [String] = []
    /// 会話のシェルの口が返す pane。`shellFailure` があれば投げる。`shellDelay` だけ待ってから返す
    var shellPane = PaneID(rawValue: "w1:p2")
    var shellFailure: (any Error)?
    var shellDelay: Duration = .zero

    init(base: FixtureSource, codexCLI: CLIVersionStatus? = nil) {
        self.base = base
        self.codexCLI = codexCLI
    }

    var started: [ConversationStartRequest] { lock.withLock { requests } }
    var shells: [String] { lock.withLock { shellRequests } }
    var stoppedShells: [String] { lock.withLock { shellStops } }
    /// 閉じた依頼（`<会話>/<依頼>/<action>/<text>`）

    func snapshot() async throws -> StateSnapshot {
        var snapshot = try await base.snapshot()
        snapshot.machine.codexCLI = codexCLI
        return snapshot
    }
    func events() -> AsyncThrowingStream<DaemonEvent, any Error> { base.events() }

    func startConversation(_ body: ConversationStartRequest) async throws -> Conversation {
        lock.withLock { requests.append(body) }
        let now = Date()
        return Conversation(
            id: "c-\(started.count)", machine: base.initial.machine.id, taskNumber: body.taskNumber, agentSessionID: "s-1", cwd: body.cwd,
            runner: .host, phase: .starting, createdAt: now, updatedAt: now)
    }

    func sendConversation(_ id: String, _ body: ConversationSendRequest) async throws -> ConversationSendResponse { throw Unused() }
    func uploadConversationAttachment(_ id: String, data: Data) async throws -> AttachmentUploadResponse { throw Unused() }
    func uploadConversationFile(_ id: String, data: Data, name: String) async throws -> AttachmentUploadResponse { throw Unused() }
    func answerConversation(_ id: String, _ body: ConversationAnswerRequest) async throws { throw Unused() }
    func controlConversation(_ id: String, _ body: ConversationControlRequest) async throws -> ConversationControlResponse { throw Unused() }
    func stopConversation(_ id: String) async throws { throw Unused() }
    func closeConversation(_ id: String) async throws { throw Unused() }
    func resumeConversation(_ id: String) async throws -> Conversation { throw Unused() }
    func conversationHistory(_ id: String, before: String?, limit: Int, subagents: Bool) async throws -> ConversationHistoryResponse { throw Unused() }
    func deleteConversation(_ id: String) async throws { throw Unused() }
    func conversationCommands(_ id: String) async throws -> ConversationCommandsResponse { throw Unused() }
    func conversationWorkFiles(_ id: String, query: String, limit: Int) async throws -> ConversationWorkFilesResponse { throw Unused() }
    func forkConversation(_ id: String, _ body: ConversationForkRequest) async throws -> Conversation { throw Unused() }
    func rewindConversation(_ id: String, _ body: ConversationRewindRequest) async throws -> ConversationRewindResponse { throw Unused() }
    func undoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation { throw Unused() }
    func redoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation { throw Unused() }
    func conversationShell(_ id: String) async throws -> ConversationShellResponse {
        let (delay, failure, pane) = lock.withLock {
            shellRequests.append(id)
            return (shellDelay, shellFailure, shellPane)
        }
        try await Task.sleep(for: delay)
        if let failure { throw failure }
        return ConversationShellResponse(pane: pane)
    }
    func stopConversationShell(_ id: String) async throws { lock.withLock { shellStops.append(id) } }
    func prewarmConversation(_ body: ConversationPrewarmRequest) async throws { throw Unused() }
    func startConversationRun(_ id: String, _ body: ConversationRunRequest) async throws -> ConversationRun { throw Unused() }
    func conversationRun(_ id: String, run: String) async throws -> ConversationRun { throw Unused() }
    func cancelConversationRun(_ id: String, run: String) async throws { throw Unused() }
    func resetConversationRuns(_ id: String) async throws { throw Unused() }
    func conversationDiff(_ id: String, scope: ConversationDiffScope) async throws -> ConversationDiffResponse { throw Unused() }
    func conversationFileDiff(_ id: String, path: String, scope: ConversationDiffScope) async throws -> ConversationFileDiffResponse { throw Unused() }
    func conversationFile(_ id: String, toolID: String, file: ChatFile, part: ChatFile.Part) async throws -> ChatFileContent { throw Unused() }
    func conversationImage(_ id: String, lineID: String, image: ChatImage) async throws -> Data { throw Unused() }
}

/// 起動のシート・起票のシート・debug の口が通る `AppModel.launchSession` の振り分け。fixtures `stress` の 1 台を、会話だけ起こせる供給元に替えて回す
@MainActor
@Suite(.serialized) struct LaunchSessionTests {
    private func model(codexCLI: CLIVersionStatus? = nil) async throws -> (AppModel, ConversationRecorder) {
        AppDefaults.useScratch("test-launch-session")
        let model = AppModel(options: LaunchOptions(scenario: "stress"))
        let recorder = ConversationRecorder(base: try FixtureSource.named("stress"), codexCLI: codexCLI)
        model.fleet.add(id: "fixture:stress", source: recorder)
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || model.fleet.conversationSource(for: recorder.base.initial.machine.id) == nil
            || model.fleet.machineState(for: recorder.base.initial.machine.id)?.machine?.codexCLI != codexCLI
        {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return (model, recorder)
    }

    private func task(on board: Board, _ model: AppModel) throws -> BoardTask {
        try #require(model.fleet.tasks(onBoard: board.id, machine: board.machine).first)
    }

    @Test("起票のシートの下書きのまま起こすと、会話をタスクの番号つきで起こし、タスクのパネルで開く先にする")
    func newTaskDraftStartsConversation() async throws {
        let (model, recorder) = try await model()
        let board = model.fleet.allBoards[0]
        let task = try task(on: board, model)
        let conversation = try await model.launchSession(task: task, NewTaskDraft(board: board).launch)
        #expect(recorder.started.map(\.taskNumber) == [task.number])
        #expect(model.sessionFocus == SessionFocus(scope: .task(task.id), item: conversation.key))
    }

    @Test("codex の版を知らせるマシンでは、Codex も会話で起こす。engine は codex、モデルと effort は選んだ codex の値（選ばなければ daemon の既定）。事前起動はしない")
    func codexConversation() async throws {
        let (model, recorder) = try await model(codexCLI: CLIVersionStatus(using: "0.130.0", newest: "0.130.0"))
        let board = model.fleet.allBoards[0]
        let task = try task(on: board, model)
        var picked = NewTaskDraft(board: board).launch
        picked.choice.select(kind: .codex)
        picked.choice.select(codexModel: "gpt-5.5-codex")
        picked.choice.select(codexEffort: "high")
        #expect(picked.request().agentArgs == ["--model", "gpt-5.5-codex", "-c", "model_reasoning_effort=high"], "端末で起こすときは codex の引数で渡す")
        var standard = NewTaskDraft(board: board).launch
        standard.choice.select(kind: .codex)
        #expect(picked.prewarmTarget == nil && standard.prewarmTarget == nil)
        for draft in [picked, standard] {
            _ = try await model.launchSession(task: task, draft)
        }
        #expect(recorder.started.map(\.engine) == [.codex, .codex])
        #expect(recorder.started.map(\.model) == ["gpt-5.5-codex", nil])
        #expect(recorder.started.map(\.effort) == ["high", nil])
        #expect(recorder.started.allSatisfy { $0.permissionMode == nil && $0.taskNumber == task.number })
    }

    @Test("Claude Code の会話の要求は engine を省く（engine を知らない古い daemon にも同じ形で届く）")
    func claudeConversationOmitsEngine() async throws {
        let (model, recorder) = try await model(codexCLI: CLIVersionStatus(using: "0.130.0", newest: "0.130.0"))
        let board = model.fleet.allBoards[0]
        _ = try await model.launchSession(task: try task(on: board, model), NewTaskDraft(board: board).launch)
        #expect(recorder.started.map(\.engine) == [nil])
    }
}
