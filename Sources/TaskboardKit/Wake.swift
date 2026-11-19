import Foundation

public struct WakeKey: Hashable, Codable, Sendable {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }
}

/// 決めた時刻に会話を起こして文を入れる予定（MCP の `wake_create`）。届け先は会話か、タスク（その時点の lead）。
/// タスク宛てで daemon が会話を選んだか新しく起こしたら、その会話の id が `conversationID` に入る
public struct Wake: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case pending
        case delivered
        case cancelled
        case failed
    }

    public var wakeID: Int64
    public var machine: MachineID
    public var at: Date
    public var prompt: String
    public var conversationID: String?
    public var taskNumber: Int?
    /// 仕掛けた会話をターンの後に終了する（終了したら false に戻る）
    public var closesCreator: Bool
    /// 仕掛けた会話の id か pane
    public var createdBy: String?
    public var state: State
    public var deliveredAt: Date?
    /// 起こせなかった理由（`failed`）か、届けられずに試し直している理由（`pending`）
    public var failure: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var id: WakeKey { WakeKey(machine: machine, id: wakeID) }

    /// 会話に入れる文と MCP の応答の時刻（このマシンの時刻で「10/25（日）09:00」）。画面には出さない
    public static func agentTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M/d（E）HH:mm"
        return formatter.string(from: date)
    }

    public init(
        wakeID: Int64, machine: MachineID, at: Date, prompt: String, conversationID: String? = nil, taskNumber: Int? = nil, closesCreator: Bool = false,
        createdBy: String? = nil, state: State = .pending, deliveredAt: Date? = nil, failure: String? = nil, createdAt: Date, updatedAt: Date
    ) {
        self.wakeID = wakeID
        self.machine = machine
        self.at = at
        self.prompt = prompt
        self.conversationID = conversationID
        self.taskNumber = taskNumber
        self.closesCreator = closesCreator
        self.createdBy = createdBy
        self.state = state
        self.deliveredAt = deliveredAt
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// `POST /v1/wakes`。届け先は `conversationID` か `taskNumber` のどちらか 1 つ。
/// `closeConversationID` を渡すと、その会話（仕掛けた会話）を、今のターンを終えて静かになったら終了する
public struct WakeCreateRequest: Codable, Hashable, Sendable {
    public var at: Date
    public var prompt: String
    public var conversationID: String?
    public var taskNumber: Int?
    public var closeConversationID: String?
    public var createdBy: String?
    /// 仕掛けたところの作業ディレクトリ。タスク宛てで新しく起こすときの最後の候補
    public var cwd: String

    public init(
        at: Date, prompt: String, conversationID: String? = nil, taskNumber: Int? = nil, closeConversationID: String? = nil, createdBy: String? = nil,
        cwd: String = ""
    ) {
        self.at = at
        self.prompt = prompt
        self.conversationID = conversationID
        self.taskNumber = taskNumber
        self.closeConversationID = closeConversationID
        self.createdBy = createdBy
        self.cwd = cwd
    }

    /// 先にしすぎない上限。これより先は断る
    public static let horizon: TimeInterval = 366 * 24 * 3600
}
