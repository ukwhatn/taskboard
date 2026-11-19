import Foundation
import Synchronization
import TaskboardKit
import Testing
@testable import Taskboard

/// 送れなかった発言の自動の送り直し（`ConversationFeed.deliver` と `OutgoingRetry`）
@MainActor
@Suite struct ConversationFeedRetryTests {
    @Test("つながらずに送れなかった発言は、［再送信］を出さずに同じ id で送り直し、通ったら送った印になる")
    func retriesTransientFailures() async throws {
        let source = FlakySendSource(failures: [URLError(.notConnectedToInternet), SessionSourceError.disconnected])
        let feed = ConversationFeed(key: ConversationKey(machine: MachineID(rawValue: "studio"), id: "c1"), fleet: Fleet(), source: source)
        feed.send("送る", images: [])
        let id = try #require(feed.outgoing.first?.clientMessageID)
        let deadline = ContinuousClock.now + .seconds(8)
        while source.sent.count < 3, ContinuousClock.now < deadline {
            #expect(feed.outgoing.first?.state != .failed, "送り直す間は［再送信］を出さない")
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(source.sent == [id, id, id])
        try await Task.sleep(for: .milliseconds(100))
        #expect(feed.outgoing.first?.state == .accepted)
    }

    @Test("daemon が理由を付けて断った発言は送り直さず、すぐ［再送信］を出す")
    func rejectionFailsAtOnce() async throws {
        let source = FlakySendSource(failures: [SessionSourceError.rejected(DaemonRejection(status: 409, message: "止まっている"))])
        let feed = ConversationFeed(key: ConversationKey(machine: MachineID(rawValue: "studio"), id: "c1"), fleet: Fleet(), source: source)
        feed.send("送る", images: [])
        let deadline = ContinuousClock.now + .seconds(2)
        while feed.outgoing.first?.state != .failed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(feed.outgoing.first?.state == .failed)
        try await Task.sleep(for: .milliseconds(1500))
        #expect(source.sent.count == 1)
    }
}

/// 送る口だけを持つ偽物。`failures` を前から順に投げ、尽きたら受ける。ほかの口は使われたら失敗する
private final class FlakySendSource: ConversationSource, @unchecked Sendable {
    private let state: Mutex<(failures: [any Error], sent: [String])>
    init(failures: [any Error]) { state = Mutex((failures, [])) }
    var sent: [String] { state.withLock { $0.sent } }

    func sendConversation(_ id: String, _ body: ConversationSendRequest) async throws -> ConversationSendResponse {
        let failure: (any Error)? = state.withLock {
            $0.sent.append(body.clientMessageID)
            return $0.failures.isEmpty ? nil : $0.failures.removeFirst()
        }
        if let failure { throw failure }
        return ConversationSendResponse(outcome: "accepted")
    }
    func startConversation(_ body: ConversationStartRequest) async throws -> Conversation { throw SessionSourceError.invalidResponse }
    func uploadConversationAttachment(_ id: String, data: Data) async throws -> AttachmentUploadResponse { throw SessionSourceError.invalidResponse }
    func uploadConversationFile(_ id: String, data: Data, name: String) async throws -> AttachmentUploadResponse { throw SessionSourceError.invalidResponse }
    func answerConversation(_ id: String, _ body: ConversationAnswerRequest) async throws { throw SessionSourceError.invalidResponse }
    func controlConversation(_ id: String, _ body: ConversationControlRequest) async throws -> ConversationControlResponse { throw SessionSourceError.invalidResponse }
    func stopConversation(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func closeConversation(_ id: String) async throws { throw SessionSourceError.invalidResponse }
    func resumeConversation(_ id: String) async throws -> Conversation { throw SessionSourceError.invalidResponse }
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
