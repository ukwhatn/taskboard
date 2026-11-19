import SwiftUI
import TaskboardKit

struct ScheduleRowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let schedule: Schedule
    let expanded: Bool
    let canEdit: Bool
    let toggle: () -> Void
    let edit: () -> Void

    /// 開いたときに取り直す。取れるまでは前回の結果だけ見せる
    @State private var runs: [ScheduleRun] = []
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.row) {
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    Button(action: toggle) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: schedule.name).textRole(.title)
                                Text(verbatim: schedule.rule.summary).textRole(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(expanded ? "閉じる" : "開く")
                    Toggle(isOn: Binding(get: { schedule.enabled }, set: { model.setSchedule(schedule, enabled: $0) })) {
                        Text("「\(schedule.name)」を有効にする")
                    }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!writable)
                }
                MetaLine(items: [model.machineName(schedule.machine), choice.summary(model.claudeModels(on: schedule.machine)), ScheduleText.directory(schedule.cwd)])
                MetaLine(items: [taskText, nextText])
                if let run = schedule.lastRun {
                    ScheduleRunBadge(run: run, now: today)
                }
                if expanded { detail }
            }
        }
        .opacity(schedule.enabled ? 1 : 0.75)
        .task(id: expanded ? schedule.lastRun?.id ?? -1 : nil) {
            guard expanded else { return }
            // 取れなかったときは前に取れた履歴を残す
            if let fetched = try? await model.scheduleRuns(schedule) { runs = fetched }
        }
        .confirmationDialog("定期起動の削除", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { model.deleteSchedule(schedule) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(schedule.name)」を削除しますか？　実行の履歴も削除されます。紐づくタスクとセッションは残ります。")
        }
    }

    private var writable: Bool { model.canWrite(schedule.machine) }

    private var choice: LaunchChoice { LaunchChoice(kind: schedule.kind, args: schedule.agentArgs) }

    private var taskText: String {
        guard let number = schedule.taskNumber else { return String(localized: "タスクなし") }
        let title = model.fleet.task(for: TaskKey(machine: schedule.machine, number: number))?.title ?? ""
        return "#\(number) \(title)"
    }

    private var nextText: String {
        guard schedule.enabled else { return String(localized: "停止中") }
        guard let next = schedule.nextAt else { return String(localized: "次回の予定はありません") }
        return String(localized: "次回は\(ScheduleText.time(next, now: today))")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Divider()
            if !schedule.prompt.isEmpty {
                Text(verbatim: schedule.prompt)
                    .textRole(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.block, verticalSpacing: Space.inline) {
                GridRow {
                    Text("前回の実行が終わっていないとき").textRole(.caption)
                    Text(schedule.overlap == .skip ? "スキップ" : "並行して起動").font(.callout)
                }
                if let custom = choice.custom {
                    GridRow {
                        Text("カスタムの引数").textRole(.caption)
                        Text(verbatim: custom.joined(separator: " ")).textRole(.mono).textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("履歴").textRole(.sectionTitle)
                let shown = runs.isEmpty ? schedule.lastRun.map { [$0] } ?? [] : runs
                if shown.isEmpty {
                    Text("実行の履歴はありません").textRole(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.block, verticalSpacing: Space.inline) {
                        ForEach(shown.prefix(10)) { run in
                            GridRow {
                                Text(verbatim: ScheduleText.time(run.scheduledAt, now: today)).font(.callout).monospacedDigit()
                                ScheduleRunBadge(run: run, now: today)
                                if let id = run.conversationID, model.fleet.conversation(for: ConversationKey(machine: schedule.machine, id: id)) != nil {
                                    Button("会話を開く") { model.navigate(to: .conversation(ConversationKey(machine: schedule.machine, id: id)), from: .link) }
                                        .buttonStyle(.borderless)
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                            // 理由は help だけだと、iPhone と iPad では読めない。開いた行の履歴で回の下に出す
                            if let reason = ScheduleRunBadge.detail(run) {
                                GridRow {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(run.outcome == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .gridCellColumns(2)
                                }
                            }
                        }
                    }
                }
            }
            if let error {
                Banner(kind: .error, message: error, onClose: { self.error = nil })
            }
            HStack(spacing: Space.row) {
                Button("今すぐ実行", systemImage: "play") { runNow() }
                if canEdit {
                    Button("編集", action: edit)
                    Button("削除", role: .destructive) { confirmDelete = true }
                }
            }
            .buttonStyle(.bordered)
            .disabled(!writable)
        }
    }

    private func runNow() {
        error = nil
        Task {
            do {
                _ = try await model.runSchedule(schedule)
            } catch {
                self.error = UserFacingError("実行できませんでした", error: error)?.text
            }
        }
    }
}

/// 各回の結果（スキップ・起動済み・起動失敗・起動中・未起動）。状態は色と文字の両方で示す
struct ScheduleRunBadge: View {
    let run: ScheduleRun
    let now: Date

    var body: some View {
        let (text, color) = Self.describe(run)
        HStack(spacing: Space.inline) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).lineLimit(1)
            if run.trigger == .manual { Text("手動").foregroundStyle(.tertiary) }
        }
        .font(.callout)
        .help(Self.detail(run) ?? "")
        .accessibilityElement(children: .combine)
    }

    static func describe(_ run: ScheduleRun) -> (String, Color) {
        switch run.outcome {
        case .skipped: (String(localized: "スキップ"), .orange)
        case .launched: (String(localized: "起動済み"), .green)
        case .failed: (String(localized: "起動失敗"), .red)
        case .launching: (String(localized: "起動中"), .blue)
        case .notStarted: (String(localized: "未起動"), .secondary)
        }
    }

    /// 回の理由（開いた行の履歴と help に出す）。スキップは daemon の決まった文、起動失敗は次に取れる操作（daemon の失敗の文は内部の語を含むので出さない）
    static func detail(_ run: ScheduleRun) -> String? {
        switch run.outcome {
        case .skipped: run.skipped
        case .failed:
            if run.conversationID != nil {
                String(localized: "実行できませんでした。会話を開いて確認してください。")
            } else {
                String(localized: "起動できませんでした。作業フォルダと紐づくタスクを確認してください。")
            }
        default: nil
        }
    }
}

enum ScheduleText {
    /// 今日・明日・昨日は時刻だけ、それ以外は日付と曜日（docs/ui-copy.md「表記」: 時刻は HH:mm、日付は「10/5（日）」）
    static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let clock = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ja_JP")).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "今日\(clock)") }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "明日\(clock)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "昨日\(clock)")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M/d（E）"
        return formatter.string(from: date) + clock
    }

    /// 作業ディレクトリの表示。空はホーム
    static func directory(_ cwd: String) -> String {
        cwd.isEmpty || cwd == "~" ? String(localized: "ホーム") : cwd
    }
}
