import Charts
import SwiftUI
import TaskboardKit

/// 利用状況の期間。粒度は daemon に頼む区切りで、トークンの棒の幅（`tokenUnit`）と揃える
enum UsagePeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: String(localized: "24時間")
        case .week: String(localized: "7日")
        case .month: String(localized: "30日")
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    var bucketSeconds: Int {
        switch self {
        case .day: 900
        case .week: 3600
        case .month: 86_400
        }
    }

    /// トークンの棒 1 本の幅。daemon はトークンを 1 時間より細かく分けない
    var tokenUnit: Calendar.Component { self == .month ? .day : .hour }

    /// 終わりを次の区切りに揃えた問い合わせ（区切りの途中で切ると、最後の点だけ値が小さく見える）
    func query(now: Date) -> UsageHistoryQuery {
        let bucket = TimeInterval(bucketSeconds)
        let end = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / bucket).rounded(.up) * bucket)
        return UsageHistoryQuery(from: end.addingTimeInterval(-seconds), to: end, bucketSeconds: bucketSeconds)
    }
}

/// 設定の［利用状況］。接続先の daemon が貯めた記録を期間と Mac で読み、グラフにする。読めなかった Mac は帯で知らせ、読めた Mac だけで描く
struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var period = UsagePeriod.week
    /// 選んだ Mac の接続設定の id。nil はすべての Mac
    @State private var scope: String?
    @State private var loaded: Loaded?
    @State private var loading = false
    @State private var reloads = 0

    struct Loaded {
        var report: UsageReport
        var failures: [UserFacingError]
        var range: ClosedRange<Date>
        var period: UsagePeriod
    }

    private struct LoadKey: Hashable {
        var period: UsagePeriod
        var scope: String?
        var machines: [String]
        var reloads: Int
    }

    var body: some View {
        let machines = model.settingsMachines
        Page(maxWidth: ReadableWidth.text) {
            controls(machines)
            if let loaded {
                ForEach(loaded.failures) { Banner(kind: .error, message: $0.text) }
                if loaded.report.isEmpty {
                    UsageEmpty(since: loaded.report.recordingSince)
                } else {
                    UsageDashboard(report: loaded.report, range: loaded.range, period: loaded.period)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: LoadKey(period: period, scope: scope, machines: machines.map(\.fleetID), reloads: reloads)) { await load(machines) }
    }

    private func controls(_ machines: [SettingsBoardScope]) -> some View {
        HStack(spacing: Space.row) {
            Picker("期間", selection: $period) {
                ForEach(UsagePeriod.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if machines.count > 1 {
                Picker("Mac", selection: $scope) {
                    Text("すべてのMac").tag(String?.none)
                    ForEach(machines, id: \.fleetID) { Text(verbatim: model.machineName(fleetID: $0.fleetID, state: $0.state)).tag(Optional($0.fleetID)) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: Space.row)
            if loading && loaded != nil { ProgressView().controlSize(.small) }
            Button("再読み込み", systemImage: "arrow.clockwise") { reloads += 1 }
                .labelStyle(.iconOnly)
                .disabled(loading)
        }
    }

    private func load(_ machines: [SettingsBoardScope]) async {
        let targets = machines.filter { scope == nil || $0.fleetID == scope }.compactMap { target in
            model.fleet.usageHistorySource(fleetID: target.fleetID).map { (name: model.machineName(fleetID: target.fleetID, state: target.state), source: $0) }
        }
        loading = true
        defer { loading = false }
        let query = period.query(now: Date())
        let results = await withTaskGroup(of: (Int, Result<UsageHistory, any Error>).self) { group in
            for (index, target) in targets.enumerated() {
                let source = target.source
                group.addTask {
                    do { return (index, .success(try await source.usageHistory(query))) } catch { return (index, .failure(error)) }
                }
            }
            var results: [(Int, Result<UsageHistory, any Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled else { return }
        var histories: [UsageReport.Machine] = []
        var failures: [UserFacingError] = []
        for (index, result) in results {
            let name = targets[index].name
            switch result {
            case .success(let history): histories.append(UsageReport.Machine(name: name, history: history))
            case .failure(let error):
                if let failure = UserFacingError("\(name)の利用状況を読み込めませんでした", error: error) { failures.append(failure) }
            }
        }
        loaded = Loaded(report: UsageReport(histories), failures: failures, range: query.from...query.to, period: period)
    }
}

/// 期間の中に記録が無いとき。記録は daemon が動き始めてからの分だけなので、いつからあるかを添える
struct UsageEmpty: View {
    let since: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            Text("この期間の記録はありません").textRole(.body)
            if let since {
                Text("記録は\(UsageFormat.day(since))からあります。").textRole(.secondary)
            } else {
                Text("記録はTaskboardを更新した後の応答から貯まります。").textRole(.secondary)
            }
        }
    }
}

/// 利用状況のグラフの並び。`UsageSettings` が読み込んだ値を描くだけ（snapshot test は値を直に渡す）
struct UsageDashboard: View {
    let report: UsageReport
    let range: ClosedRange<Date>
    let period: UsagePeriod

    var body: some View {
        if !report.windows.isEmpty {
            PageSection(String(localized: "利用枠")) {
                ForEach(report.windows, id: \.window) { series in
                    UsageWindowChart(series: series, machines: report.machines, range: range)
                }
            }
        }
        if report.active.contains(where: { $0.count > 0 }) {
            PageSection(String(localized: "動いていたセッション")) {
                Text("5分の間に応答したセッションの数です。").textRole(.secondary)
                UsageActiveChart(points: report.active, range: range)
            }
        }
        if !report.tokens.isEmpty {
            PageSection(String(localized: "トークン")) {
                UsageTokenSummary(report: report)
                UsageTokenChart(points: report.tokens, range: range, unit: period.tokenUnit)
                UsageModelTable(rows: report.models)
            }
        }
        if !report.sessions.isEmpty {
            PageSection(String(localized: "セッションごとのトークン")) {
                Text("トークンの多い順に\(report.sessions.count)件を表示します。").textRole(.secondary)
                UsageSessionTable(rows: report.sessions, showsMachine: report.machines.count > 1)
            }
        }
        if !report.skills.isEmpty {
            PageSection(String(localized: "スキル")) {
                UsageSkillChart(rows: report.skills)
            }
        }
        if report.compactionCounts != (0, 0, 0) {
            PageSection(String(localized: "圧縮")) {
                Text(UsageFormat.compactions(report.compactionCounts)).textRole(.body)
                if !report.compactions.isEmpty {
                    Text("圧縮の直前のコンテキスト").textRole(.caption)
                    UsageCompactionChart(points: report.compactions, range: range)
                }
            }
        }
    }
}

// MARK: - グラフ

/// 1 つの窓の使用率の推移。系列は Mac（アカウントが Mac ごとに違うことがあるので足さない）
struct UsageWindowChart: View {
    let series: UsageReport.WindowSeries
    let machines: [String]
    let range: ClosedRange<Date>
    @State private var selected: Date?

    var body: some View {
        let shown = machines.filter { name in series.points.contains { $0.machine == name } }
        VStack(alignment: .leading, spacing: Space.inline) {
            Text(UsageFormat.window(series)).textRole(.caption)
            Chart {
                ForEach(series.points, id: \.self) { point in
                    LineMark(x: .value("時刻", point.at), y: .value("使用率", point.percent))
                        .foregroundStyle(by: .value("Mac", point.machine))
                        .lineStyle(StrokeStyle(lineWidth: UsageChartMetrics.line))
                }
                if let selected, let at = UsageFormat.nearest(selected, in: series.points.map(\.at)) {
                    RuleMark(x: .value("時刻", at))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            UsageTip(title: UsageFormat.time(at), lines: series.points.filter { $0.at == at }.map { "\($0.machine) \(UsageText.percent($0.percent))" })
                        }
                }
            }
            .chartForegroundStyleScale(domain: machines, range: UsageChartPalette.colors(machines.count))
            .chartLegend(shown.count > 1 ? .visible : .hidden)
            .chartXScale(domain: range)
            .chartYScale(domain: 0...max(100, series.points.map(\.percent).max() ?? 0))
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(UsageText.percent(value.as(Double.self))) }
                }
            }
            .chartXSelection(value: $selected)
            .frame(height: UsageChartMetrics.windowHeight)
        }
    }
}

/// 応答したセッションの数。系列は Claude Code と Codex
struct UsageActiveChart: View {
    let points: [UsageReport.ActivePoint]
    let range: ClosedRange<Date>
    @State private var selected: Date?

    var body: some View {
        let engines = AgentKind.allCases.filter { engine in points.contains { $0.engine == engine } }.map(\.label)
        Chart {
            ForEach(points, id: \.self) { point in
                LineMark(x: .value("時刻", point.at), y: .value("セッション", point.count))
                    .foregroundStyle(by: .value("種類", point.engine.label))
                    .interpolationMethod(.stepEnd)
                    .lineStyle(StrokeStyle(lineWidth: UsageChartMetrics.line))
            }
            if let selected, let at = UsageFormat.nearest(selected, in: points.map(\.at)) {
                RuleMark(x: .value("時刻", at))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        UsageTip(title: UsageFormat.time(at), lines: points.filter { $0.at == at }.map { String(localized: "\($0.engine.label) \($0.count)件") })
                    }
            }
        }
        .chartForegroundStyleScale(domain: engines, range: UsageChartPalette.colors(engines.count))
        .chartLegend(engines.count > 1 ? .visible : .hidden)
        .chartXScale(domain: range)
        .chartXSelection(value: $selected)
        .frame(height: UsageChartMetrics.height)
    }
}

/// トークンの合計と、セッション 1 つあたり
struct UsageTokenSummary: View {
    let report: UsageReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.section) {
            LabeledContent("合計", value: UsageFormat.tokens(report.totalTokens.total))
            if let average = report.tokensPerSession {
                LabeledContent("1セッションあたり", value: UsageFormat.tokens(average))
                LabeledContent("セッション", value: String(localized: "\(report.sessionCount)件"))
            }
        }
        .textRole(.body)
    }
}

