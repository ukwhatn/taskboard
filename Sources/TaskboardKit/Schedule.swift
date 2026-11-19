import Foundation

/// 5 フィールドの cron 式（分 時 日 月 曜日）。`*`・数・`a-b`・`a,b`・`*/n`・`a-b/n` を受ける。
/// 日と曜日の両方を絞ったときはどちらかに合えば起動する（cron の慣習）。時刻はマシンのローカル時刻
public struct CronExpression: Hashable, Sendable {
    public let source: String
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    /// 0 = 日曜（7 も日曜として受ける）
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool

    public init?(_ source: String) {
        let fields = source.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5,
            let minutes = Self.field(fields[0], 0...59), let hours = Self.field(fields[1], 0...23), let days = Self.field(fields[2], 1...31),
            let months = Self.field(fields[3], 1...12), let weekdays = Self.field(fields[4], 0...7)
        else { return nil }
        self.source = fields.joined(separator: " ")
        self.minutes = minutes
        self.hours = hours
        self.days = days
        self.months = months
        self.weekdays = Set(weekdays.map { $0 == 7 ? 0 : $0 })
        dayRestricted = fields[2] != "*"
        weekdayRestricted = fields[4] != "*"
    }

    static func field(_ text: String, _ range: ClosedRange<Int>) -> Set<Int>? {
        var values = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return nil }
            var step = 1
            if pieces.count == 2 {
                guard let parsed = Int(pieces[1]), parsed > 0 else { return nil }
                step = parsed
            }
            let span: ClosedRange<Int>
            if pieces[0] == "*" {
                span = range
            } else if let dash = pieces[0].firstIndex(of: "-") {
                guard let low = Int(pieces[0][..<dash]), let high = Int(pieces[0][pieces[0].index(after: dash)...]), low <= high,
                    range.contains(low), range.contains(high)
                else { return nil }
                span = low...high
            } else {
                guard let single = Int(pieces[0]), range.contains(single) else { return nil }
                // `5/15` は 5 から終わりまで 15 おき
                span = pieces.count == 2 ? single...range.upperBound : single...single
            }
            values.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
        }
        return values.isEmpty ? nil : values
    }

    func matchesDay(_ components: DateComponents) -> Bool {
        guard let month = components.month, months.contains(month), let day = components.day, let weekday = components.weekday else { return false }
        let dayOK = days.contains(day)
        let weekdayOK = weekdays.contains(weekday - 1)
        switch (dayRestricted, weekdayRestricted) {
        case (true, true): return dayOK || weekdayOK
        case (true, false): return dayOK
        case (false, true): return weekdayOK
        case (false, false): return true
        }
    }

    /// `after` より後で最初に合う時刻（秒は 0）。4 年先まで見て無ければ nil（2/30 のような式）
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let start = calendar.date(byAdding: .minute, value: 1, to: date),
            let startMinute = calendar.dateInterval(of: .minute, for: start)?.start
        else { return nil }
        var day = calendar.startOfDay(for: startMinute)
        let sortedHours = hours.sorted(), sortedMinutes = minutes.sorted()
        for _ in 0..<(366 * 4) {
            let components = calendar.dateComponents([.month, .day, .weekday], from: day)
            if matchesDay(components) {
                for hour in sortedHours {
                    for minute in sortedMinutes {
                        // DST で存在しない時刻は calendar が前後にずらす。ずれた結果も `start` 以降なら採る
                        guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
                        if candidate >= startMinute { return candidate }
                    }
                }
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = tomorrow
        }
        return nil
    }
}

/// 繰り返し。画面の「毎日 / 平日 / 毎週」は cron 式にして持つ。間隔は cron で書けない（90 分おき等）ので別に持つ
public enum ScheduleRule: Hashable, Sendable {
    case cron(String)
    case interval(minutes: Int)

