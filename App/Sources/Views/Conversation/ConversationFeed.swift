import Foundation
import Observation
import TaskboardKit

/// 入力欄に戻す発言（取り消された待機中の発言・巻き戻した指示）
struct RestoredDraft: Equatable {
    var text: String
    var images: [ChatDraftImage] = []
    var files: [ChatDraftFile] = []
    /// 今の下書きの後ろに足す（差分の行のコメント。付けた順に並べる）
    var appends = false
}

/// 1 つの会話の手元。画面が出ている間だけ `Fleet` で購読し、手元に何も無ければ履歴の 1 ページを同時に取る。
/// アプリが動いている間は `AppModel.conversationFeeds` が新しく開いた順に 16 会話まで持ち、開き直したら続きだけ取る
@MainActor
@Observable
final class ConversationFeed: ConversationListener {
    enum Phase: Equatable {
        /// 購読を始めるのを待っている
        case connecting
        case live
        /// 接続が切れた。繋ぎ直したら `Fleet` が購読し直す
        case disconnected
        /// 会話の記録が消えた（`removed`・`missing`）
        case removed
        /// 表示用のデータ（fixtures）
        case fixture
    }

    let key: ConversationKey
    /// 手元の全体。画面は下の写しを読む（これを読むと、生成中の差分のたびに会話の画面の全体を描き直した）。
    /// 画面に要る値を足したら、写しの欄と `publish()` の両方に足す（`ConversationFeedPublishTests`）
    @ObservationIgnored private var timeline: ConversationTimeline {
        didSet { publish() }
    }
    #if DEBUG
    /// debug の口とテストだけが読む手元の全体
    var debugTimeline: ConversationTimeline { timeline }
    #endif
    /// 画面が読む `timeline` の写し。変わったものだけ替える。1 つの値にまとめないのは、発言だけを読む画面を生成中の差分で描き直さないため
    private(set) var messages: [ChatMessage] = []
    /// 生成中の block の並びと状態。文は空にしてある（差分のたびに会話の画面と一覧を描き直さない）。見せる文は `reveal` から読む
    private(set) var streaming: [ConversationTimeline.StreamingBlock] = []
    /// 生成中の本文の見せる文（生成中の行だけが読む）
    let reveal = StreamingReveal()
    private(set) var outgoing: [ConversationTimeline.Outgoing] = []
    private(set) var historyState: ConversationTimeline.HistoryState = .notLoaded
    private(set) var isGenerating = false
    private(set) var isEmpty = true
    private(set) var phase: Phase
    /// 履歴を取れなかった理由（画面の帯に出す）
    private(set) var historyFailure: UserFacingError?
    private(set) var loadingOlder = false
    /// 待ち行列から取り消された発言と、巻き戻した指示。画面が下書きに戻して空にする
    var restoredDrafts: [RestoredDraft] = []
    /// 履歴のページを読み込んだ回数。増えたら画面が末尾へ送り直す
    private(set) var reloads = 0
    /// `/` で使えるコマンド（開いたときに取り、購読の `commands` で替える）
    var commands: [ConversationCommand] = []
    /// コードブロックの Run
    var runs = ConversationRunStore()
    /// 発言のファイルの札を押して取った中身（`loadFile`）
    let files = ChatFileStore()
    /// 差分の画面の一覧とファイルごとの diff（画面を開いたときに取る）
    var diff: ConversationLoad<ConversationDiffResponse> = .idle
    /// 差分の画面で比べる相手
    var diffScope: ConversationDiffScope = .all
    var fileDiffs: [String: ConversationLoad<ConversationFileDiffResponse>] = [:]
    /// コネクタの一覧（欄を開いたときに `mcp_status` で取る。状態には載らない）
    var connectors: ConversationLoad<[ConversationMcpServer]> = .idle
    /// コンテキストの区分ごとのトークン（シートを開いたときに取る。状態には載らない）
    var contextBreakdown: ConversationLoad<ConversationContextBreakdown> = .idle
    /// 止まった会話を、読む画面のために起こしている間と、起こせなかったとき（`load(waking:then:)`）
    var wake: ConversationWake = .idle
    /// 読むだけのシートの中身（開いているシートの 1 つ分。開いたときに取る）
    var readout: ConversationLoad<ConversationReadoutValue> = .idle
    /// ［プラグイン］のシートの、入れられる plugin を絞る文字
    @ObservationIgnored var pluginQuery = ""
    /// 権限の規則のシートの sandbox の節（`/sandbox` の状態）
    var sandbox: ConversationLoad<ConversationSandbox> = .idle
    /// 裏のタスクの一覧と、タスクごとの出力の末尾（`/tasks` のシートを開いたときに取る）
    var backgroundTasks: ConversationLoad<ConversationBackgroundTasks> = .idle
    var taskOutputs: [String: ConversationLoad<ConversationTaskOutput>] = [:]
    /// 入力欄の下の欄で開いているもの。debug の口と snapshot test も開く
    var openField: ConversationField?
    /// 上の帯の［状態］を開いているか（`/status` などでも開く。詳細の欄が隣にあれば、その「会話」の節を開いて閉じ直す）
    var showsInfo = false
    /// 会話の画面に重ねているもの（差分・巻き戻しの確認・端末）
    var sheet: ConversationSheet?
    /// 直前の巻き戻しで戻せなかったリンクの数（帯に出す。元に戻すか閉じると消す）
    var skippedLinks: Int?