/// トークンの種類ごとの積み上げ
struct UsageTokenChart: View {
    let points: [UsageReport.TokenPoint]
    let range: ClosedRange<Date>
    let unit: Calendar.Component
    @State private var selected: Date?

    private var kinds: [String] { UsageReport.TokenKind.allCases.map(UsageFormat.kind) }

    var body: some View {
        Chart {
            ForEach(points, id: \.self) { point in
                BarMark(x: .value("時刻", point.at, unit: unit), y: .value("トークン", point.tokens))
                    .foregroundStyle(by: .value("種類", UsageFormat.kind(point.kind)))
            }
            if let selected, let at = UsageFormat.nearest(selected, in: points.map(\.at)) {
                RuleMark(x: .value("時刻", at, unit: unit))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        UsageTip(
                            title: UsageFormat.time(at),
                            lines: points.filter { $0.at == at }.map { "\(UsageFormat.kind($0.kind)) \(UsageFormat.tokens($0.tokens))" })
                    }
            }
        }
        .chartForegroundStyleScale(domain: kinds, range: UsageChartPalette.colors(kinds.count))
        .chartXScale(domain: range)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { Text(UsageFormat.tokens(value.as(Int.self) ?? 0)) }
            }
        }
        .chartXSelection(value: $selected)
        .frame(height: UsageChartMetrics.height)
    }
}

