import SwiftUI
import TaskboardKit

/// 作成・編集の下書き
struct ScheduleDraft: Identifiable {
    enum Repeat: String, CaseIterable, Identifiable {
        case daily, weekdays, weekly, interval, cron
        var id: String { rawValue }
        var label: String {
            switch self {
            case .daily: String(localized: "毎日")
            case .weekdays: String(localized: "平日")
            case .weekly: String(localized: "毎週")
            case .interval: String(localized: "間隔")
            case .cron: String(localized: "cron式")
            }
        }
    }

    enum Destination: String, CaseIterable, Identifiable {
        case newTask, existing, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newTask: String(localized: "新しいタスク")
            case .existing: String(localized: "既存のタスク")
            case .none: String(localized: "なし")
            }
        }
    }

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes, hours
        var id: String { rawValue }
        var label: String {
            switch self {
            case .minutes: String(localized: "分")
            case .hours: String(localized: "時間")
            }
        }
        var minutes: Int { self == .hours ? 60 : 1 }
    }

    /// 曜日のボタンの並び（月曜から。0 = 日曜）
    static let weekdayOrder = [1, 2, 3, 4, 5, 6, 0]

    let id = UUID()
    let existing: Schedule?
    var name = ""
    var repeatKind: Repeat = .daily
    var hour = 9
    var minute = 0
    /// 0 = 日曜
    var weekdays: Set<Int> = [1]
    var intervalValue = 1
    var intervalUnit: IntervalUnit = .hours
    var cron = "0 9 * * *"
    var launch: LaunchDraft
    var destination: Destination = .newTask
    var boardID = ""
    var columnID = ""
    var taskNumber: Int?
    var overlap: ScheduleOverlap = .skip

    init(machine: MachineID) {
        existing = nil
        launch = LaunchDraft(machine: machine)
    }

    init(_ schedule: Schedule) {
        existing = schedule
        name = schedule.name
        launch = LaunchDraft(machine: schedule.machine, cwd: schedule.cwd, prompt: schedule.prompt)
        launch.select(kind: schedule.kind, args: schedule.agentArgs)
        launch.promptEdited = true
        overlap = schedule.overlap
        destination = schedule.taskNumber == nil ? .none : .existing
        taskNumber = schedule.taskNumber
        switch schedule.rule {
        case .interval(let minutes):
            repeatKind = .interval
            intervalMinutes = minutes
        case .cron(let source):
            cron = source
            let f = source.split(whereSeparator: \.isWhitespace).map(String.init)
            if f.count == 5, let m = Int(f[0]), let h = Int(f[1]), (0...59).contains(m), (0...23).contains(h), f[2] == "*", f[3] == "*" {
                hour = h
                minute = m
                if f[4] == "*" {
                    repeatKind = .daily
                } else if f[4] == "1-5" {
                    repeatKind = .weekdays
                } else if let days = ScheduleRule.weekdays(f[4]) {
                    repeatKind = .weekly
                    weekdays = Set(days)
                } else {
                    repeatKind = .cron
                }
            } else {
                repeatKind = .cron
            }
        }
    }

    /// 間隔（分）。60 で割り切れれば時間で持つ
    var intervalMinutes: Int {
        get { intervalValue * intervalUnit.minutes }
        set {
            if newValue >= 60, newValue % 60 == 0 {
                intervalUnit = .hours
                intervalValue = newValue / 60
            } else {
                intervalUnit = .minutes
                intervalValue = newValue
            }
        }
    }

    var rule: ScheduleRule {
        switch repeatKind {
        case .daily: .cron("\(minute) \(hour) * * *")
        case .weekdays: .cron("\(minute) \(hour) * * 1-5")
        case .weekly: .cron("\(minute) \(hour) * * \(Self.weekdayOrder.filter(weekdays.contains).map(String.init).joined(separator: ","))")
        case .interval: .interval(minutes: intervalMinutes)
        case .cron: .cron(cron.trimmingCharacters(in: .whitespaces))
        }
    }

    /// 入力の誤り（docs/ui-copy.md「エラー」）。無ければ nil
    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "名前を入力してください。") }
        if repeatKind == .weekly && weekdays.isEmpty { return String(localized: "曜日を1つ以上選んでください。") }
        if !rule.isValid {
            return repeatKind == .interval
                ? String(localized: "間隔は\(ScheduleRule.minimumIntervalMinutes)分以上にしてください。")
                : String(localized: "cron式を読み取れません。「分 時 日 月 曜日」の5つを半角の空白で区切って入力してください。")
        }
        if destination == .newTask && (boardID.isEmpty || columnID.isEmpty) { return String(localized: "タスクを追加する案件と列を選んでください。") }
        if destination == .existing && taskNumber == nil { return String(localized: "紐づけるタスクを選んでください。") }
        return nil
    }
}