    /// `anchor`（作成・変更の時刻）から数えて、`after` より後の最初の起動時刻
    public func next(after date: Date, anchor: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .cron(let source):
            return CronExpression(source)?.next(after: date, calendar: calendar)
        case .interval(let minutes):
            guard minutes > 0 else { return nil }
            let step = Double(minutes * 60)
            let count = max(0, ((date.timeIntervalSince(anchor)) / step).rounded(.down) + 1)
            return anchor.addingTimeInterval(count * step)
        }
    }

    /// 間隔の最短（分）。daemon の断り（`intervalTooShort` の `minimum`）とアプリの欄の説明もこの値
    public static let minimumIntervalMinutes = 5

    public var isValid: Bool {
        switch self {
        case .cron(let source): CronExpression(source) != nil
        case .interval(let minutes): minutes >= Self.minimumIntervalMinutes
        }
    }

    /// 一覧に出す文（「毎日09:00」「平日09:00」「毎週月・木の10:00」「90分おき」、それ以外は「cron式「…」」）。
    /// 時刻は HH:mm、曜日は月曜から（docs/ui-copy.md「表記」）
    public var summary: String {
        switch self {
        case .interval(let minutes):
            return minutes % 60 == 0 ? String(localized: "\(minutes / 60)時間おき") : String(localized: "\(minutes)分おき")
        case .cron(let source):
            let f = source.split(whereSeparator: \.isWhitespace).map(String.init)
            let raw = String(localized: "cron式「\(f.joined(separator: " "))」")
            guard f.count == 5, let minute = Int(f[0]), let hour = Int(f[1]), (0...59).contains(minute), (0...23).contains(hour), f[2] == "*", f[3] == "*"
            else { return raw }
            let time = String(format: "%02d:%02d", hour, minute)
            if f[4] == "*" { return String(localized: "毎日\(time)") }
            if f[4] == "1-5" { return String(localized: "平日\(time)") }
            guard let days = Self.weekdays(f[4]) else { return raw }
            let names = [String(localized: "日"), String(localized: "月"), String(localized: "火"), String(localized: "水"), String(localized: "木"), String(localized: "金"), String(localized: "土")]
            return String(localized: "毎週\(days.map { names[$0] }.joined(separator: "・"))の\(time)")
        }
    }

    /// 「1,4」のような曜日の並びを、月曜から日曜の順に（0 と 7 は日曜）。範囲や step を含めば nil
    public static func weekdays(_ field: String) -> [Int]? {
        let parts = field.split(separator: ",", omittingEmptySubsequences: false)
        let days = parts.compactMap { Int($0) }
        guard !days.isEmpty, days.count == parts.count, days.allSatisfy({ (0...7).contains($0) }) else { return nil }
        let set = Set(days.map { $0 == 7 ? 0 : $0 })
        return set.sorted { ($0 == 0 ? 7 : $0) < ($1 == 0 ? 7 : $1) }
    }
}

extension ScheduleRule: Codable {
    private enum CodingKeys: String, CodingKey { case cron, intervalMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let cron = try c.decodeIfPresent(String.self, forKey: .cron) {
            self = .cron(cron)
        } else {
            self = .interval(minutes: try c.decode(Int.self, forKey: .intervalMinutes))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let source): try c.encode(source, forKey: .cron)
        case .interval(let minutes): try c.encode(minutes, forKey: .intervalMinutes)
        }
    }
}

/// 前回の実行が動いている間に次の時刻が来たとき
public enum ScheduleOverlap: String, Codable, Hashable, Sendable, CaseIterable {
    case skip
    case parallel
}

public struct ScheduleKey: Hashable, Codable, Sendable {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }
}

/// 各回。結果は daemon が回の記録と会話から埋める
public struct ScheduleRun: Codable, Hashable, Identifiable, Sendable {
    public enum Trigger: String, Codable, Hashable, Sendable {
        case schedule
        case manual
    }

    public var id: Int64
    public var scheduleID: Int64
    public var scheduledAt: Date
    public var trigger: Trigger
    public var requestID: String?
    /// 起動しなかった理由（前回が動いていた等）。起動した回は nil
    public var skipped: String?
    /// 起動の段階。起こせなかった回は `.failed`
    public var stage: LaunchStage?
    /// 起こせなかった理由
    public var error: String?
    /// host の会話で動かした回の会話の id（その回は `requestID` が無い）
    public var conversationID: String?
    public var createdAt: Date

    public init(
        id: Int64, scheduleID: Int64, scheduledAt: Date, trigger: Trigger, requestID: String? = nil, skipped: String? = nil, stage: LaunchStage? = nil,
        error: String? = nil, conversationID: String? = nil, createdAt: Date
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.scheduledAt = scheduledAt
        self.trigger = trigger
        self.requestID = requestID
        self.skipped = skipped
        self.stage = stage
        self.error = error
        self.conversationID = conversationID
        self.createdAt = createdAt
    }

    public var failed: Bool { stage == .failed }

    /// 各回の結果
    public enum Outcome: Hashable, Sendable {
        case skipped
        case launched
        case failed
        case launching
        /// 記録だけあって起動していない（daemon が止まった等）
        case notStarted
    }

    public var outcome: Outcome {
        if skipped != nil { return .skipped }
        switch stage {
        case .done: return .launched
        case .failed: return .failed
        case .none: return .notStarted
        default: return .launching
        }
    }
}

