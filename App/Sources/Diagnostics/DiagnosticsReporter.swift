import Foundation
import TaskboardKit

/// 接続先の daemon へまだ送っていない止まりの記録。接続先ごとに 1 回だけ送り、全部の接続先へ送ったら捨てる
struct DiagnosticsOutbox: Codable, Equatable {
    static let pendingLimit = 50
    /// 見張りの止まりは 1 時間にこの数まで溜める（同じ操作で何度も止まったときに、同じ止まりを送り続けない）
    static let stallsPerHour = 10
    /// 送れないまま、これより古くなった記録は捨てる
    static let keep: TimeInterval = 7 * 24 * 3600

    struct Entry: Codable, Equatable {
        var report: AppDiagnosticReport
        var queuedAt: Date
        /// 送り終えた接続先の id
        var sentTo: Set<String> = []
    }

    private(set) var entries: [Entry] = []
    private var stallTimes: [Date] = []

    /// 溜めたら true。前に溜めた id と、1 時間の上限を越えた見張りの止まりは溜めない
    @discardableResult
    mutating func enqueue(_ report: AppDiagnosticReport, now: Date) -> Bool {
        guard !entries.contains(where: { $0.report.id == report.id }) else { return false }
        if report.kind == .stall {
            stallTimes = stallTimes.filter { now.timeIntervalSince($0) < 3600 }
            guard stallTimes.count < Self.stallsPerHour else { return false }
            stallTimes.append(now)
        }
        entries.append(Entry(report: report, queuedAt: now))
        if entries.count > Self.pendingLimit { entries.removeFirst(entries.count - Self.pendingLimit) }
        return true
    }

    /// その接続先へ次に送る分（古い順に 1 回の上限まで）
    func due(for target: String) -> [AppDiagnosticReport] {
        Array(entries.filter { !$0.sentTo.contains(target) }.prefix(AppDiagnosticsUpload.reportLimit).map(\.report))
    }

    mutating func markSent(_ ids: Set<String>, to target: String) {
        for index in entries.indices where ids.contains(entries[index].report.id) { entries[index].sentTo.insert(target) }
    }

    /// 今の接続先の全部へ送った記録と、古くなった記録を捨てる。接続先が 1 つも無い間は、古くなるまで残す
    mutating func prune(targets: Set<String>, now: Date) {
        entries.removeAll { entry in
            (!targets.isEmpty && targets.isSubset(of: entry.sentTo)) || now.timeIntervalSince(entry.queuedAt) > Self.keep
        }
    }
}

/// 止まりの記録を溜めて、接続先の daemon へ送る（`POST /v1/devices/current/diagnostics`）。溜めた分はこの端末の設定に置き、
/// 次の起動でも送る（MetricKit の診断は起動の直後に届き、そのときはまだ接続先に繋がっていないことがある）
@MainActor
final class DiagnosticsReporter {
    typealias Send = @Sendable (DaemonEndpoint, AppDiagnosticsUpload) async throws -> AppDiagnosticsResult

    static let defaultsKey = "diagnostics.outbox"
    static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }()
    #if os(iOS)
    static let osVersion = "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
    #else
    static let osVersion = "macOS " + ProcessInfo.processInfo.operatingSystemVersionString
    #endif

    private let defaults: UserDefaults
    private let send: Send
    private let now: () -> Date
    private(set) var outbox: DiagnosticsOutbox
    private var inFlight: Set<String> = []

    init(
        defaults: UserDefaults,
        send: @escaping Send = { endpoint, body in try await DaemonClient(endpoint: endpoint, session: DaemonClient.cookieless).sendDiagnostics(body) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.send = send
        self.now = now
        outbox = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(DiagnosticsOutbox.self, from: $0) } ?? DiagnosticsOutbox()
    }

    func record(_ reports: [AppDiagnosticReport], targets: [String: DaemonEndpoint]) {
        var changed = false
        for report in reports { changed = outbox.enqueue(report, now: now()) || changed }
        if changed { save() }
        flush(targets: targets)
    }

    /// 接続先ごとに、まだ送っていない分を送る。失敗した接続先は、次に記録が増えるか前面に戻るまで送り直さない
    func flush(targets: [String: DaemonEndpoint]) {
        outbox.prune(targets: Set(targets.keys), now: now())
        for (target, endpoint) in targets where !inFlight.contains(target) {
            let reports = outbox.due(for: target)
            guard !reports.isEmpty else { continue }
            inFlight.insert(target)
            Task {
                // 前の版の daemon（口が無い 404）にも、繋がらない接続先にも、送れていないものとして次の機会を待つ
                let sent = (try? await send(endpoint, AppDiagnosticsUpload(reports: reports))) != nil
                inFlight.remove(target)
                guard sent else { return }
                outbox.markSent(Set(reports.map(\.id)), to: target)
                save()
                // 1 回の上限より多く溜まっていたら、残りを続けて送る
                flush(targets: targets)
            }
        }
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(outbox), forKey: Self.defaultsKey)
    }
}