    /// 送った発言が daemon に通ったとき（再送で通ったときも）
    @ObservationIgnored var onDelivered: (() -> Void)?
    @ObservationIgnored private weak var fleet: Fleet?
    @ObservationIgnored var source: (any ConversationSource)?
    /// 表示用のデータの差分・コネクタ・巻き戻しの確認の中身
    @ObservationIgnored var fixtureTools: FixtureConversation?
    @ObservationIgnored private var viewers = 0
    /// 画面に出ている（scene が裏に入っている間は出ていない）
    var isOnScreen: Bool { viewers > 0 }
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    /// 送り直すときの中身（`clientMessageID` ごと）。置けた画像の id は持ち越し、置き直さない
    @ObservationIgnored private var bodies: [String: OutgoingBody] = [:]
    /// つながらずに送れなかった発言の、自動の送り直しの待ち（`OutgoingRetry`）。つなぎ直したら待たずに送る
    @ObservationIgnored private var autoRetries: [String: (attempt: Int, wait: Task<Void, Never>)] = [:]
    /// 届いてまだ当てていない出来事。まとめて当てる（1 件ずつ当てると、開いたときに控えが 1 件ずつ出て、そのたびに全体を描き直した）
    @ObservationIgnored private var pendingEvents: [ConversationEvent] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var publishedVersion = -1
    static let pageSize = 50
    /// 控えを流している間に、当てるのを待つ長さの上限（流し終えの印が届かないときもこれで当てる）
    static let replayWait = Duration.milliseconds(400)

    private struct OutgoingBody {
        var text: String
        var images: [ChatDraftImage]
        var files: [ChatDraftFile]
        var uploaded: [String]?
        /// 会話のマシンでのファイルのパス（置いたものを含む）。送り直すときに置き直さない
        var filePaths: [String]?
        var later = false
    }

    init(key: ConversationKey, fleet: Fleet, source: any ConversationSource) {
        self.key = key
        self.fleet = fleet
        self.source = source
        timeline = ConversationTimeline()
        phase = .connecting
        publish()
    }

    init(key: ConversationKey, fixture: ConversationTimeline, tools: FixtureConversation? = nil) {
        self.key = key
        timeline = fixture
        phase = .fixture
        fixtureTools = tools
        publish()
        if let tools {
            commands = tools.commands
            for run in tools.runs { runs.replace(run) }
            if let connectors = tools.mcpServers { self.connectors = .loaded(connectors) }
        }
    }

    var resumePoint: (epoch: String?, after: Int) { (timeline.epoch, timeline.seq) }

    /// 画面が出た（scene が前面に戻った）。同じ会話を 2 か所で開くと数を重ねる
    func start() {
        viewers += 1
        guard viewers == 1, let fleet, source != nil else { return }
        fleet.retainConversation(key, listener: self)
        if timeline.historyState == .notLoaded { loadLatest() }
        loadCommands()
    }

