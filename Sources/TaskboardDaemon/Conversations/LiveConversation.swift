import Foundation
import TaskboardKit

/// 動いている会話の actor の口。`ConversationService` が会話ごとの仕事（起こす・送る・答える・止める・知らせ・購読・巻き戻し・端末）を任せる。
/// engine ごとの adapter が満たし、engine に無い操作は `ConversationError.controlUnsupported` で断る
protocol LiveConversation: Actor {
    nonisolated var id: String { get }
    /// host の子の知らせの入口（`ConversationService.route` が振り分ける）
    nonisolated var inbox: AsyncStream<AgentHostNotice>.Continuation { get }
    var record: ConversationRecord { get }

    // MARK: 起こす・引き取る

    func start(resume: Bool, withinSoft: Bool) async throws
    /// 画面に出たら起こし直すか（人が止めた・終えた会話は起こさない）
    var wakesForViewer: Bool { get }
    /// host の子に購読し直すか（daemon が起き直した後の突き合わせ）
    func resubscribes(to process: AgentHostProcessInfo) -> Bool
    /// 読み直しは `ConversationTiming.replay` まで待つ
    func attach(process: AgentHostProcessInfo, prewarmed: Bool) async
    func resubscribe() async
    func hostRestarted() async

    // MARK: 送る・答える・制御

    func send(_ request: ConversationSendRequest) async throws -> ConversationSendOutcome
    func deliver(text: String, uuid: String, wake: ConversationWakePolicy) async throws -> ConversationDeliveryOutcome
    func deliveryState(_ uuid: String) async -> ConversationDeliveryOutcome
    func received(_ uuid: String) -> Bool
    func answer(_ request: ConversationAnswerRequest) async throws
    func control(_ request: ConversationControlRequest) async throws -> ConversationControlResponse
    func rename(_ title: String) async throws

    // MARK: 止める

    func stop(_ cause: ConversationStopCause) async
    func stopIfIdle(before cutoff: Date) async -> Bool
    func isStoppable(before cutoff: Date) -> Bool
    func stopIfResting() async
    /// 動いていて空いている・裏のタスクが無いと分かっている・問いが無い・答えている途中でない・起こしている途中でない・利用枠の上限で待っていない
    /// （画面に出ているかは問わない）
    var isResting: Bool { get }
    /// 返事の後にしばらく空いた会話を圧縮する（`ConversationService.compactIdleConversations` の見回り）
    func compactIfIdle() async
    func stopIfFinished() async -> Bool
    func continueAfterLimit() async
    func continueAfterNetwork(online: Bool, returned: Bool) async

    // MARK: 起こした側への知らせ

    func noticeDelivered(at: Date)
    func noticeCancelled(at: Date)
    var noticeState: (busy: Bool, requests: [ConversationRequest]) { get }
    var lastActiveAt: Date { get }

    // MARK: 様子・購読・記録

    func snapshot() -> Conversation
    /// `/` で使えるコマンド。engine から受けた一覧が無ければ nil
    var commands: [ConversationCommand]? { get }
    var isLive: Bool { get }
    var isIdle: Bool { get }
    var lastSeq: Int { get }
    var viewers: Int { get }
    func reloadRecord()
    func subscribe(_ outbox: StreamOutbox, key: UUID, epoch clientEpoch: String?, after: Int, subagents: Bool) -> Bool
    func unsubscribe(key: UUID)
    func events(after: Int) -> AsyncStream<ConversationEvent>
    func retire() throws
    func unretire()

    // MARK: 差分・Run

    func emitRun(_ update: ConversationRunUpdate)
    func refreshDiffSoon()
    func setDiff(_ summary: ConversationDiffSummary)
}

/// 巻き戻せる会話（Claude）。巻き戻しの補助のプロセス（`HelperProcess`）を起こし、daemon が起き直したら引き取る。
/// 従わない会話の巻き戻しは `ConversationService` が `ConversationError.controlUnsupported` で断る
protocol RewindingConversation: LiveConversation {
    /// 巻き戻しの補助のプロセスの知らせの入口
    nonisolated var helperInbox: AsyncStream<AgentHostNotice>.Continuation { get }
    func adoptHelper(_ process: AgentHostProcessInfo) async
    func rewindFiles(userMessageID: String, dryRun: Bool) async throws -> ConversationRewindResponse
    func rewind(_ request: ConversationRewindRequest, projects: URL) async throws -> ConversationRewindResponse
    func undoRewind(expected: String) async throws -> Conversation
    func redoRewind(expected: String) async throws -> Conversation
}

extension LiveConversation {
    func start(resume: Bool) async throws { try await start(resume: resume, withinSoft: false) }
    func attach(process: AgentHostProcessInfo) async { await attach(process: process, prewarmed: false) }
    func subscribe(_ outbox: StreamOutbox, key: UUID, epoch clientEpoch: String?, after: Int) -> Bool {
        subscribe(outbox, key: key, epoch: clientEpoch, after: after, subagents: false)
    }
    /// codex の会話は圧縮しない（`thread/compact/start` を送る口がまだ無い）
    func compactIfIdle() async {}
}

