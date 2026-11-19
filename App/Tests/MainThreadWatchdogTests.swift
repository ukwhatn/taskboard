import Foundation
import Testing
@testable import Taskboard

/// 主スレッドの見張り。見張る列を止め、渡した時計を進めてから放したときに、1 回だけ書き出し、戻ったら止まっていた長さを知らせるかを見る。
/// 時計はテストが進める（本物の時計だと、全体で回したときに見張りの列が遅れて起き、止まっていた長さが閾値をまたいだ）
@Suite struct MainThreadWatchdogTests {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [URL] = []
        private var stalls: [(ms: Int, file: URL?)] = []
        private var hitches: [Int] = []
        func hitched(_ ms: Int) { lock.withLock { hitches.append(ms) } }
        var hitchList: [Int] { lock.withLock { hitches } }
        func sampled(_ url: URL) { lock.withLock { samples.append(url) } }
        func stalled(_ ms: Int, _ file: URL?) { lock.withLock { stalls.append((ms, file)) } }
        var sampleCount: Int { lock.withLock { samples.count } }
        var stallList: [(ms: Int, file: URL?)] { lock.withLock { stalls } }
    }

    /// テストが進める時計。見張りが読んだ回数（合図を送るときと、見回りのたびに 1 回）も数える
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanoseconds: UInt64 = 1_000_000_000
        private var count = 0
        func now() -> DispatchTime { lock.withLock { count += 1; return DispatchTime(uptimeNanoseconds: nanoseconds) } }
        func advance(ms: UInt64) { lock.withLock { nanoseconds += ms * 1_000_000 } }
        var reads: Int { lock.withLock { count } }
    }

    /// 見張る列を止めてから見張りを始め、合図が止めた後ろに並ぶのを待つ。`stall` で時計を進めてから列を放し、見張りが返事を受けるまで待つ
    private func stall(
        ms: UInt64, box: Box, label: String, sample: Bool = true, whileStalled: (Clock, MainThreadWatchdog) async throws -> Void = { _, _ in }
    ) async throws {
        let clock = Clock()
        let watched = DispatchQueue(label: label)
        let gate = DispatchSemaphore(value: 0)
        let sampler: (@Sendable (URL) -> Void)? = sample ? { @Sendable url in box.sampled(url) } : nil
        watched.async { gate.wait() }
        let dog = MainThreadWatchdog(
            directory: FileManager.default.temporaryDirectory.appending(path: "watchdog-tests-\(UUID().uuidString)"),
            threshold: .milliseconds(300), hitchThreshold: .milliseconds(100), interval: .milliseconds(20), watched: watched,
            sample: sampler, now: { clock.now() }, onHitch: { box.hitched($0) }, onStall: { box.stalled($0, $1) })
        dog.start()
        try await waitUntil { clock.reads >= 1 }
        clock.advance(ms: ms)
        try await whileStalled(clock, dog)
        gate.signal()
        // 合図が返り（watched）、見張りの列で返事を受け終える（stop は見張りの列に並ぶので、返事の後に来る）まで
        watched.sync {}
        dog.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "待っても起きない")
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("見張る列が閾値より長く止まると 1 回だけ書き出し、戻ったら止まっていた長さを書き出したファイルと一緒に知らせる。引っかかりには数えない")
    func samplesOnceAndReportsAfterRecovery() async throws {
        let box = Box()
        try await stall(ms: 1_000, box: box, label: "watched") { _, _ in
            try await waitUntil { box.sampleCount == 1 }
            // 書き出した後の見回り（時計を読まない）を何回か通しても、書き出し直さない。遅い環境では通る回が減るだけで、誤って落ちない
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(box.sampleCount == 1, "1 回の停止で書き出すのは 1 回")
        let stall = try #require(box.stallList.first)
        #expect(box.stallList.count == 1)
        #expect(stall.ms == 1_000)
        #expect(stall.file?.lastPathComponent.hasPrefix("hang-") == true)
        #expect(stall.file?.pathExtension == "txt")
        #expect(box.hitchList.isEmpty, "書き出した停止は引っかかりに数えない")
    }

    @Test("書き出すほどでない遅れ（引っかかり）は、書き出さずに長さだけ知らせる")
    func reportsHitchesWithoutSampling() async throws {
        let box = Box()
        try await stall(ms: 200, box: box, label: "watched-hitch") { clock, _ in
            // 閾値に届かないので、止まっている間の見回りでは書き出さない
            let reads = clock.reads
            try await waitUntil { clock.reads >= reads + 3 }
        }
        #expect(box.sampleCount == 0)
        #expect(box.stallList.isEmpty)
        #expect(box.hitchList == [200])
    }

    @Test("書き出さない見張り（iOS）も、閾値より長い止まりは戻ったときに長さだけを止まりとして知らせる")
    func reportsStallWithoutSampler() async throws {
        let box = Box()
        try await stall(ms: 1_000, box: box, label: "watched-nosample", sample: false) { _, _ in
            // 見回り（20 ms ごと）が何回か通るまで。閾値を越えたと決めた後の見回りは時計を読まないので、読んだ回数では待てない
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(box.sampleCount == 0)
        #expect(box.stallList.count == 1)
        #expect(box.stallList.first?.ms == 1_000)
        #expect(box.stallList.first?.file == nil)
        #expect(box.hitchList.isEmpty)
    }

    @Test("背面に移った後に返った合図は数えず、前面に戻ってからの止まりは数える（iOS は背面でプロセスごと止まる）")
    func ignoresTimeInBackground() async throws {
        let box = Box()
        try await stall(ms: 0, box: box, label: "watched-background") { clock, dog in
            dog.pause()
            clock.advance(ms: 60_000)
            // 止まっている間の見回りが何回か通っても、背面の間は数えない
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(box.stallList.isEmpty, "背面の間に止まっていた時間は止まりにしない")
        #expect(box.hitchList.isEmpty)
        #expect(box.sampleCount == 0)
    }

    @Test("閾値より短い遅れは知らせない")
    func ignoresShortDelays() async throws {
        let box = Box()
        try await stall(ms: 50, box: box, label: "watched-short")
        #expect(box.sampleCount == 0)
        #expect(box.stallList.isEmpty)
        #expect(box.hitchList.isEmpty)
    }

    @Test("書き出したファイルは新しい順に決まった数だけ残し、古いものから消す")
    func prunesOldFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watchdog-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for day in 10...14 { FileManager.default.createFile(atPath: directory.appending(path: "hang-2026-10-\(day)T000000.txt").path, contents: Data()) }
        FileManager.default.createFile(atPath: directory.appending(path: "app-events.jsonl").path, contents: Data())
        MainThreadWatchdog.prune(directory, keep: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["app-events.jsonl", "hang-2026-10-13T000000.txt", "hang-2026-10-14T000000.txt"])
    }
}