public struct Schedule: Codable, Hashable, Identifiable, Sendable {
    public var scheduleID: Int64
    public var machine: MachineID
    public var name: String
    public var enabled: Bool
    public var rule: ScheduleRule
    public var cwd: String
    public var kind: AgentKind
    public var agentArgs: [String]
    public var prompt: String
    /// 常設タスク。各回のセッションがここに紐づく。nil なら紐づけない
    public var taskNumber: Int?
    public var overlap: ScheduleOverlap
    /// 次に起こす時刻（停止中は nil）
    public var nextAt: Date?
    public var lastRun: ScheduleRun?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: ScheduleKey { ScheduleKey(machine: machine, id: scheduleID) }

    public init(
        scheduleID: Int64, machine: MachineID, name: String, enabled: Bool, rule: ScheduleRule, cwd: String, kind: AgentKind, agentArgs: [String],
        prompt: String, taskNumber: Int?, overlap: ScheduleOverlap, nextAt: Date? = nil, lastRun: ScheduleRun? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.scheduleID = scheduleID
        self.machine = machine
        self.name = name
        self.enabled = enabled
        self.rule = rule
        self.cwd = cwd
        self.kind = kind
        self.agentArgs = agentArgs
        self.prompt = prompt
        self.taskNumber = taskNumber
        self.overlap = overlap
        self.nextAt = nextAt
        self.lastRun = lastRun
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `POST /v1/schedules`。`taskNumber` も `newTask` も無ければ紐づけない
public struct ScheduleCreateRequest: Codable, Hashable, Sendable {
    public struct NewTask: Codable, Hashable, Sendable {
        public var boardID: String
        public var columnID: String

        public init(boardID: String, columnID: String) {
            self.boardID = boardID
            self.columnID = columnID
        }
    }

    public var name: String
    public var rule: ScheduleRule
    public var cwd: String
    public var kind: AgentKind
    public var agentArgs: [String]
    public var prompt: String
    public var taskNumber: Int?
    /// 常設タスクを新しく作る（題は定期起動の名前）
    public var newTask: NewTask?
    public var overlap: ScheduleOverlap
    public var enabled: Bool

    public init(
        name: String, rule: ScheduleRule, cwd: String, kind: AgentKind, agentArgs: [String] = [], prompt: String, taskNumber: Int? = nil,
        newTask: NewTask? = nil, overlap: ScheduleOverlap = .skip, enabled: Bool = true
    ) {
        self.name = name
        self.rule = rule
        self.cwd = cwd
        self.kind = kind
        self.agentArgs = agentArgs
        self.prompt = prompt
        self.taskNumber = taskNumber
        self.newTask = newTask
        self.overlap = overlap
        self.enabled = enabled
    }
}

/// `PATCH /v1/schedules/{id}`。nil の欄は変えない。紐づけを外すには `clearTask: true`
public struct ScheduleUpdateRequest: Codable, Hashable, Sendable {
    public var name: String?
    public var enabled: Bool?
    public var rule: ScheduleRule?
    public var cwd: String?
    public var kind: AgentKind?
    public var agentArgs: [String]?
    public var prompt: String?
    public var taskNumber: Int?
    public var clearTask: Bool
    /// 常設タスクを新しく作って紐づけ直す（題は定期起動の名前）。`taskNumber`・`clearTask` と同時に送らない
    public var newTask: ScheduleCreateRequest.NewTask?
    public var overlap: ScheduleOverlap?

    public init(
        name: String? = nil, enabled: Bool? = nil, rule: ScheduleRule? = nil, cwd: String? = nil, kind: AgentKind? = nil, agentArgs: [String]? = nil,
        prompt: String? = nil, taskNumber: Int? = nil, clearTask: Bool = false, newTask: ScheduleCreateRequest.NewTask? = nil, overlap: ScheduleOverlap? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.rule = rule
        self.cwd = cwd
        self.kind = kind
        self.agentArgs = agentArgs
        self.prompt = prompt
        self.taskNumber = taskNumber
        self.clearTask = clearTask
        self.newTask = newTask
        self.overlap = overlap
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        rule = try c.decodeIfPresent(ScheduleRule.self, forKey: .rule)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        kind = try c.decodeIfPresent(AgentKind.self, forKey: .kind)
        agentArgs = try c.decodeIfPresent([String].self, forKey: .agentArgs)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        taskNumber = try c.decodeIfPresent(Int.self, forKey: .taskNumber)
        clearTask = try c.decodeIfPresent(Bool.self, forKey: .clearTask) ?? false
        newTask = try c.decodeIfPresent(ScheduleCreateRequest.NewTask.self, forKey: .newTask)
        overlap = try c.decodeIfPresent(ScheduleOverlap.self, forKey: .overlap)
    }
}
