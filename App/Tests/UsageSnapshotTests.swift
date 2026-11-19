import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 設定の［利用状況］。fixtures の記録（`FixtureUsage`。実機に近い量）を Mac 2 台ぶん合わせて、設定の中身の幅で描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct UsageSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    /// 撮る日の終わり（BoardSnapshotTests.today と同じ日の 18 時に区切りを揃える）
    static func query(_ period: UsagePeriod) -> UsageHistoryQuery {
        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: BoardSnapshotTests.today) ?? BoardSnapshotTests.today
        return UsageHistoryQuery(from: end.addingTimeInterval(-period.seconds), to: end, bucketSeconds: period.bucketSeconds)
    }

    private func render(_ period: UsagePeriod, machines: [String], name: String, height: CGFloat, testName: String = #function) throws {
        let (width, appearance) = try Matrix.parse(name)
        let query = Self.query(period)
        let report = UsageReport(machines.map { UsageReport.Machine(name: $0, history: FixtureUsage.history(query, seed: $0)) })
        let view = Page(maxWidth: ReadableWidth.text) {
            UsageDashboard(report: report, range: query.from...query.to, period: period)
        }
        .pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: height), variant: appearance), named: name, testName: testName)
    }

    @Test("7日・Mac 2 台（利用枠は Mac ごとの線、ほかは合算）", arguments: Matrix.cases([720]))
    func week(name: String) throws {
        try render(.week, machines: ["Studio", "MacBook Air"], name: name, height: 3000)
    }

    @Test("24時間・Mac 1 台（凡例の無い利用枠）", arguments: Matrix.cases([520]))
    func day(name: String) throws {
        try render(.day, machines: ["Studio"], name: name, height: 3000)
    }

    @Test("30日・Mac 2 台（日ごとの棒）", arguments: Matrix.cases([720]))
    func month(name: String) throws {
        try render(.month, machines: ["Studio", "MacBook Air"], name: name, height: 3000)
    }

    @Test("圧縮が自動だけの期間も、凡例は自動・手動・Codex の 1 列", arguments: Matrix.cases([520]))
    func compactionsOfOneKind(name: String) throws {
        let (width, appearance) = try Matrix.parse(name)
        let query = Self.query(.day)
        var history = FixtureUsage.history(query, seed: "Studio")
        history.compactions = history.compactions.filter { $0.trigger == .auto }
        let report = UsageReport([UsageReport.Machine(name: "Studio", history: history)])
        // 一番上の目盛りはグラフの枠の上にはみ出して描かれる（画面では節の見出しの下に入る）
        let view = Page { UsageCompactionChart(points: report.compactions, range: query.from...query.to).padding(.top, Space.block) }.pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 260), variant: appearance), named: name)
    }

    @Test("記録が無い期間（いつから記録があるか）", arguments: Matrix.cases([520]))
    func empty(name: String) throws {
        let (width, appearance) = try Matrix.parse(name)
        let view = Page {
            Banner(kind: .error, message: UserFacingError("MacBook Airの利用状況を読み込めませんでした", cause: nil, remedy: UserFacingError.updateDaemon).text)
            UsageEmpty(since: BoardSnapshotTests.today.addingTimeInterval(-3 * 86_400))
        }
        .pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 240), variant: appearance), named: name)
    }

    @Test("fixtures の記録は同じ問い合わせなら同じ値で、Mac の名前で変わる")
    func fixtureIsStable() {
        let query = Self.query(.week)
        #expect(FixtureUsage.history(query, seed: "Studio") == FixtureUsage.history(query, seed: "Studio"))
        #expect(FixtureUsage.history(query, seed: "Studio") != FixtureUsage.history(query, seed: "Air"))
        // 本番に近い量: 7 日で区切り 168、応答は 1 日 5,000 回前後
        let history = FixtureUsage.history(query, seed: "Studio")
        #expect(history.samples.count == 168)
        let requests = history.tokens.reduce(0) { $0 + $1.requests }
        #expect((25_000...50_000).contains(requests))
    }
}
