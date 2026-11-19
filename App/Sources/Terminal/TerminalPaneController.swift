import Foundation
import Observation
import TaskboardKit

/// 会話の作業フォルダのシェル 1 つの端末接続。daemon の WebSocket とエンジンをつなぎ、観察 / 操作の状態を画面に見せる。
@MainActor
@Observable
final class TerminalPaneController {
    enum Phase: Equatable {
        case connecting
        case observing
        case controlling
        /// 別のクライアントが操作中。`takeOver()` で奪える。
        case busy
        /// このシェルの中継は終わった（シェルが無い等）。再接続しない。
        case closed(TerminalCloseReason, String?)
        case disconnected(String)
    }

    let key: TerminalKey
    let engine: any TerminalEngine
    private let source: any DaemonWriter
    /// 今の文字の大きさ（`TerminalShelf` に預けている間に設定が変わったら、戻ったときに合わせる）
    private(set) var fontSize: Double

    private(set) var phase: Phase = .connecting
    /// 一時的な知らせ（操作を奪われた等）。利用者が閉じるか次の操作で消える。
    private(set) var notice: String?
    private(set) var frameSize: (cols: Int, rows: Int)?
    private(set) var framesReceived = 0
    /// 枠いっぱいに描いたときの格子。操作中はこの大きさに pane を合わせる（表示のみの間も daemon に覚えさせておく）
    private(set) var availableGrid: (cols: Int, rows: Int)?
    /// エミュレータの 1 セル（pt）。画面の大きさの計算に使う
    private(set) var cellSize: CGSize?
    /// frame の大きさに格子が揃うまでためておくバイト列。狭い格子に書くと折り返され、広がったときの reflow で崩れる
    private var heldBytes = Data()
    private var heldFlush: Task<Void, Never>?

    /// 開いたら操作権を取りに行き、pane を枠の大きさに合わせる。「操作を返す」を押したか、別のクライアントに引き継がれたら取りに行かない
    private var wantsControl = true
    private var acquiredOnThisConnection = false
    /// 自分から取りに行った操作権の返事（control か busy）を待っている
    private var acquirePending = false
    /// 開いて操作権を取りに行っている途中。画面は表示のみの大きさ（pane の今の大きさ）で描かず、枠いっぱいで待つ。
    /// 表示のみの大きさで一度描くと、取れた後に枠いっぱいへ広がり、開くたびに小さい画面がちらついた
    var awaitingControl: Bool { wantsControl && (phase == .connecting || acquirePending) }


    private var connection: TerminalConnection?
    /// 今の接続へ送る列。1 本の Task が順に送る（1 通ずつ Task を作ると、貼り付けを分けた片や続けた打鍵の順が入れ替わる）
    private var outbox: AsyncStream<TerminalClientMessage>.Continuation?
    private var connectTask: Task<Void, Never>?
    private var stopped = false
    /// `TerminalShelf` に預けている（画面に出ていない）。操作権を持っていなければ、届いた frame は描かずに捨てる
    private(set) var parked = false
    /// 預けても操作権を返さず、frame も描き続ける。Mac はほぼこの端末だけで使うので、戻ったときに取り直しも接続し直しもしない。
    /// ほかの端末からは［引き継ぐ］で取る。iPhone・iPad は離れたらすぐ返す（Mac に戻ったときに Mac が取れるように）
    #if os(macOS)
    static let holdsControlWhileParked = true
    #else
    static let holdsControlWhileParked = false
    #endif
    /// 預けている間に frame を捨て、その後まだ全画面の frame を受けていない。表示のみのまま戻ったら、接続し直して全画面を受ける
    private var missingFullFrame = false
    /// 今の接続を切って、待たずにつなぎ直す
    private var reconnectRequested = false

    init(key: TerminalKey, source: any DaemonWriter, engine: any TerminalEngine, fontSize: Double = SessionTextSize.terminalDefault) {
        self.key = key
        self.source = source
        self.engine = engine
        self.fontSize = fontSize
        engine.onInput = { [weak self] data in self?.input(data) }
        engine.onCellSizeChange = { [weak self] in self?.cellSize = self?.engine.cellSize }
        engine.onResize = { [weak self] _, _ in self?.releaseHeldBytesIfFitting() }
    }

    /// 画面に出す。預けていた接続はそのまま使い、操作権を取りに行く
    func attach() {
        let reused = connectTask != nil
        parked = false
        guard reused else {
            start()
            return
        }
        // 開き直したときは、新しく開いたときと同じく取りに行く（前に「操作を返す」を押していても、引き継がれていても）
        wantsControl = true
        // 操作権を持ったまま預けていたなら取り直さない。預けている間に引き継がれていたら取りに行く
        if phase != .controlling { acquiredOnThisConnection = false }
        notice = nil
        // 取れると control の subprocess が起動し直し、最初の frame は全画面になる。取りに行かないなら、捨てた frame の分を接続し直して受ける
        if wantsControl { requestControlIfReady() }
        if !acquirePending, missingFullFrame { reconnect() }
    }

