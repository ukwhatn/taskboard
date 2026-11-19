import Foundation

/// ターンの完了の通知を出す時機（端末ごとの設定。`PushRegistration.turns`）
public enum TurnNotify: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case never
    /// アプリが前面にない間だけ。前面なら端末が抑える（iPhone・iPad の APNs も、届いた端末で抑える）
    case background
    case always

    public var id: String { rawValue }

    /// 知らない値（新しい版が足したもの）は「アプリを使っていないときだけ」と読む（登録ごと読めなくしない）
    public init(from decoder: any Decoder) throws {
        self = TurnNotify(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .background
    }

    public var label: String {
        switch self {
        case .never: String(localized: "出さない")
        case .background: String(localized: "アプリを使っていないときだけ")
        case .always: String(localized: "常に")
        }
    }
}

/// 応答中のセッションと会話を控え、応答を終えて入力を待ったものを返す（daemon の APNs とアプリのローカル通知で同じものを使う）。
/// 数えるのは host の会話（running から idle へ）。
/// オーケストレーター・定期起動の会話と、委譲先（親のある会話）は数えない（人が待っている応答ではない）
public struct TurnWatch: Sendable {
    /// 応答中のもの（`TurnFinished.key`）
    public private(set) var working: Set<String> = []

    public init() {}

    /// 今の応答中を控える（返さない）。起動したときと、基準を取り直すとき
    public mutating func reset(_ state: MachineState) {
        working = Set(Self.entries(state).filter(\.working).map(\.turn.key))
    }

    /// 前に応答中で、今は入力を待っているもの。控えを今の応答中に置き換える
    public mutating func update(_ state: MachineState) -> [TurnFinished] {
        let entries = Self.entries(state)
        let finished = entries.filter { $0.awaitsInput && working.contains($0.turn.key) }.map(\.turn)
        working = Set(entries.filter(\.working).map(\.turn.key))
        return finished
    }

    private struct Entry {
        var turn: TurnFinished
        var working: Bool
        var awaitsInput: Bool
    }

    private static func entries(_ state: MachineState) -> [Entry] {
        guard let machine = state.machine?.id else { return [] }
        var result: [Entry] = []
        for conversation in state.conversations.values
        where conversation.purpose == nil && conversation.parentConversationID == nil {
            let name = conversation.engine.agentKind?.label ?? AgentKind.claude.label
            let turn = TurnFinished(
                key: "turn/conversation/\(conversation.id)",
                title: conversation.customTitle ?? conversation.title ?? String(localized: "\(name)が応答を終えました"), machine: machine,
                taskNumber: conversation.taskNumber, link: .conversation(conversation.key))
            result.append(Entry(turn: turn, working: conversation.phase == .running, awaitsInput: conversation.phase == .idle))
        }
        return result
    }
}

/// 応答を終えたセッションか会話（`TurnWatch.update`）
public struct TurnFinished: Hashable, Sendable {
    public var key: String
    public var title: String
    public var machine: MachineID
    public var taskNumber: Int?
    var link: TaskboardLink

    /// 通知の中身。補足は接続先に付けた名前とタスクの番号。押すとそのセッション・会話を開く
    public func notification(machineName: String) -> InboxNotification {
        let taskKey = taskNumber.map { TaskKey(machine: machine, number: $0) }
        return InboxNotification(
            title: String(localized: "応答の完了"),
            subtitle: [machineName.isEmpty ? nil : machineName, taskKey.map { "#\($0.number)" }].compactMap { $0 }.joined(separator: "・"),
            body: title, itemID: key, url: link.url, threadID: taskKey?.description ?? machine.rawValue, collapseKey: key, turn: true)
    }
}
