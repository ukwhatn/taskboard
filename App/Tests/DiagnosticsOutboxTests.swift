import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// daemon へ送る止まりの記録の溜まり。同じ記録は 1 回だけ溜め、接続先ごとに 1 回だけ送り、全部へ送ったら捨てる
@Suite struct DiagnosticsOutboxTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(_ id: String, kind: AppDiagnosticReport.Kind = .stall) -> AppDiagnosticReport {
        AppDiagnosticReport(id: id, kind: kind, at: start, durationMS: 2_000)
    }

    @Test("同じ id は 2 回溜めない")
    func dedupes() {
        var outbox = DiagnosticsOutbox()
        let queued1 = outbox.enqueue(report("a"), now: start)
        #expect(queued1)
        let queued2 = outbox.enqueue(report("a"), now: start)
        #expect(!queued2)
        #expect(outbox.entries.map(\.report.id) == ["a"])
    }

    @Test("見張りの止まりは 1 時間に 10 件まで。MetricKit の診断は数えない。1 時間たつとまた溜める")
    func limitsStallsPerHour() {
        var outbox = DiagnosticsOutbox()
        for n in 0..<12 { outbox.enqueue(report("s\(n)"), now: start.addingTimeInterval(Double(n))) }
        #expect(outbox.entries.count == 10)
        let queued3 = outbox.enqueue(report("h", kind: .hang), now: start)
        #expect(queued3)
        let queued4 = outbox.enqueue(report("s12"), now: start.addingTimeInterval(3599))
        #expect(!queued4)
        let queued5 = outbox.enqueue(report("s13"), now: start.addingTimeInterval(3601))
        #expect(queued5)
        #expect(outbox.entries.count == 12)
    }

    @Test("溜めるのは 50 件までで、越えたら古いものから捨てる")
    func capsPending() {
        var outbox = DiagnosticsOutbox()
        for n in 0..<55 { outbox.enqueue(report("h\(n)", kind: .hang), now: start) }
        #expect(outbox.entries.count == 50)
        #expect(outbox.entries.first?.report.id == "h5")
    }

    @Test("接続先ごとに送っていない分を 20 件ずつ出し、全部の接続先へ送ったものだけ捨てる")
    func sendsOncePerTarget() {
        var outbox = DiagnosticsOutbox()
        for n in 0..<25 { outbox.enqueue(report("h\(n)", kind: .hang), now: start) }
        let first = outbox.due(for: "studio")
        #expect(first.count == 20)
        #expect(first.first?.id == "h0")
        outbox.markSent(Set(first.map(\.id)), to: "studio")
        #expect(outbox.due(for: "studio").map(\.id) == ["h20", "h21", "h22", "h23", "h24"])
        #expect(outbox.due(for: "second").count == 20, "別の接続先には送っていない")

        outbox.prune(targets: ["studio", "second"], now: start)
        #expect(outbox.entries.count == 25, "secondMac へ送るまで残す")
        outbox.prune(targets: ["studio"], now: start)
        #expect(outbox.entries.map(\.report.id) == ["h20", "h21", "h22", "h23", "h24"])
    }

    @Test("接続先が無い間は残し、7 日を過ぎたら捨てる")
    func keepsWithoutTargetsUntilOld() {
        var outbox = DiagnosticsOutbox()
        outbox.enqueue(report("a"), now: start)
        outbox.prune(targets: [], now: start.addingTimeInterval(6 * 24 * 3600))
        #expect(outbox.entries.count == 1)
        outbox.prune(targets: [], now: start.addingTimeInterval(7 * 24 * 3600 + 1))
        #expect(outbox.entries.isEmpty)
    }

    @Test("送れなかった分は保存先に残し、次の起動の送り口が送る。送り終えた分は送り直さない")
    @MainActor
    func reporterPersistsUntilSent() async throws {
        let suite = "uk.whatn.taskboard.tests.diagnostics.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        final class Sent: @unchecked Sendable {
            private let lock = NSLock()
            private var bodies: [[String]] = []
            func add(_ ids: [String]) { lock.withLock { bodies.append(ids) } }
            var all: [[String]] { lock.withLock { bodies } }
        }
        struct Offline: Error {}
        let sent = Sent()
        let targets = ["studio": DaemonEndpoint(baseURL: URL(string: "http://studio.test")!, token: "t")]

        let offline = DiagnosticsReporter(defaults: defaults, send: { _, _ in throw Offline() }, now: { start })
        offline.record([report("a"), report("b", kind: .hang)], targets: targets)
        try await Task.sleep(for: .milliseconds(50))
        #expect(offline.outbox.entries.count == 2)

        let next = DiagnosticsReporter(defaults: defaults, send: { _, body in
            sent.add(body.reports.map(\.id))
            return AppDiagnosticsResult(logged: body.reports.count, skipped: 0)
        }, now: { start })
        #expect(next.outbox.entries.count == 2, "前の起動の溜まりを読む")
        next.flush(targets: targets)
        let deadline = ContinuousClock.now + .seconds(5)
        while !next.outbox.entries.isEmpty {
            try #require(ContinuousClock.now < deadline, "送り終わらない")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent.all == [["a", "b"]])
        next.flush(targets: targets)
        try await Task.sleep(for: .milliseconds(50))
        #expect(sent.all.count == 1, "送り終えた分は送り直さない")
    }
}