enum ConversationSendOutcome: String, Codable, Equatable, Sendable {
    /// engine が受けた
    case accepted
    /// 同じ `client_message_id` を前に受けている
    case duplicate
    /// 書いたが、受けたかを確かめられなかった
    case unknown
}

/// 回答・レビュー・知らせを発言として届けた結果。受け取り済みにしてよいのは `delivered` だけ
enum ConversationDeliveryOutcome: Equatable, Sendable {
    /// モデルに渡った
    case delivered
    /// 待ち行列に入ったまま取り消された。回数を進めた uuid で届け直す
    case cancelled
    /// 会話が空いていない（生成中・問い待ち）。次に空いたときに届ける
    case busy
    /// 渡ったかを確かめられなかった。同じ uuid で状態を見直す
    case unknown
}

/// 送る本文。画像でない添付のパスを確かめ、engine の読む形で本文の頭に書く（`MentionedFiles`）。相対パスと無いファイルは 404
enum ConversationSendText {
    static func compose(_ request: ConversationSendRequest, engine: Conversation.Engine) throws -> String {
        for path in request.files where !path.hasPrefix("/") || !FileManager.default.fileExists(atPath: path) {
            throw ConversationError(status: 404, code: .attachmentMissing, description: "添付のファイル \(path) が無い")
        }
        return MentionedFiles.compose(request.text, paths: request.files, engine: engine)
    }
}

/// 止まっている会話を、届けるために起こすか（届けるものごとの値は `DeliveryKind.wake`）
enum ConversationWakePolicy: Sendable {
    case always
    /// 人が止めた・終了した会話（`ConversationStopCause.keepsStopped`）は起こさない。人が戻すまで届けずに残す
    case unlessStoppedByPerson
    case never
}


/// 会話の actor の待ち時間（engine の応答・発言の受付・止める手順・差分のため）
struct ConversationTiming: Sendable {
    var control: Duration = .seconds(30)
    /// 委譲先の知らせに載せる codex の最後の返事を読む上限（app-server の起動を含む。超えたら返事なしで知らせる）
    var noticeReply: Duration = .seconds(5)
    /// codex の MCP の server の実行中の状態（`mcpServerStatus/list` の全部の頁）を待つ期限。アプリの要求が切れる（60 秒）前に返す
    var mcpStatus: Duration = .seconds(45)
    /// 脇の質問（`side_question`）。答えはモデルが書く
    var sideQuestion: Duration = .seconds(180)
    var accept: Duration = .seconds(10)
    var stopResult: Duration = .seconds(5)
    /// 生成中なのに CLI から行が来ないまま、これを超えたら止まっているとする。host の会話の transcript（7 日・60 本）で、
    /// 結果や発言の後に次の発言が書かれるまでの間は 99% が 34 秒・最長 233 秒、自動の圧縮は最長 119 秒だった（2026-10-21 に測った）
    var stall: Duration = .seconds(300)
    /// 中断に CLI が応えるまでと、応えてからターンが終わるまでの待ち。超えたら止めて起こし直す
    var interruptAnswer: Duration = .seconds(10)
    var interruptResult: Duration = .seconds(10)
    var stopInput: Duration = .seconds(10)
    /// ［今すぐ送る］で、主の流れの Bash・subagent の tool_use が task になるのを待つ上限（Bash は 3.4〜3.9 秒。2.1.304 で 11 回測った）
    var detachWait: Duration = .seconds(5)
    /// 生成中に送った発言が待ち行列に入ったとき、主の流れの前景の tool を tool_use からこれだけ動いていたら裏に回す。回せなければ `steerDetachRetry` ごとに
    /// 試し直し、`steerDetachGiveUp` で諦める（Desktop の 3 秒・1 秒・15 秒）
    var steerDetachAge: Duration = .seconds(3)
    var steerDetachRetry: Duration = .seconds(1)
    var steerDetachGiveUp: Duration = .seconds(15)
    var stopTerm: Duration = .seconds(5)
    /// 引き取りで、host の控えを終わりまで読むのを待つ上限
    var replay: Duration = .seconds(10)
    /// 同じ block の差分をためて 1 つの出来事にする間
    var deltaBatch: Duration = .milliseconds(50)
    /// 差分の要約を取り直す前にまとめる間
    var diffBatch: Duration = .seconds(1)
    /// 返事の後にこれだけ空いたら圧縮する（`compactIfIdle`）。prompt cache の 1 時間が切れる前に縮め、次の発言で書き直すキャッシュを減らす
    var idleCompact: TimeInterval = 50 * 60
    /// これを過ぎて見回りが来たら圧縮しない（キャッシュが切れかけで、圧縮そのものが書き直しになる）
    var idleCompactCutoff: TimeInterval = 56 * 60
}
