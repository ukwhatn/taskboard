import Foundation
import os

/// 主スレッドの応答を見張る。`hitchThreshold` より長くふさがったら戻ったときに長さを知らせ（引っかかり）、
/// `threshold` より長く応答しないときは自分のスタックを `hang-<時刻>.txt` に書き出して、戻ったら止まっていた長さを知らせる。
/// 強制終了した hang は macOS が ips も spindump も残さないことがあり、何で止まったかを後から引けないため。
/// iOS は別のプロセスを起こせないので書き出さず、止まっていた長さだけを知らせる（積み重ねは MetricKit の `MXHangDiagnostic` で取る）
final class MainThreadWatchdog: @unchecked Sendable {
    static let keepFiles = 10

    let directory: URL
    private let threshold: DispatchTimeInterval
    private let hitchThreshold: DispatchTimeInterval
    private let interval: DispatchTimeInterval
    private let watched: DispatchQueue
    private let sample: (@Sendable (URL) -> Void)?
    private let onHitch: @Sendable (_ ms: Int) -> Void
    private let onStall: @Sendable (_ ms: Int, _ file: URL?) -> Void
    private let now: @Sendable () -> DispatchTime
    private let queue = DispatchQueue(label: "uk.whatn.taskboard.watchdog", qos: .utility)
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "watchdog")
    // 以下は queue の中だけで触る
    private var timer: DispatchSourceTimer?
    /// 合図を送って、まだ返っていない時刻
    private var sentAt: DispatchTime?
    /// この停止を閾値を越えた止まりと決めた（1 回の停止で 1 回だけ書き出す）
    private var stalled = false
    private var sampledFile: URL?
    /// 背面にいる間は合図を送らない。iOS は背面でプロセスごと止まるので、前に送った合図が前面に戻ってから返り、背面の時間まで止まりに数えてしまう
    private var paused = false
    /// `pause` のたびに進める。前の番号で送った合図の返事は捨てる
    private var epoch = 0

    init(
        directory: URL, threshold: DispatchTimeInterval = .milliseconds(1500), hitchThreshold: DispatchTimeInterval = .milliseconds(100),
        interval: DispatchTimeInterval = .milliseconds(100), watched: DispatchQueue = .main, sample: (@Sendable (URL) -> Void)? = MainThreadWatchdog.defaultSample,
        now: @escaping @Sendable () -> DispatchTime = { .now() },
        onHitch: @escaping @Sendable (_ ms: Int) -> Void, onStall: @escaping @Sendable (_ ms: Int, _ file: URL?) -> Void
    ) {
        self.directory = directory
        self.threshold = threshold
        self.hitchThreshold = hitchThreshold
        self.onHitch = onHitch
        self.interval = interval
        self.watched = watched
        self.sample = sample
        self.onStall = onStall
        self.now = now
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// 背面に移るとき。戻るまで数えない
    func pause() {
        queue.async { [self] in
            paused = true
            epoch += 1
            sentAt = nil
            stalled = false
            sampledFile = nil
        }
    }

    /// 前面に戻ったとき
    func resume() {
        queue.async { [self] in paused = false }
    }

    private func tick() {
        guard !paused else { return }
        guard let sentAt else {
            let sent = now()
            let epoch = epoch
            self.sentAt = sent
            watched.async { [weak self] in self?.queue.async { self?.beat(sent: sent, epoch: epoch) } }
            return
        }
        guard !stalled, now() > sentAt + threshold else { return }
        stalled = true
        guard let sample else {
            Self.logger.error("main thread stalled")
            return
        }
        let file = directory.appending(path: "hang-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).txt")
        sampledFile = file
        Self.logger.error("main thread stalled, sampling to \(file.lastPathComponent, privacy: .public)")
        sample(file)
    }

    private func beat(sent: DispatchTime, epoch: Int) {
        guard epoch == self.epoch else { return }
        defer {
            sentAt = nil
            stalled = false
            sampledFile = nil
        }
        let returned = now()
        let ms = Int((returned.uptimeNanoseconds - sent.uptimeNanoseconds) / 1_000_000)
        if stalled {
            onStall(ms, sampledFile)
        } else if returned > sent + hitchThreshold {
            onHitch(ms)
        }
    }

    #if os(macOS)
    static let defaultSample: (@Sendable (URL) -> Void)? = runSample

    /// `sample` は 2 秒ぶん主スレッドを含む全スレッドを書く。待たずに戻る（その間も見張りを続ける）。
    /// 3 秒待ってから取ると、止まりの終わりの 1 秒しか取れなかった（20:39 の 4.3 秒の止まり）
    private static let runSample: @Sendable (URL) -> Void = { file in
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in prune(file.deletingLastPathComponent(), keep: keepFiles) }
        do { try process.run() } catch { logger.error("sample failed: \(error.localizedDescription, privacy: .public)") }
    }
    #else
    static let defaultSample: (@Sendable (URL) -> Void)? = nil
    #endif

    /// `hang-*.txt` を名前（時刻）の新しい順に `keep` 個だけ残す
    static func prune(_ directory: URL, keep: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }
            .sorted(by: >)
        for name in names.dropFirst(keep) { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
    }
}