/// スキルの発火の回数。モデルが呼んだ分と、人が /コマンドで呼んだ分を積む
struct UsageSkillChart: View {
    let rows: [UsageReport.SkillRow]

    private var sources: [String] { [String(localized: "モデル"), String(localized: "/コマンド")] }

    // Swift Charts の横棒は、名前の軸のラベルを棒の上に重ねて描いた（軸の位置を leading にしても同じ）ので、名前の列と棒の列を Grid で並べる
    var body: some View {
        let colors = UsageChartPalette.colors(sources.count)
        let most = max(rows.map(\.total).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(spacing: Space.block) {
                ForEach(Array(zip(sources, colors)), id: \.0) { source, color in
                    Label { Text(verbatim: source) } icon: { Circle().fill(color).frame(width: UsageChartMetrics.legendDot, height: UsageChartMetrics.legendDot) }
                        .textRole(.caption)
                }
            }
            .accessibilityHidden(true)
            Grid(alignment: .leading, horizontalSpacing: Space.row, verticalSpacing: Space.inline) {
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(verbatim: row.name).lineLimit(1).truncationMode(.middle).textRole(.caption)
                        ShareBar(shares: [Double(row.model) / Double(most), Double(row.command) / Double(most)]) {
                            Rectangle().fill(colors[0])
                            Rectangle().fill(colors[1])
                            Text(verbatim: "\(row.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: UsageChartMetrics.barRow)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "\(row.name)、\(sources[0])\(row.model)回、\(sources[1])\(row.command)回"))
                }
            }
        }
    }
}

/// 渡された幅を割合で分けて棒を並べ、最後の子（数）を棒の後ろに置く。割合の和は 1 まで（数の分の幅を残して縮める）
private struct ShareBar: Layout {
    let shares: [Double]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? subviews.last?.sizeThatFits(.unspecified).height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.last else { return }
        let labelWidth = label.sizeThatFits(.unspecified).width + Space.inline
        let room = max(bounds.width - labelWidth, 0)
        let barHeight = bounds.height / 2
        var x = bounds.minX
        for (subview, share) in zip(subviews.dropLast(), shares) {
            let width = room * min(max(share, 0), 1)
            subview.place(at: CGPoint(x: x, y: bounds.midY - barHeight / 2), proposal: ProposedViewSize(width: width, height: barHeight))
            x += width
        }
        label.place(at: CGPoint(x: x + Space.inline, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// 圧縮の直前のコンテキスト。自動・手動・Codex（どちらか記録に無い）で分け、色と形の両方で見分ける
struct UsageCompactionChart: View {
    let points: [UsageReport.CompactionPoint]
    let range: ClosedRange<Date>

    private var triggers: [String] { [String(localized: "自動"), String(localized: "手動"), "Codex"] }

    var body: some View {
        Chart {
            ForEach(points, id: \.self) { point in
                PointMark(x: .value("時刻", point.at), y: .value("直前のコンテキスト", point.before))
                    .foregroundStyle(by: .value("圧縮", UsageFormat.trigger(point)))
                    .symbol(by: .value("圧縮", UsageFormat.trigger(point)))
                    .symbolSize(UsageChartMetrics.point)
            }
        }
        .chartForegroundStyleScale(domain: triggers, range: UsageChartPalette.colors(triggers.count))
        // 色と同じ domain を渡さないと、形の凡例が期間にある種類だけで別に並ぶ
        .chartSymbolScale(domain: triggers)
        .chartXScale(domain: range)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { Text(UsageFormat.tokens(value.as(Int.self) ?? 0)) }
            }
        }
        .frame(height: UsageChartMetrics.height)
    }
}

/// グラフに触れた所の値
private struct UsageTip: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: title).textRole(.caption)
            ForEach(lines, id: \.self) { Text(verbatim: $0).font(.caption.monospacedDigit()) }
        }
        .padding(Space.inline)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

