import SwiftUI
import TaskboardKit

/// 枠の色。statusline-command.sh と同じく 80% で注意、100% で危険。予測が出ていれば予測で判定する
enum UsageLevel {
    case ok, warn, danger

    init(now: Double, projected: Double?) {
        let value = max(now, projected ?? 0)
        self = value >= 100 ? .danger : value >= 80 ? .warn : .ok
    }

    /// 文字は注意・危険のときだけ色を付ける（余裕のある値まで緑にすると目が散る）
    var textColor: Color { self == .ok ? .primary : color }

    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .danger: .red
        }
    }
}

/// 表の 1 行（Claude 5時間 など）
struct UsageRowModel: Identifiable {
    let id: String
    let group: String
    let label: String
    let now: Double
    let projected: Double?
    let reset: String
}

/// 利用枠の文字。期間は「5時間」「1週間」（docs/ui-copy.md「用語表」）、値が無い項目は空白
enum UsageText {
    /// 会話の利用枠。Claude は会話のアカウントの枠（nil はマシンのログイン）
    static func rows(_ usage: UsageSnapshot, engine: Conversation.Engine, account: String?, now: Date) -> [UsageRowModel] {
        let group: String? = switch engine {
        case .claude: account.map { "Claude \($0)" } ?? "Claude"
        case .codex: "Codex"
        case .unknown: nil
        }
        return rows(usage, now: now).filter { $0.group == group }
    }

    static func rows(_ usage: UsageSnapshot, now: Date) -> [UsageRowModel] {
        var rows: [UsageRowModel] = []
        // id は設定（`UsageWindowChoice`）が見るので、表示の文字と切り離して固定する
        func add(_ id: String, _ group: String, _ label: String, _ window: UsageWindow?) {
            guard let window else { return }
            rows.append(
                UsageRowModel(
                    id: id, group: group, label: label, now: window.usedPercent,
                    projected: window.projectedPercent(now: now), reset: reset(window.resetsAt, longWindow: window.windowSeconds >= 86_400, now: now)))
        }
        add("Claude/5h", "Claude", String(localized: "5時間"), usage.claude?.fiveHour)
        add("Claude/1w", "Claude", String(localized: "1週間"), usage.claude?.sevenDay)
        // taskboard のアカウントの枠は表にだけ出す（見出しの棒はマシンのログインの枠）
        for account in usage.claudeAccounts ?? [] {
            let group = "Claude \(account.name)"
            add("Claude:\(account.name)/5h", group, String(localized: "5時間"), account.usage?.fiveHour)
            add("Claude:\(account.name)/1w", group, String(localized: "1週間"), account.usage?.sevenDay)
        }
        // Codex のセッションが動いていなくても、枠の値があれば出す（47 §2）
        if let codex = usage.codex {
            add("Codex/primary", "Codex", windowLabel(codex.primary), codex.primary)
            add("Codex/secondary", "Codex", windowLabel(codex.secondary), codex.secondary)
            if let monthly = codex.monthly {
                rows.append(
                    UsageRowModel(
                        id: "Codex/month", group: "Codex", label: String(localized: "月間"), now: monthly.usedPercent, projected: nil,
                        reset: reset(monthly.resetsAt, longWindow: true, now: now)))
            }
        }
        return rows
    }

    static func windowLabel(_ window: UsageWindow?) -> String {
        windowLabel(seconds: window?.windowSeconds)
    }

    static func windowLabel(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return String(localized: "利用枠") }
        if seconds % 604_800 == 0 { return String(localized: "\(seconds / 604_800)週間") }
        if seconds % 86_400 == 0 { return String(localized: "\(seconds / 86_400)日") }
        return String(localized: "\(seconds / 3600)時間")
    }

    /// 1 日より長い窓は日時で（残り時間だと「148時間30分後」になって読めない）、短い窓は残り時間で。無ければ空白
    static func reset(_ date: Date?, longWindow: Bool, now: Date) -> String {
        guard let date else { return "" }
        if longWindow { return dateFormatter.string(from: date) }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? String(localized: "\(hours)時間\(minutes)分後") : String(localized: "\(minutes)分後")
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? ""
    }

    static func tokens(_ value: Int?) -> String? {
        guard let value else { return nil }
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: value % 1_000_000 == 0 ? "%.0fM" : "%.1fM", Double(value) / 1_000_000) }
        if value >= 1000 { return "\(value / 1000)k" }
        return "\(value)"
    }

    /// 「10/6（月）09:00」（docs/ui-copy.md「表記」）
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d（E）HH:mm"
        return f
    }()

    /// 読み上げと help の 1 行（「Claude 5時間 42%、Claude 1週間 57%」）
    static func summary(_ rows: [UsageRowModel]) -> String {
        rows.map { "\($0.group) \($0.label) \(percent($0.now))" }.joined(separator: "、")
    }
}

/// マシンの見出しに並べる細いバー（Claude 5時間 / 1週間、Codex があれば 3 本目）。押すと表。押せる範囲は見た目より広い（`hitTarget`）
struct MachineUsageBars: View {
    @Environment(AppModel.self) private var model
    let state: MachineState
    var name: String?
    @State private var showDetail = false