    /// 画面が消えた（scene が裏に入った）
    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        fleet?.releaseConversation(key)
        if phase == .live { phase = .connecting }
    }

    /// 使い回すときに、今の接続先で操作する（接続し直すと別の供給元になる）
    func use(_ source: any ConversationSource) {
        guard self.source != nil else { return }
        self.source = source
    }

    // MARK: 履歴

    func loadLatest() {
        guard let source else { return }
        historyTask?.cancel()
        historyTask = Task { [key] in
            do {
                let page = try await source.conversationHistory(key.id, before: nil, limit: Self.pageSize, subagents: true)
                guard !Task.isCancelled else { return }
                flushEvents()
                timeline.mergeHistory(page, older: false)
                historyFailure = nil
                reloads += 1
            } catch {
                guard !Task.isCancelled else { return }
                historyFailure = UserFacingError("会話の記録を読み込めませんでした", error: error)
            }
        }
    }

    /// 上へ戻したときの次のページ。Claude の会話 ID が変わっていたら（`/clear`）末尾から取り直す
    func loadOlder() {
        guard let source, timeline.historyState == .more, let cursor = timeline.olderCursor, !loadingOlder else { return }
        loadingOlder = true
        Task { [key] in
            defer { loadingOlder = false }
            do {
                let page = try await source.conversationHistory(key.id, before: cursor, limit: Self.pageSize, subagents: true)
                flushEvents()
                if !timeline.mergeHistory(page, older: true) { loadLatest() }
            } catch {
                historyFailure = UserFacingError("会話の記録を読み込めませんでした", error: error)
            }
        }
    }

    #if DEBUG
    /// debug の口（`/bench/older`）が、古いページを読んだのと同じに前へ足す
    func mergeOlderPage(_ page: ConversationHistoryResponse) {
        flushEvents()
        _ = timeline.mergeHistory(page, older: true)
    }
    #endif

    // MARK: 購読

    func streamSubscribed(epoch: String, through: Int) {
        flushEvents()
        apply(timeline.subscribed(epoch: epoch, through: through))
        phase = .live
        // 切れていた間の出力を取り直す
        refreshRunningRuns()
        for (id, retry) in autoRetries {
            retry.wait.cancel()
            autoRetries[id] = nil
            deliver(id, attempt: retry.attempt + 1)
        }
    }

    func streamEvent(_ event: ConversationEvent) {
        pendingEvents.append(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            let started = ContinuousClock.now
            while let self, self.waitsForReplay(since: started) { try? await Task.sleep(for: .milliseconds(30)) }
            self?.flushEvents()
        }
    }

    /// 控えを流している途中で、through まで届いておらず、待つ上限にも達していない
    private func waitsForReplay(since started: ContinuousClock.Instant) -> Bool {
        // 後から来た gap で流し直すときは、gap を当てた次の回から待つ（当てる前の timeline は流し直しを知らない）
        guard let replayThrough = timeline.replayThrough else { return false }
        return (pendingEvents.last?.seq ?? 0) < replayThrough && ContinuousClock.now - started < Self.replayWait
    }

    /// ためた出来事を当てる。手元をほかの経路で替える前にも呼ぶ（届いた順を崩さない）
    private func flushEvents() {
        flushTask = nil
        guard !pendingEvents.isEmpty else { return }
        let events = pendingEvents
        pendingEvents = []
        apply(timeline.apply(events))
    }

    func streamUnsubscribed(reason: String) {
        flushEvents()
        phase = .removed
    }

    func streamDisconnected() {
        flushEvents()
        if phase != .removed { phase = .disconnected }
    }

    /// 画面が読む写しを、変わったものだけ替える
    private func publish() {
        if publishedVersion != timeline.messagesVersion {
            publishedVersion = timeline.messagesVersion
            messages = timeline.messages
        }
        let shapes = timeline.streaming.map { block in
            var shape = block
            shape.text = ""
            return shape
        }
        if streaming != shapes { streaming = shapes }
        reveal.update(timeline.streaming)
        if outgoing != timeline.outgoing { outgoing = timeline.outgoing }
        if historyState != timeline.historyState { historyState = timeline.historyState }
        if isGenerating != timeline.isGenerating { isGenerating = timeline.isGenerating }
        if isEmpty != timeline.isEmpty { isEmpty = timeline.isEmpty }
    }

    /// 取り消された発言を入力欄に戻す形。置いた画像とファイルは、置いた id とパスのまま戻す
    private static func restored(_ outgoing: ConversationTimeline.Outgoing, body: OutgoingBody?) -> RestoredDraft {
        guard let body else { return RestoredDraft(text: outgoing.text) }
        var images = body.images
        if let uploaded = body.uploaded {
            for (index, id) in uploaded.enumerated() where index < images.count { images[index].uploadedID = id }
        }
        let files =
            body.filePaths.map { paths in zip(body.files, paths).map { ChatDraftFile(name: $0.name, content: .path($1)) } } ?? body.files
        return RestoredDraft(text: body.text, images: images, files: files)
    }

    /// fixtures と debug の口が手元に出来事を当てる
    func apply(_ effects: [ConversationTimeline.Effect]) {
        for effect in effects {
            switch effect {
            case .reloadHistory: loadLatest()
            case .restoreDraft(let outgoing):
                restoredDrafts.append(Self.restored(outgoing, body: bodies.removeValue(forKey: outgoing.clientMessageID)))
            case .commands(let commands):
                self.commands = commands
            case .run(let update):
                runs.apply(update)
            }
        }
    }

    // MARK: 操作

    /// 先に出してから送る。画像は 1 枚ずつ置いてから id を載せ、ほかのマシンへのファイルも 1 つずつ置いてからパスを載せる。
    /// 送れなかったら印を付け、［再送信］で同じ id を送り直す。`later` は応答が終わってから送る（engine が `sendLater` を持つときだけ渡す）
    func send(_ text: String, images: [ChatDraftImage], files: [ChatDraftFile] = [], later: Bool = false) {
        let id = UUID().uuidString.lowercased()
        bodies[id] = OutgoingBody(text: text, images: images, files: files, later: later)
        flushEvents()
        if let engine = fleet?.conversation(for: key)?.engine { timeline.queuesMessages = engine.queuesMessages }
        timeline.addOutgoing(clientMessageID: id, text: text, attachmentCount: images.count, fileNames: files.map(\.name), later: later, at: Date())
        deliver(id)
    }

    func retry(_ clientMessageID: String) {
        guard bodies[clientMessageID] != nil else { return }
        autoRetries.removeValue(forKey: clientMessageID)?.wait.cancel()
        timeline.markRetrying(clientMessageID)
        deliver(clientMessageID)
    }

    /// `attempt` は自動の送り直しの回数（人が送った・［再送信］は 0）
    private func deliver(_ id: String, attempt: Int = 0) {
        guard let source, var body = bodies[id] else {
            timeline.markFailed(id)
            return
        }
        Task { [key] in
            do {
                if body.uploaded == nil {
                    var ids: [String] = []
                    for image in body.images {
                        if let id = image.uploadedID {
                            ids.append(id)
                        } else {
                            ids.append(try await source.uploadConversationAttachment(key.id, data: image.data).id)
                        }
                    }
                    body.uploaded = ids
                    bodies[id]?.uploaded = ids
                }
                if body.filePaths == nil {
                    var paths: [String] = []
                    for file in body.files {
                        switch file.content {
                        case .path(let path): paths.append(path)
                        case .data(let data): paths.append(try await source.uploadConversationFile(key.id, data: data, name: file.name).path)
                        }
                    }
                    body.filePaths = paths
                    bodies[id]?.filePaths = paths
                }
                _ = try await source.sendConversation(
                    key.id, ConversationSendRequest(text: body.text, attachments: body.uploaded ?? [], files: body.filePaths ?? [], clientMessageID: id, later: body.later))
                timeline.markSent(id)
                onDelivered?()
            } catch {
                guard OutgoingRetry.isTransient(error), let delay = OutgoingRetry.delay(afterFailure: attempt), bodies[id] != nil else {
                    timeline.markFailed(id)
                    return
                }
                // 送っている印のまま待つ。尽きたら［再送信］を出す
                timeline.markRetrying(id)
                let wait = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self, self.autoRetries.removeValue(forKey: id) != nil else { return }
                    self.deliver(id, attempt: attempt + 1)
                }
                autoRetries[id] = (attempt, wait)
            }
        }
    }

    func answer(_ request: ConversationAnswerRequest) async throws {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        try await source.answerConversation(key.id, request)
    }

    /// 待機中の発言を、今の返答の区切りを待たずに渡す（［今すぐ送信］）。もう渡っていた（`nothing_waiting`）なら受けた印にする
    func sendNow(_ clientMessageID: String) async throws -> ConversationSendNow {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        let response = try await source.controlConversation(key.id, ConversationControlRequest(kind: .sendNow, value: clientMessageID))
        let result = try WireJSON.decoder().decode(ConversationSendNow.self, from: Data((response.payloadJSON ?? "").utf8))
        if result.outcome == .nothingWaiting { timeline.markAccepted(clientMessageID) }
        timeline.markSooner(clientMessageID)
        bodies[clientMessageID]?.later = false
        return result
    }

    /// 待機中の発言を待ち行列から外す。外せたら受付が cancelled で終わり、［編集］（`edit`）なら文を入力欄に戻し、［取り消す］なら捨てる。
    /// もう渡っていた（false）なら受けた印にしてカードから外す
    func cancelQueued(_ clientMessageID: String, edit: Bool) async throws -> Bool {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        if !edit { timeline.discard(clientMessageID) }
        do {
            let response = try await source.controlConversation(key.id, ConversationControlRequest(kind: .cancelQueued, value: clientMessageID))
            let cancelled = try WireJSON.decoder().decode(ConversationQueuedCancel.self, from: Data((response.payloadJSON ?? "").utf8)).cancelled
            if !cancelled {
                timeline.keep(clientMessageID)
                timeline.markAccepted(clientMessageID)
            }
            return cancelled
        } catch {
            timeline.keep(clientMessageID)
            throw error
        }
    }

    /// 生成を止める（プロセスは残す）。待ち行列の発言は取り消され、`accepted(cancelled)` で下書きに戻る
    func interrupt() async throws {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        _ = try await source.controlConversation(key.id, ConversationControlRequest(kind: .interrupt))
    }

    /// DebugServer の `/conversation` が返す手元の今
    var debugDescription: [String: Any] {
        let phase: String = switch phase {
        case .connecting: "connecting"
        case .live: "live"
        case .disconnected: "disconnected"
        case .removed: "removed"
        case .fixture: "fixture"
        }
        return [
            "key": key.description, "phase": phase, "seq": timeline.seq, "epoch": timeline.epoch as Any, "count": timeline.messages.count,
            "history": "\(timeline.historyState)", "agentSessionID": timeline.agentSessionID as Any,
            "tail": timeline.messages.suffix(8).map { ["id": $0.id, "role": $0.role.rawValue, "kind": $0.kind.rawValue, "text": String($0.text.prefix(120))] },
            "streaming": timeline.streaming.map { ["message": $0.messageID, "index": $0.index, "block": $0.block.rawValue, "tool": $0.toolName as Any, "text": String($0.text.prefix(120)), "stopped": $0.stopped] },
            "outgoing": timeline.outgoing.map { ["id": $0.clientMessageID, "text": String($0.text.prefix(120)), "state": "\($0.state)"] },
            "historyFailure": historyFailure?.text as Any,
            "commands": commands.map(\.name),
            "runs": runs.entries.map { ["id": $0.id, "message": $0.messageID as Any, "status": $0.status.rawValue, "exitCode": $0.exitCode as Any, "output": String($0.output.suffix(400)), "truncated": $0.truncated] },
            "diff": diff.debugDescription { ["files": $0.files.map(\.path), "branch": $0.summary.branch as Any, "scope": $0.scope.rawValue, "base": $0.base as Any] },
            "fileDiffs": fileDiffs.mapValues { $0.debugDescription { ["bytes": $0.diff.utf8.count, "truncated": $0.truncated] } },
            "connectors": connectors.debugDescription { $0.map { ["name": $0.name, "status": $0.status] } },
            "contextBreakdown": contextBreakdown.debugDescription { ["total": $0.totalTokens, "max": $0.maxTokens, "categories": $0.categories.map(\.name)] },
            "readout": readout.debugDescription { $0.debugName },
            "backgroundTasks": backgroundTasks.debugDescription { $0.tasks.map(\.id) },
            "taskOutputs": taskOutputs.mapValues { $0.debugDescription { ["bytes": $0.totalBytes, "truncated": $0.truncated] } },
            "openField": openField?.rawValue as Any,
            "showsInfo": showsInfo,
            "sheet": sheet?.debugName as Any,
            "skippedLinks": skippedLinks as Any,
        ]
    }
}