// MARK: - 表

/// model ごとのトークン
struct UsageModelTable: View {
    let rows: [UsageReport.ModelRow]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: Space.block, verticalSpacing: Space.inline) {
            GridRow {
                Text("モデル").gridColumnAlignment(.leading)
                Text("応答")
                ForEach(UsageReport.TokenKind.allCases, id: \.self) { Text(UsageFormat.kind($0)) }
            }
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.self) { row in
                GridRow {
                    Text(verbatim: row.model.isEmpty ? row.engine.label : row.model).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "\(row.requests)")
                    ForEach(UsageReport.TokenKind.allCases, id: \.self) { Text(UsageFormat.tokens($0.value(row.tokens))) }
                }
            }
        }
        .font(.callout.monospacedDigit())
    }
}

/// トークンの多いセッション
struct UsageSessionTable: View {
    let rows: [UsageReport.SessionRow]
    let showsMachine: Bool

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: Space.block, verticalSpacing: Space.inline) {
            GridRow {
                Text("セッション").gridColumnAlignment(.leading)
                if showsMachine { Text("Mac").gridColumnAlignment(.leading) }
                Text("応答")
                Text("トークン")
                Text("最大のコンテキスト")
                Text("圧縮")
            }
            .foregroundStyle(.secondary)
            Divider()
            ForEach(rows, id: \.self) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: UsageFormat.session(row.total)).lineLimit(1).truncationMode(.tail)
                        Text(verbatim: row.total.engine.label).textRole(.caption)
                    }
                    if showsMachine { Text(verbatim: row.machine).lineLimit(1) }
                    Text(verbatim: "\(row.total.requests)")
                    Text(UsageFormat.tokens(row.total.tokens.total))
                    Text(row.total.maxContext.map(UsageFormat.tokens) ?? "")
                    Text(verbatim: "\(row.total.compactions)")
                }
            }
        }
        .font(.callout.monospacedDigit())
    }
}

