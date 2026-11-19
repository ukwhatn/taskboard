import Foundation

/// `/v1/stream` の 1 本の接続。本番は `DaemonStreamConnection`、テストは台本どおりに送る偽物
public protocol StreamConnection: Sendable {
    var frames: AsyncThrowingStream<StreamServerFrame, any Error> { get }
    func send(_ message: StreamClientMessage) async throws
    func close()
}

extension DaemonStreamConnection: StreamConnection {}

/// 状態と会話の出来事を 1 本の接続で送れる供給元。E1 までの daemon は upgrade を 404 で断り、`Fleet` は今の取り方に戻る
public protocol StreamSource: SessionSource {
    func openStateStream() -> any StreamConnection
}

extension DaemonClient: StreamSource {
    public func openStateStream() -> any StreamConnection { openStream() }
}

/// 会話の購読を受ける側（会話の画面の手元）。`Fleet.retainConversation` で付ける
@MainActor
public protocol ConversationListener: AnyObject {
    /// 購読し直すときの `epoch` と `after`（手元の最後の seq）
    var resumePoint: (epoch: String?, after: Int) { get }
    func streamSubscribed(epoch: String, through: Int)
    func streamEvent(_ event: ConversationEvent)
    /// 購読が終わった（`removed`・`missing`。`behind` は `Fleet` が購読し直す）
    func streamUnsubscribed(reason: String)
    /// 接続が切れた。繋ぎ直したら `Fleet` が購読し直す
    func streamDisconnected()
}

/// host の会話の操作（HTTP）。本番は `DaemonClient`
public protocol ConversationSource: Sendable {
    func startConversation(_ body: ConversationStartRequest) async throws -> Conversation
    func sendConversation(_ id: String, _ body: ConversationSendRequest) async throws -> ConversationSendResponse
    func uploadConversationAttachment(_ id: String, data: Data) async throws -> AttachmentUploadResponse
    func uploadConversationFile(_ id: String, data: Data, name: String) async throws -> AttachmentUploadResponse
    func answerConversation(_ id: String, _ body: ConversationAnswerRequest) async throws
    func controlConversation(_ id: String, _ body: ConversationControlRequest) async throws -> ConversationControlResponse
    func stopConversation(_ id: String) async throws
    func closeConversation(_ id: String) async throws
    func resumeConversation(_ id: String) async throws -> Conversation
    func conversationHistory(_ id: String, before: String?, limit: Int, subagents: Bool) async throws -> ConversationHistoryResponse
    func deleteConversation(_ id: String) async throws
    func conversationCommands(_ id: String) async throws -> ConversationCommandsResponse
    func conversationWorkFiles(_ id: String, query: String, limit: Int) async throws -> ConversationWorkFilesResponse
    func forkConversation(_ id: String, _ body: ConversationForkRequest) async throws -> Conversation
    func rewindConversation(_ id: String, _ body: ConversationRewindRequest) async throws -> ConversationRewindResponse
    func undoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation
    func redoRewindConversation(_ id: String, _ body: ConversationSessionGuard) async throws -> Conversation
    func conversationShell(_ id: String) async throws -> ConversationShellResponse
    func stopConversationShell(_ id: String) async throws
    func prewarmConversation(_ body: ConversationPrewarmRequest) async throws
    func startConversationRun(_ id: String, _ body: ConversationRunRequest) async throws -> ConversationRun
    func conversationRun(_ id: String, run: String) async throws -> ConversationRun
    func cancelConversationRun(_ id: String, run: String) async throws
    /// 会話の Run のシェルを全部閉じる（次の Run は新しいシェルで動く）
    func resetConversationRuns(_ id: String) async throws
    func conversationDiff(_ id: String, scope: ConversationDiffScope) async throws -> ConversationDiffResponse
    func conversationFileDiff(_ id: String, path: String, scope: ConversationDiffScope) async throws -> ConversationFileDiffResponse
    /// 発言のファイルの札の中身（`ChatMessage.files`）
    func conversationFile(_ id: String, toolID: String, file: ChatFile, part: ChatFile.Part) async throws -> ChatFileContent
    /// 人の発言に添えた画像のバイト列（`ChatMessage.images`）
    func conversationImage(_ id: String, lineID: String, image: ChatImage) async throws -> Data
}

extension DaemonClient: ConversationSource {}
