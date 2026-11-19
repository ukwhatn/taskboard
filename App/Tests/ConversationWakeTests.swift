import Foundation
import Synchronization
import TaskboardKit
import Testing
@testable import Taskboard

/// 止まった会話の扱い。人が開いた読む画面は起こしてから読み込み、起こせなかったときだけ帯で知らせる
@MainActor
@Suite struct ConversationWakeTests {
    private let key = ConversationKey(machine: MachineID(rawValue: "studio"), id: "c1")

    private func conversation(_ phase: Conversation.Phase, lastExit: String? = nil) -> Conversation {
        Conversation(
            id: "c1", machine: key.machine, taskNumber: 1, agentSessionID: "s1", cwd: "/w", runner: phase == .stopped ? .none : .host, phase: phase,
            lastExit: lastExit, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func settle(_ until: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !until(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("止まった会話の読む画面は、起こしてから読み込む（起こしている間は読み込み中）")
    func wakesBeforeLoading() async throws {
        let source = WakeSource()
        let feed = ConversationFeed(key: key, fleet: Fleet(), source: source)
        let loads = Mutex<[[String]]>([])
        feed.load(waking: conversation(.stopped)) { loads.withLock { $0.append(source.calls) } }
        guard case .waking = feed.wake else { Issue.record("起こしている間は waking: \(feed.wake)"); return }
        try await settle { !loads.withLock { $0.isEmpty } }
        #expect(source.calls == ["resume"])
        #expect(loads.withLock { $0 } == [["resume"]], "読み込みは起こした後")
        guard case .idle = feed.wake else { Issue.record("起きたら idle: \(feed.wake)"); return }
    }

    @Test("動いている会話は起こさずに読み込む")
    func doesNotWakeRunning() async throws {
        let source = WakeSource()
        let feed = ConversationFeed(key: key, fleet: Fleet(), source: source)
        var loaded = false
        for phase in [Conversation.Phase.idle, .running, .waiting, .starting] {
            feed.load(waking: conversation(phase)) { loaded = true }
            #expect(loaded, "\(phase)")
            loaded = false
        }
        #expect(source.calls.isEmpty)
    }

    @Test("起こせなかったら読み込まずに失敗を出し、次に開いて動いていれば失敗を消す")
    func wakeFailure() async throws {
        let source = WakeSource(failure: SessionSourceError.rejected(DaemonRejection(status: 409, message: "上限")))
        let feed = ConversationFeed(key: key, fleet: Fleet(), source: source)
        var loaded = false
        feed.load(waking: conversation(.stopped)) { loaded = true }
        try await settle { if case .failed = feed.wake { true } else { false } }
        guard case .failed(let failure) = feed.wake else { Issue.record("起こせなかったら failed: \(feed.wake)"); return }
        #expect(failure.event == "会話を起動できませんでした")
        #expect(!loaded)
        feed.load(waking: conversation(.idle)) { loaded = true }
        #expect(loaded)
        guard case .idle = feed.wake else { Issue.record("動いていれば idle: \(feed.wake)"); return }
    }

    @Test("表示用のデータ（供給元が無い）は起こさずに読み込む")
    func fixtureLoadsAsIs() async throws {
        let model = try await ConversationSnapshotTests.loadedModel()
        let feed = model.conversationFeed(for: try ConversationSnapshotTests.key(model, "c-stop"))
        var loaded = false
        feed.load(waking: try #require(model.fleet.conversation(for: feed.key))) { loaded = true }
        #expect(loaded)
    }

    @Test("止まった理由が起こせなかった・予期しない終わりのときだけ、失敗の帯を出す。人や taskboard が止めた会話と動いている会話には出さない")
    func failureBannerOnlyForFailures() {
        func text(_ phase: Conversation.Phase, _ cause: ConversationStopCause?, inTurn: Bool = true) -> String? {
            var stopped = conversation(phase, lastExit: cause?.lastExit)
            if inTurn { stopped.turnStartedAt = Date(timeIntervalSince1970: 0) }
            return stopped.stoppedFailure?.text
        }
        #expect(text(.stopped, .startFailed) == "会話を起動できませんでした。送信すると、起動し直します。")
        #expect(text(.stopped, .unexpected("終了コード 1 で終わった")) == "会話が途中で動かなくなりました。送信すると、起動し直します。")
        #expect(text(.stopped, .unexpected("終了コード 1 で終わった"), inTurn: false) == nil, "入力待ちの間の終わりは失ったものが無い")
        for cause in [ConversationStopCause.person, .closed, .taskboard, .suspended, .idle, .deferred, .finished, .hostRestarted, .hostMissing] {
            #expect(text(.stopped, cause) == nil, "\(cause)")
        }
        #expect(text(.stopped, nil) == nil, "理由の記録が無い")
        #expect(text(.idle, .startFailed) == nil, "起こし直したら帯は消える")
    }
}

/// 起こす口だけを持つ偽物。呼ばれた順を `calls` に控え、`failure` があれば投げる。ほかの口は使われたら失敗する
private final class WakeSource: ConversationSource, @unchecked Sendable {
    private let state = Mutex<[String]>([])
    private let failure: (any Error)?
    init(failure: (any Error)? = nil) { self.failure = failure }
    var calls: [String] { state.withLock { $0 } }

    func resumeConversation(_ id: String) async throws -> Conversation {
        state.withLock { $0.append("resume") }
        if let failure { throw failure }
        return Conversation(
            id: id, machine: MachineID(rawValue: "studio"), taskNumber: 1, agentSessionID: "s1", cwd: "/w", runner: .host, phase: .starting,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    func startConversation(_ body: ConversationStartRequest) async throws -> Conversation { throw SessionSourceError.invalidResponse }
    func sendConversation(_ id: String, _ body: ConversationSendRequest) async throws -> ConversationSendResponse { throw SessionSourceError.invalidResponse }
    func uploadConversationAttachment(_ id: String, data: Data) async throws -> AttachmentUploadResponse { throw SessionSourceError.invalidResponse }
    func uploadConversationFile(_ id: String, data: Data, name: String) async throws -> AttachmentUploadResponse { throw SessionSourceError.invalidResponse }
    func answerConversation(_ id: String, _ body: ConversationAnswerRequest) async throws { throw SessionSourceError.invalidResponse }
    func controlConversation(_ id: String, _ body: ConversationControlRequest) async throws -> ConversationControlResponse { throw SessionSourceError.invalidResponse }
    func stopConversation(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func closeConversation(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func conversationHistory(_ id: String, before: String?, limit: Int, subagents: Bool) async throws -> ConversationHistoryResponse { throw SessionSourceError.invalidResponse }
    func deleteConversation(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func conversationCommands(_ id: String) async throws -> ConversationCommandsResponse { throw SessionSourceError.invalidResponse }
    func conversationWorkFiles(_ id: String, query: String, limit: Int) async throws -> ConversationWorkFilesResponse { throw SessionSourceError.invalidResponse }
    func forkConversation(_ id: String, _ body: ConversationForkRequest) async throws -> Conversation { throw SessionSourceError.invalidResponse }
    func rewindConversation(_ id: String, _ body: ConversationRewindRequest) async throws -> ConversationRewindResponse { throw SessionSourceError.invalidResponse }
    func undoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation { throw SessionSourceError.invalidResponse }
    func redoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation { throw SessionSourceError.invalidResponse }
    func conversationShell(_ id: String) async throws -> ConversationShellResponse { throw SessionSourceError.invalidResponse }
    func stopConversationShell(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func prewarmConversation(_ body: ConversationPrewarmRequest) async throws { throw SessionSourceError.invalidResponse }
    func startConversationRun(_ id: String, _ body: ConversationRunRequest) async throws -> ConversationRun { throw SessionSourceError.invalidResponse }
    func conversationRun(_ id: String, run: String) async throws -> ConversationRun { throw SessionSourceError.invalidResponse }
    func cancelConversationRun(_ id: String, run: String) async throws { throw SessionSourceError.invalidResponse }
    func resetConversationRuns(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func conversationDiff(_ id: String, scope: ConversationDiffScope) async throws -> ConversationDiffResponse { throw SessionSourceError.invalidResponse }
    func conversationFileDiff(_ id: String, path: String, scope: ConversationDiffScope) async throws -> ConversationFileDiffResponse { throw SessionSourceError.invalidResponse }
    func conversationFile(_ id: String, toolID: String, file: ChatFile, part: ChatFile.Part) async throws -> ChatFileContent { throw SessionSourceError.invalidResponse }
    func conversationImage(_ id: String, lineID: String, image: ChatImage) async throws -> Data { throw SessionSourceError.invalidResponse }
}