// MARK: - 文字

enum UsageFormat {
    static func tokens(_ value: Int) -> String { UsageText.tokens(value) ?? "" }

    static func kind(_ kind: UsageReport.TokenKind) -> String {
        switch kind {
        case .input: String(localized: "入力")
        case .cacheWrite: String(localized: "キャッシュ書き込み")
        case .cacheRead: String(localized: "キャッシュ読み込み")
        case .output: String(localized: "出力")
        }
    }

    static func window(_ series: UsageReport.WindowSeries) -> String {
        switch series.window {
        case .claudeFiveHour: "Claude " + String(localized: "5時間")
        case .claudeSevenDay: "Claude " + String(localized: "1週間")
        case .codexPrimary, .codexSecondary: "Codex " + UsageText.windowLabel(seconds: series.windowSeconds)
        case .codexMonthly: "Codex " + String(localized: "月間")
        }
    }

    static func trigger(_ point: UsageReport.CompactionPoint) -> String {
        switch point.trigger {
        case .auto: String(localized: "自動")
        case .manual: String(localized: "手動")
        case nil: "Codex"
        }
    }

    static func compactions(_ counts: (auto: Int, manual: Int, unknown: Int)) -> String {
        var parts = [String(localized: "自動\(counts.auto)回"), String(localized: "手動\(counts.manual)回")]
        if counts.unknown > 0 { parts.append(String(localized: "Codex \(counts.unknown)回")) }
        return parts.joined(separator: "・")
    }

    /// 名前の付いたセッションは名前、無ければ作業フォルダの名前、どちらも無ければ ID の頭
    static func session(_ total: UsageHistory.SessionTotal) -> String {
        if let title = total.title, !title.isEmpty { return title }
        if let cwd = total.cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return String(total.session.prefix(8))
    }

    /// 触れた位置にいちばん近い区切り
    static func nearest(_ date: Date, in dates: [Date]) -> Date? {
        dates.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
    }

    /// 「10/6（月）09:00」（docs/ui-copy.md「表記」）
    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 「10/6（月）」
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let timeFormatter: DateFormatter = formatter("M/d（E）HH:mm")
    private static let dayFormatter: DateFormatter = formatter("M/d（E）")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = format
        return f
    }
}
