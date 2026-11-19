import Foundation
import TaskboardKit

/// 再開の予定と PR・issueの監視（読むだけ。作る・取り消すのは MCP の `wake_*`・`watch_*`）
extension AppModel {
    /// タスクに届く再開の予定（タスク宛てと、タスクの会話宛て）のうち、待っているものと失敗したもの。時刻の早い順
    func wakes(forTask key: TaskKey) -> [Wake] {
        guard let state = fleet.machineState(for: key.machine) else { return [] }
        let conversations = Self.conversationIDs(ofTask: key.number, in: state)
        return state.wakes.values.filter { wake in
            guard wake.state == .pending || wake.state == .failed else { return false }
            return wake.taskNumber == key.number || wake.conversationID.map(conversations.contains) == true
        }
        .sorted { ($0.at, $0.wakeID) < ($1.at, $1.wakeID) }
    }

    /// タスクに届く PR・issueの監視（タスク宛てと、タスクの会話宛て）のうち、続いているものと、タグに入って終えたもの。作った順
    func watches(forTask key: TaskKey) -> [Watch] {
        guard let state = fleet.machineState(for: key.machine) else { return [] }
        let conversations = Self.conversationIDs(ofTask: key.number, in: state)
        return state.watches.values.filter { watch in
            guard watch.state == .active || (watch.state == .ended && watch.tag != nil) else { return false }
            return watch.taskNumber == key.number || watch.conversationID.map(conversations.contains) == true
        }
        .sorted { $0.watchID < $1.watchID }
    }

    /// 止まった・終了した会話に添える、いちばん早い待っている再開の予定。動いている会話には添えない
    func nextWake(for conversation: Conversation) -> Wake? {
        guard conversation.phase == .stopped, let state = fleet.machineState(for: conversation.machine) else { return nil }
        return state.wakes.values.filter { $0.state == .pending && $0.conversationID == conversation.id }.min { ($0.at, $0.wakeID) < ($1.at, $1.wakeID) }
    }

    /// 会話の行に添える「{時刻}に再開」（`nextWake(for:)` が無ければ nil）
    func nextWakeText(for conversation: Conversation, now: Date) -> String? {
        nextWake(for: conversation).map { String(localized: "\(ScheduleText.time($0.at, now: now))に再開") }
    }

    /// 会話の状態の名前と、あれば「{時刻}に再開」（「停止中・今日15:00に再開」）
    func statusText(of conversation: Conversation, now: Date) -> String {
        ([StatusAppearance.of(conversation).label] + [nextWakeText(for: conversation, now: now)].compactMap { $0 }).joined(separator: "・")
    }

    private static func conversationIDs(ofTask number: Int, in state: MachineState) -> Set<String> {
        Set(state.conversations.values.filter { $0.taskNumber == number }.map(\.id))
    }
}
