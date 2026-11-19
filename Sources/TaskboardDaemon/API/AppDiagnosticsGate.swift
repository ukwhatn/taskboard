import Foundation
import TaskboardKit

/// 端末から届いた止まりの記録のうち、ログに残すものを選ぶ。前に受けた id は残さず、端末ごとに 1 時間に `hourlyLimit` 件までにする。
/// メモリにだけ持つ（daemon を再起動すると同じ id をもう一度残しうるが、アプリも送った id を覚えているので 2 回は届かない）
actor AppDiagnosticsGate {
    typealias Clock = @Sendable () -> Date

    static let hourlyLimit = 30
    /// 端末ごとに覚えておく id の数
    static let rememberedIDs = 500

    private let now: Clock
    private var seen: [String: [String]] = [:]
    private var logged: [String: [Date]] = [:]

    init(now: @escaping Clock = { Date() }) {
        self.now = now
    }

    /// 残す記録と、残さなかった数
    func admit(_ reports: [AppDiagnosticReport], device: String) -> (admitted: [AppDiagnosticReport], skipped: Int) {
        let date = now()
        var recent = (logged[device] ?? []).filter { date.timeIntervalSince($0) < 3600 }
        var ids = seen[device] ?? []
        var admitted: [AppDiagnosticReport] = []
        for report in reports where !ids.contains(report.id) && recent.count < Self.hourlyLimit {
            ids.append(report.id)
            recent.append(date)
            admitted.append(report)
        }
        seen[device] = Array(ids.suffix(Self.rememberedIDs))
        logged[device] = recent
        return (admitted, reports.count - admitted.count)
    }
}