    /// 画面から外す（`TerminalShelf` に預ける）。接続は残す。`holdsControlWhileParked` でなければ、見ていないシェルを操作中にしないよう操作権は返す
    func park() {
        parked = true
        guard !Self.holdsControlWhileParked else { return }
        if phase == .controlling || acquirePending { send(.release) }
        acquirePending = false
        acquiredOnThisConnection = false
        heldFlush?.cancel()
        heldFlush = nil
        heldBytes = Data()
    }

    /// 預けていた端末を、そのまま出せるか
    var isReusable: Bool {
        if stopped { return false }
        if case .closed = phase { return false }
        return true
    }

    func uses(_ other: any DaemonWriter) -> Bool {
        (source as AnyObject) === (other as AnyObject)
    }

    func setFontSize(_ points: Double) {
        guard points != fontSize else { return }
        fontSize = points
        engine.setFontSize(points)
    }

    func start() {
        guard connectTask == nil, !stopped else { return }
        connectTask = Task { [weak self] in await self?.runConnectionLoop() }
    }

    /// 接続し直した最初の frame は全画面（daemon の中継は subprocess の最初の frame を全画面で送る）
    private func reconnect() {
        guard let connection else { return }
        reconnectRequested = true
        missingFullFrame = false
        connection.close()
    }