    var body: some View {
        if let usage = state.machine.flatMap({ model.fleet.usage(for: $0.id) }) {
            LiveClock { now in
                let rows = UsageText.rows(usage, now: now)
                let windows = model.usageWindows
                let shown = rows.filter { row in windows.contains { $0.includes(row) } }
                let bars = Array((shown.filter { $0.group == "Claude" } + shown.filter { $0.group == "Codex" }.prefix(1)).prefix(3))
                let title = String(localized: "\(name ?? state.machine.map { model.machineName($0.id) } ?? "")の利用枠")
                if !bars.isEmpty {
                    Button {
                        showDetail.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            ForEach(bars) { row in
                                UsageBar(now: row.now, projected: row.projected, width: 22, height: 4)
                            }
                        }
                        .hitTarget()
                    }
                    .buttonStyle(.plain)
                    .help(UsageText.summary(bars))
                    .accessibilityLabel(title)
                    .accessibilityValue(UsageText.summary(bars))
                    .popover(isPresented: $showDetail) {
                        UsageTable(title: title, rows: rows, updatedAt: usage.claude?.at)
                            // 棒は一覧の節の見出しにあり、見出しの文字の色を引き継いで表の全体が薄くなった
                            .foregroundStyle(Color.primary)
                            .compactSheetTop()
                            .presentationCompactAdaptation(.sheet)
                            .presentationDetents([.medium])
                    }
                }
            }
        }
    }
}

struct UsageBar: View {
    let now: Double
    let projected: Double?
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        let level = UsageLevel(now: now, projected: projected)
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            if let projected {
                Capsule().fill(level.color.opacity(0.3)).frame(width: width * min(1, projected / 100))
            }
            Capsule().fill(level.color).frame(width: width * min(1, now / 100))
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

/// 「使用・予測・リセット」の表。予測は今のペースで窓の終わりまで使ったときの値。残り時間と「N分前の値」は時間の経過で進む
struct UsageTable: View {
    let title: String
    let rows: [UsageRowModel]
    let updatedAt: Date?

    var body: some View {
        LiveClock { now in
            VStack(alignment: .leading, spacing: Space.block) {
                Text(title).textRole(.sectionTitle)
                Grid(alignment: .leading, horizontalSpacing: Space.block, verticalSpacing: Space.row) {
                    GridRow {
                        Text(verbatim: "")
                        Text(verbatim: "")
                        Text("使用").gridColumnAlignment(.trailing)
                        Text("予測").gridColumnAlignment(.trailing)
                        Text("リセット")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(groups, id: \.self) { group in
                        GridRow {
                            Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridCellColumns(5)
                        }
                        ForEach(rows.filter { $0.group == group }) { row in
                            GridRow {
                                Text(row.label).font(.callout)
                                UsageBar(now: row.now, projected: row.projected, width: 90, height: 6)
                                Text(UsageText.percent(row.now)).monospacedDigit()
                                Text(UsageText.percent(row.projected)).monospacedDigit().foregroundStyle(UsageLevel(now: 0, projected: row.projected).textColor)
                                Text(row.reset).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let updatedAt, now.timeIntervalSince(updatedAt) > 600 {
                    // Claude の枠は Claude Code が動いている間だけ届く
                    Text("Claudeの利用枠は\(RelativeTime.text(updatedAt, now: now))の値です。").textRole(.caption)
                }
            }
            .padding(Space.section)
            .frame(minWidth: 340, alignment: .leading)
        }
    }

    private var groups: [String] {
        rows.map(\.group).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}

private extension View {
    /// シートで出したとき（compact の幅。popover が `presentationCompactAdaptation(.sheet)` でシートになる）は上に寄せる
    /// （中央に置くと、上に大きな空きができた）。iPad と Mac の popover は中身の大きさのまま
    func compactSheetTop() -> some View {
        modifier(CompactSheetTop())
    }
}

private struct CompactSheetTop: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        if sizeClass == .compact {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// コンテキストの使用率の閾値（statusline と同じ）。40% を超えたら目立たせ、60% 以上は警告の色
enum ContextUsage {
    static func isHigh(_ percent: Double) -> Bool { percent > 40 }

    static func color(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        return percent >= 60 ? .red : isHigh(percent) ? .orange : .secondary
    }
}

/// セッションのピルに添える context。`ContextUsage.isHigh` のときだけ出す
struct ContextBadge: View {
    let context: SessionContext?
    /// チャットの入力欄の下: 40% 以下でも出し、「コンテキスト」を付ける。ホバーでトークン数とモデル
    var labeled = false

    var body: some View {
        if let context, let pct = context.usedPercent, labeled || ContextUsage.isHigh(pct) {
            let badge = (labeled ? Text("コンテキスト\(UsageText.percent(pct))") : Text(UsageText.percent(pct)))
                .font(.caption.monospacedDigit().weight(labeled && !ContextUsage.isHigh(pct) ? .regular : .semibold))
                .foregroundStyle(ContextUsage.color(pct))
                .accessibilityLabel("コンテキスト\(UsageText.percent(pct))")
            if labeled {
                // ピルは自分の help に同じ行を持つので、ラベル付きのときだけ付ける
                badge.help(context.detailLines.joined(separator: "\n"))
            } else {
                badge
            }
        }
    }
}

extension SessionContext {
    /// ピルのホバー・長押しに出す 1 行ずつ
    var detailLines: [String] {
        var lines: [String] = []
        let model = [model, effort].compactMap { $0 }.joined(separator: "・")
        if !model.isEmpty { lines.append(model) }
        if let account { lines.append(String(localized: "アカウント：\(account)")) }
        if let usedPercent {
            let tokens = [UsageText.tokens(inputTokens), UsageText.tokens(windowSize)].compactMap { $0 }.joined(separator: " / ")
            lines.append(String(localized: "コンテキスト\(UsageText.percent(usedPercent))") + (tokens.isEmpty ? "" : "（\(tokens)）"))
        }
        return lines
    }
}
