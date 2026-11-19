import Foundation
import Logging
import TaskboardKit

/// 会話のシェル（agent host の擬似端末）と、それを開いている画面（`/v1/terminal/{id}` の WebSocket）の中継。
///
/// - 画面を開くと、host がためた出力を全画面の frame で送る（前の画面を消してから描かせる）。以後の出力はそのまま流す
/// - 書き込みと擬似端末の大きさは、操作権を持つ画面が 1 つだけ持つ。最後に `acquire(takeover: true)` した画面が取る
/// - 過去の行は画面のエミュレータが持つので、`scroll` は受けても何もしない
/// - host がシェルを扱えない版なら、`fallback`（daemon の中の host の部品）で開く。host は会話が動いている間入れ替わらないため。
///   そのシェルは daemon を入れ替えると消える
/// - コードブロックの実行のシェル（`ConversationRuns`）も同じ口で開き、その知らせは `runNotices` に流す
actor ConversationShells {
    static let keyPrefix = "shell-"

    static func key(conversation id: String) -> String { keyPrefix + id }

    static func isShell(_ id: String) -> Bool { PaneID(rawValue: id).isConversationShell }

    enum Outgoing: Sendable, Equatable {
        case text(String)
        case binary(Data)
        /// WebSocket を閉じる。`nil` は画面の側から切れた後
        case end(reason: String?)
    }

    enum Failure: Error, CustomStringConvertible {
        case hostUnavailable
        case hostOutdated

        var description: String {
            switch self {
            case .hostUnavailable: "agent host に繋がっていない"
            case .hostOutdated: "agent host がシェルを扱えない版で動いている"
            }
        }
    }

    private struct Viewer {
        var key: String
        var cols: Int
        var rows: Int
        var outgoing: [Outgoing] = []
        var queuedBytes = 0
        var waiter: CheckedContinuation<Outgoing?, Never>?
        var ended = false
        /// ためた出力を受け取る前に届いた出力（位置つき）。nil なら届いたらすぐ流す
        var held: [(start: Int, data: Data)]? = []
        /// ここまで流した（位置）。繋ぎ直しで同じ出力を 2 回流さない
        var deliveredThrough = 0
    }

    private let host: any AgentHostTransport
    private let fallback: InProcessAgentHost?
    private var fallbackStarted = false
    /// `fallback` で開いたシェルの key
    private var fallbackKeys: Set<String> = []
    private let logger: Logger
    private let queueLimitBytes: Int
    private var hostVersion: Int?
    private var viewers: [UUID: Viewer] = [:]
    private var controllers: [String: UUID] = [:]
    private var sizes: [String: (cols: Int, rows: Int)] = [:]
    /// この位置より前の出力にある端末への問い合わせは答え済み（シェルに書いた時点で画面が受け取っていた所まで）。
    /// 読み直しの出力から落とさないと、繋ぎ直すたびにエミュレータが答え直し、その答えが今動いているものへの入力になる
    private var answeredThrough: [String: Int] = [:]
    /// host の知らせを届いた順に読む（`deliver` は同期で呼ばれる）
    private nonisolated let inbox: AsyncStream<AgentHostNotice>.Continuation
    private nonisolated let runSink: AsyncStream<AgentHostNotice>.Continuation
    /// 実行のシェル（key が `ConversationRuns.keyPrefix` で始まる）の知らせ
    nonisolated let runNotices: AsyncStream<AgentHostNotice>

    init(host: any AgentHostTransport, fallback: InProcessAgentHost? = nil, logger: Logger, queueLimitBytes: Int = 4 << 20) {
        self.host = host
        self.fallback = fallback
        self.logger = logger
        self.queueLimitBytes = queueLimitBytes
        let (stream, continuation) = AsyncStream<AgentHostNotice>.makeStream()
        inbox = continuation
        (runNotices, runSink) = AsyncStream<AgentHostNotice>.makeStream()
        Task { [weak self] in
            for await notice in stream { await self?.route(notice) }
        }
    }

    // MARK: host

    nonisolated func deliver(_ notice: AgentHostNotice) { inbox.yield(notice) }

    /// host に繋がった（繋ぎ直した）。host は接続ごとに購読を持つので、開いている画面ごとに全画面から送り直す
    func hostConnected(version: Int?) async {
        hostVersion = version
        for id in viewers.keys { await sync(id) }
    }

    func hostDisconnected() { hostVersion = nil }

    private func requireHost(for key: String) throws {
        if fallbackKeys.contains(key) { return }
        guard let hostVersion else { throw Failure.hostUnavailable }
        guard hostVersion >= AgentHostWire.shellVersion else { throw Failure.hostOutdated }
    }

    private var hostServesShells: Bool { (hostVersion ?? 0) >= AgentHostWire.shellVersion }

    private func transport(for key: String) -> any AgentHostTransport {
        if fallbackKeys.contains(key), let fallback { return fallback }
        return host
    }

    private func startedFallback() async -> InProcessAgentHost? {
        guard let fallback else { return nil }
        if !fallbackStarted {
            fallbackStarted = true
            await fallback.start { [weak self] notice in self?.deliver(notice) }
        }
        return fallback
    }

    // MARK: 会話から

    func open(key: String, argv: [String], env: [String: String], cwd: String, cols: Int = 80, rows: Int = 24) async throws {
        if hostVersion != nil, !hostServesShells, !fallbackKeys.contains(key), await startedFallback() != nil { fallbackKeys.insert(key) }
        try requireHost(for: key)
        // 前からあるシェルの問い合わせは、誰かが答えたか待つのをやめている（daemon が起き直すと、どこまで答えたかが分からない）
        if answeredThrough[key] == nil { answeredThrough[key] = try await shellInfo(key) == nil ? 0 : .max }
        _ = try await transport(for: key).call(.shellOpen, key: key, argv: argv, env: env, cwd: cwd, data: nil, signal: nil, after: nil, through: nil, cols: cols, rows: rows)
    }

    /// 画面を通さずに書く（実行のシェル）
    func input(_ key: String, _ data: Data) async throws {
        try requireHost(for: key)
        _ = try await transport(for: key).call(
            .shellInput, key: key, argv: nil, env: nil, cwd: nil, data: data.base64EncodedString(), signal: nil, after: nil, through: nil, cols: nil, rows: nil)
    }

    /// 購読する（実行のシェル）：ためた出力と、その終わりの位置。以後の出力は `runNotices` に届く
    func subscribe(_ key: String) async throws -> (kept: Data, offset: Int) {
        try requireHost(for: key)
        let reply = try await transport(for: key).call(
            .shellSubscribe, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
        return (reply.data.flatMap { Data(base64Encoded: $0) } ?? Data(), reply.offset ?? 0)
    }

    /// シェルが生きているか。host に繋がっていなければ throw
    func isLive(_ key: String) async throws -> Bool {
        // シェルを扱えない host なら、開くときに `fallback` で新しく起こす
        if hostVersion != nil, !hostServesShells, !fallbackKeys.contains(key) { return false }
        try requireHost(for: key)
        return try await shellInfo(key) != nil
    }

    func close(_ key: String) async {
        guard (try? requireHost(for: key)) != nil else { return }
        do {
            _ = try await transport(for: key).call(.shellClose, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
        } catch {
            logger.warning("shell close failed", metadata: ["key": .string(key), "error": "\(error)"])
        }
    }

    /// 生きているシェルの key。host に繋がっていないか、シェルを持てない host で `fallback` も無ければ nil
    func liveKeys() async throws -> Set<String>? {
        var keys: Set<String> = []
        if hostServesShells {
            keys = try await Self.keys(in: host)
        } else if hostVersion == nil || fallback == nil {
            return nil
        }
        if !fallbackKeys.isEmpty, let fallback = await startedFallback() { keys.formUnion(try await Self.keys(in: fallback)) }
        return keys
    }

    private static func keys(in transport: any AgentHostTransport) async throws -> Set<String> {
        let reply = try await transport.call(.shellList, key: nil, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
        return Set(reply.shells?.map(\.key) ?? [])
    }

    private func shellInfo(_ key: String) async throws -> AgentHostShellInfo? {
        let reply = try await transport(for: key).call(.shellList, key: nil, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
        return reply.shells?.first { $0.key == key }
    }

    // MARK: 画面から

    /// 画面を足し、ためた出力を送り始める。返した id で `handle`・`next`・`leave` を呼ぶ
    func join(key: String, cols: Int, rows: Int) async -> UUID {
        let id = UUID()
        viewers[id] = Viewer(key: key, cols: cols, rows: rows)
        if (try? requireHost(for: key)) == nil {
            finish(id, .paneNotFound, Failure.hostOutdated.description)
        } else {
            await sync(id)
        }
        return id
    }

    func leave(_ id: UUID) async {
        guard let viewer = viewers.removeValue(forKey: id) else { return }
        viewer.waiter?.resume(returning: nil)
        if controllers[viewer.key] == id { controllers[viewer.key] = nil }
        guard !viewers.values.contains(where: { $0.key == viewer.key }) else { return }
        _ = try? await transport(for: viewer.key).call(
            .shellUnsubscribe, key: viewer.key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
    }

    func handle(_ id: UUID, _ message: TerminalClientMessage) async {
        guard let viewer = viewers[id], !viewer.ended else { return }
        switch message {
        case .acquire(let takeover):
            await acquire(id, takeover: takeover)
        case .input(let data):
            await write(id, data)
        case .resize(let cols, let rows):
            let size = AgentHostShells.clamp(cols: cols, rows: rows)
            viewers[id]?.cols = size.cols
            viewers[id]?.rows = size.rows
            if controllers[viewer.key] == id { await resize(viewer.key, size) }
        case .release:
            guard controllers[viewer.key] == id else { return }
            controllers[viewer.key] = nil
            send(id, .mode(.observe))
        }
    }

    /// 次に WebSocket へ書くもの。`nil` は終わり
    func next(_ id: UUID) async -> Outgoing? {
        guard var viewer = viewers[id] else { return nil }
        if !viewer.outgoing.isEmpty {
            let item = viewer.outgoing.removeFirst()
            viewer.queuedBytes -= Self.size(of: item)
            viewers[id] = viewer
            return item
        }
        if viewer.ended { return nil }
        return await withCheckedContinuation { viewers[id]?.waiter = $0 }
    }

    // MARK: 内部

    /// ためた出力を全画面で送る。待つ間に届いた出力は、ためた分に入っていない所から流す
    private func sync(_ id: UUID) async {
        guard let key = viewers[id]?.key else { return }
        viewers[id]?.held = []
        let reply: AgentHostReply
        let info: AgentHostShellInfo?
        do {
            reply = try await transport(for: key).call(
                .shellSubscribe, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
            info = sizes[key] == nil ? try await shellInfo(key) : nil
        } catch {
            finish(id, .paneNotFound, "シェルが無い: \(error)")
            return
        }
        guard viewers[id] != nil else { return }
        if let info { sizes[key] = (info.cols, info.rows) }
        let size = sizes[key] ?? (80, 24)
        let offset = reply.offset ?? 0
        send(id, .frame(seq: UInt64(offset), full: true, cols: size.cols, rows: size.rows))
        // 前の画面とスクロールバックを消してから描く（繋ぎ直した画面はエミュレータを使い回す）
        let kept = reply.data.flatMap { Data(base64Encoded: $0) } ?? Data()
        let answered = min(max((answeredThrough[key] ?? .max) - (offset - kept.count), 0), kept.count)
        push(id, .binary(Data("\u{1b}c\u{1b}[3J".utf8) + TerminalQueries.removing(from: kept.prefix(answered)) + kept.dropFirst(answered)))
        send(id, .mode(controllers[key] == id ? .control : .observe))
        viewers[id]?.deliveredThrough = offset
        let held = viewers[id]?.held ?? []
        viewers[id]?.held = nil
        for chunk in held { forward(id, start: chunk.start, chunk.data) }
    }

    private func route(_ notice: AgentHostNotice) {
        if notice.key.hasPrefix(ConversationRuns.keyPrefix) {
            if notice.event == .shellExit { fallbackKeys.remove(notice.key) }
            runSink.yield(notice)
            return
        }
        let ids = viewers.filter { $0.value.key == notice.key }.map(\.key)
        switch notice.event {
        case .shellOutput:
            guard let start = notice.seq, let data = notice.data.flatMap({ Data(base64Encoded: $0) }) else { return }
            for id in ids {
                if viewers[id]?.held != nil {
                    viewers[id]?.held?.append((start, data))
                } else {
                    forward(id, start: start, data)
                }
            }
        case .shellExit:
            fallbackKeys.remove(notice.key)
            controllers[notice.key] = nil
            sizes[notice.key] = nil
            answeredThrough[notice.key] = nil
            for id in ids { finish(id, .paneNotFound, "シェルが終わった") }
        default:
            break
        }
    }

    private func forward(_ id: UUID, start: Int, _ data: Data) {
        guard let through = viewers[id]?.deliveredThrough else { return }
        let end = start + data.count
        guard end > through else { return }
        viewers[id]?.deliveredThrough = end
        push(id, .binary(start >= through ? data : data.suffix(end - through)))
    }

    private func acquire(_ id: UUID, takeover: Bool) async {
        guard let viewer = viewers[id] else { return }
        let current = controllers[viewer.key]
        if current == id {
            send(id, .mode(.control))
            return
        }
        if current != nil, !takeover {
            send(id, .controllerBusy)
            return
        }
        if let current {
            send(current, .controlLost(.takenOver))
            send(current, .mode(.observe))
        }
        controllers[viewer.key] = id
        send(id, .mode(.control))
        await resize(viewer.key, (viewer.cols, viewer.rows))
    }

    /// 操作権を持たない画面の入力は、ほかに持つ画面が無ければ操作権を取ってから書く
    private func write(_ id: UUID, _ data: Data) async {
        guard let key = viewers[id]?.key else { return }
        if controllers[key] == nil { await acquire(id, takeover: false) }
        guard controllers[key] == id else {
            send(id, .controllerBusy)
            return
        }
        if let seen = viewers[id]?.deliveredThrough { answeredThrough[key] = max(answeredThrough[key] ?? 0, seen) }
        do {
            _ = try await transport(for: key).call(
                .shellInput, key: key, argv: nil, env: nil, cwd: nil, data: data.base64EncodedString(), signal: nil, after: nil, through: nil, cols: nil,
                rows: nil)
        } catch {
            logger.warning("shell input failed", metadata: ["key": .string(key), "bytes": .stringConvertible(data.count), "error": "\(error)"])
        }
    }

    /// 擬似端末の大きさを変え、開いている画面すべてに新しい大きさを知らせる
    private func resize(_ key: String, _ size: (cols: Int, rows: Int)) async {
        if let current = sizes[key], current == size { return }
        sizes[key] = size
        do {
            _ = try await transport(for: key).call(
                .shellResize, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: size.cols, rows: size.rows)
        } catch {
            logger.warning("shell resize failed", metadata: ["key": .string(key), "error": "\(error)"])
            return
        }
        for (id, viewer) in viewers where viewer.key == key {
            send(id, .frame(seq: UInt64(viewer.deliveredThrough), full: false, cols: size.cols, rows: size.rows))
        }
    }

    private func send(_ id: UUID, _ message: TerminalServerMessage) {
        guard let data = try? WireJSON.encoder().encode(message) else { return }
        push(id, .text(String(decoding: data, as: UTF8.self)))
    }

    private func finish(_ id: UUID, _ reason: TerminalCloseReason, _ message: String?) {
        guard let viewer = viewers[id], !viewer.ended else { return }
        send(id, .closed(reason: reason, message: message))
        push(id, .end(reason: reason.rawValue))
        viewers[id]?.ended = true
        if controllers[viewer.key] == id { controllers[viewer.key] = nil }
    }

    private func push(_ id: UUID, _ item: Outgoing) {
        guard var viewer = viewers[id], !viewer.ended else { return }
        if let waiter = viewer.waiter {
            viewer.waiter = nil
            viewers[id] = viewer
            waiter.resume(returning: item)
            return
        }
        let size = Self.size(of: item)
        if viewer.queuedBytes + size > queueLimitBytes, case .binary = item {
            logger.warning("shell viewer too slow; closing", metadata: ["key": .string(viewer.key), "queued": .stringConvertible(viewer.queuedBytes)])
            viewer.outgoing.removeAll()
            viewer.queuedBytes = 0
            viewers[id] = viewer
            finish(id, .queueOverflow, "未送信が \(queueLimitBytes) バイトを超えた")
            return
        }
        viewer.outgoing.append(item)
        viewer.queuedBytes += size
        viewers[id] = viewer
    }

    private static func size(of item: Outgoing) -> Int {
        switch item {
        case .text(let text): text.utf8.count
        case .binary(let data): data.count
        case .end: 0
        }
    }
}

/// 端末への問い合わせ（エミュレータが答えを入力として返す列）
enum TerminalQueries {
    /// DA1・DA2・DA3、DSR（状態・カーソルの位置）、DECRQM、XTVERSION、kitty のキーボードの問い、窓の大きさの問い、
    /// OSC 4・10〜12 の色の問い、XTGETTCAP
    private static let pattern = try! NSRegularExpression(
        pattern: #"\x1b\[[>=]?0?c|\x1b\[\??[56]n|\x1b\[\??[0-9;]*\$p|\x1b\[>0?q|\x1b\[\?u|\x1b\[1[468]t|\x1b\](?:1[012]|4;[0-9]+);\?(?:\x07|\x1b\\)|\x1bP\+q[0-9A-Fa-f;]*\x1b\\"#)

    static func removing(from data: some DataProtocol) -> Data {
        // latin1 はバイトと文字が 1 対 1 なので、UTF-8 の途中で切れても壊さずに戻せる
        guard let text = String(bytes: Array(data), encoding: .isoLatin1) else { return Data(data) }
        let range = NSRange(text.startIndex..., in: text)
        guard pattern.firstMatch(in: text, range: range) != nil else { return Data(data) }
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "").data(using: .isoLatin1) ?? Data(data)
    }
}