    /// 画面から外れる。操作中なら操作権を返してから切る。
    func stop() {
        stopped = true
        engine.invalidate()
        heldFlush?.cancel()
        connectTask?.cancel()
        connectTask = nil
        let connection = connection
        self.connection = nil
        if phase == .controlling, let connection {
            outbox?.yield(.release)
            outbox?.finish()
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                connection.close()
            }
        } else {
            outbox?.finish()
            connection?.close()
        }
        outbox = nil
    }

    private func input(_ data: Data) {
        // クリックの報告は操作中だけ送る。表示のみの間に送ると、クリックで操作権を取りに行ってしまう
        let data = phase == .controlling ? data : TerminalMouse.removingReports(from: data)
        guard !data.isEmpty else { return }
        wantsControl = true
        // 別のクライアントが操作中に打ったら引き継ぐ。打った文字は、操作権を取れるまで daemon がためておく
        if phase == .busy { takeOver() }
        // 貼り付けは、シェルが bracketed paste を入れていればエミュレータが印で包む。印ごとそのまま書く。
        // 大きい貼り付けは分けて送る（daemon の WebSocket は 1 通 1MB までで、base64 と JSON で膨らむ）
        var rest = data[...]
        while !rest.isEmpty {
            send(.input(Data(rest.prefix(Self.inputPieceLimit))))
            rest = rest.dropFirst(Self.inputPieceLimit)
        }
    }

    func takeOver() {
        notice = nil
        wantsControl = true
        send(.acquire(takeover: true))
    }

    func release() {
        notice = nil
        wantsControl = false
        send(.release)
    }

    func dismissNotice() {
        notice = nil
    }

    /// 端末の枠の大きさから。エミュレータの格子ではなくこちらを送るのは、表示のみの間はエミュレータを pane の実寸で描くから
    func setAvailableGrid(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let availableGrid, availableGrid == (cols, rows) { return }
        availableGrid = (cols, rows)
        send(.resize(cols: cols, rows: rows))
        requestControlIfReady()
    }

    /// 1 通の入力の上限（バイト）
    static let inputPieceLimit = 200_000

    /// 確認用（DebugServer）。文字列を UTF-8 で入力として送る。
    func typeText(_ text: String) {
        send(.input(Data(text.utf8)))
    }

    /// 確認用（DebugServer）。利用者の貼り付けと同じく、エミュレータを通して送る
    func pasteText(_ text: String) {
        engine.paste(text)
    }

    private func send(_ message: TerminalClientMessage) {
        outbox?.yield(message)
    }

    private func runConnectionLoop() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled, !stopped {
            let size = availableGrid ?? engine.gridSize ?? (cols: 80, rows: 24)
            let connection = source.openTerminal(pane: key.pane, cols: size.cols, rows: size.rows)
            self.connection = connection
            let (messages, outbox) = AsyncStream<TerminalClientMessage>.makeStream()
            self.outbox = outbox
            Task {
                for await message in messages { try? await connection.send(message) }
            }
            phase = .connecting
            acquiredOnThisConnection = false
            acquirePending = false
            requestControlIfReady()
            var closedForGood = false
            do {
                for try await item in connection.incoming {
                    switch item {
                    case .bytes(let data):
                        framesReceived += 1
                        feedFrame(data)
                    case .message(let message):
                        if apply(message) { closedForGood = true }
                    }
                    if closedForGood { break }
                }
                if !closedForGood, !stopped, !reconnectRequested { phase = .disconnected("daemon との接続が切れた") }  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
            } catch {
                if !stopped, !reconnectRequested { phase = .disconnected(String(describing: error)) }
            }
            self.connection = nil
            outbox.finish()
            self.outbox = nil
            if closedForGood || stopped { return }
            if reconnectRequested {
                reconnectRequested = false
                continue
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(10))
        }
    }

    private var gridFitsFrame: Bool {
        guard let frameSize, let grid = engine.gridSize else { return false }
        return grid.cols == frameSize.cols && grid.rows == frameSize.rows
    }

    private func feedFrame(_ data: Data) {
        if parked, !(Self.holdsControlWhileParked && phase == .controlling) {
            missingFullFrame = true
            return
        }
        if heldBytes.isEmpty, gridFitsFrame {
            draw(data)
            return
        }
        heldBytes.append(data)
        // 格子が揃わないまま（描画が始まらない等）でも、1 秒で諦めて描く。操作権の返事を待っている間は、取れて pane が枠の大きさで描き直されるまでもう少し待つ
        if heldFlush == nil {
            heldFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if self?.awaitingControl == true { try? await Task.sleep(for: .seconds(2)) }
                guard !Task.isCancelled else { return }
                self?.releaseHeldBytes()
            }
        }
    }

    private func releaseHeldBytesIfFitting() {
        if !heldBytes.isEmpty, gridFitsFrame { releaseHeldBytes() }
    }

    private func releaseHeldBytes() {
        heldFlush?.cancel()
        heldFlush = nil
        guard !heldBytes.isEmpty else { return }
        let data = heldBytes
        heldBytes = Data()
        draw(data)
    }

    private func draw(_ data: Data) {
        engine.feed(data)
    }

    /// 操作権を取りに行く。接続の直後から送る（最初の frame を待ってから送ると、daemon は observe を起動して frame を返してから control に張り直すので、
    /// 1 往復と subprocess の起動 1 回ぶん遅れる）。枠の大きさが分かる前は、最初の frame まで待つ（80x24 のまま取ると、pane が一度その大きさになる）
    private func requestControlIfReady(frameArrived: Bool = false) {
        // `.controlling` は預けたときに返した操作権の返事がまだ来ていないとき（取れている間は `acquiredOnThisConnection` が立っている）
        guard !parked, !acquiredOnThisConnection, wantsControl, outbox != nil, [.connecting, .observing, .controlling].contains(phase) else { return }
        guard availableGrid != nil || frameArrived else { return }
        acquiredOnThisConnection = true
        acquirePending = true
        send(.acquire(takeover: false))
    }

    /// サーバの制御情報を状態に反映する。`true` なら中継が終わった。
    private func apply(_ message: TerminalServerMessage) -> Bool {
        switch message {
        case .frame(_, let full, let cols, let rows):
            // full の frame は画面全体を描き直すので、ためていた前の差分は要らない
            if full {
                heldBytes = Data()
                if !parked { missingFullFrame = false }
            }
            frameSize = (cols, rows)
            if phase == .connecting { phase = .observing }
            requestControlIfReady(frameArrived: true)
        case .mode(.observe):
            if phase != .busy { phase = .observing }
        case .mode(.control):
            phase = .controlling
            // 入力や引き継ぎで取れた分も、この接続では取ったものとして扱う（取れている間に操作権をもう一度求めない）
            acquiredOnThisConnection = true
            acquirePending = false
            notice = nil
        case .controllerBusy:
            phase = .busy
            acquirePending = false
            // 別のクライアントが操作中で、表示のみの差分しか来ない。捨てた frame の分を全画面で受け直す
            if !parked, missingFullFrame { reconnect() }
            // 表示のみの大きさで描き直すので、ためていた分が格子に合えば出す
            releaseHeldBytesIfFitting()
        case .controlLost(let reason):
            phase = .observing
            acquirePending = false
            if reason == .takenOver { wantsControl = false }
            notice =
                switch reason {
                case .takenOver: String(localized: "ほかのデバイスが操作を引き継いだため、表示のみに戻りました。")
                case .disconnected: String(localized: "ターミナルとの接続が切れたため、表示のみに戻りました。")
                }
        case .closed(let reason, let message):
            phase = .closed(reason, message)
            acquirePending = false
            return reason != .queueOverflow  // 溢れは再接続で戻る
        }
        return false
    }

    /// DebugServer の `/state` 用。
    var debugDescription: [String: Any] {
        [
            "pane": key.pane.rawValue,
            "machine": key.machine.rawValue,
            "phase": phaseLabel,
            "awaitingControl": awaitingControl,
            "notice": notice as Any,
            "frameSize": frameSize.map { ["cols": $0.cols, "rows": $0.rows] } as Any,
            "gridSize": engine.gridSize.map { ["cols": $0.cols, "rows": $0.rows] } as Any,
            "framesReceived": framesReceived,
            "parked": parked,
        ]
    }

    var phaseLabel: String {
        switch phase {
        case .connecting: "connecting"
        case .observing: "observing"
        case .controlling: "controlling"
        case .busy: "busy"
        case .closed(let reason, _): "closed:\(reason.rawValue)"
        case .disconnected: "disconnected"
        }
    }
}
