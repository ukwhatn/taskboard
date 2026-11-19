import Foundation
import GRDB
import TaskboardKit

/// セッションの紐づけを外す（`taskSession` の行を消す）。結ぶほうは `Store.linkSession`
extension Store {
    /// 紐づけが無ければ 404。外した後のタスクを返す。セッションそのもの（会話・端末の Claude Code）は止めない
    public func unlinkSession(task number: Int, sessionID: String) throws -> BoardTask {
        let (task, changes) = try database.write { db -> (BoardTask, [StoreChange]) in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE number = ?", arguments: [number]) == 1 else {
                throw StoreError.taskNotFound(number)
            }
            // そのタスクの host の会話の ID は会話ごと外す（今の ID だけを外すと、/clear の前の ID の行から会話が lead に選ばれ続ける）
            if var conversation = try Self.conversationOwning(db, sessionID: sessionID), conversation.taskNumber == number {
                let tasks = try Self.bind(db, &conversation, task: nil, at: Date())
                return (try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!, (tasks + [number]).map { .task($0) } + [.conversation(conversation.id)])
            }
            try db.execute(sql: "DELETE FROM taskSession WHERE taskNumber = ? AND sessionId = ?", arguments: [number, sessionID])
            guard db.changesCount > 0 else {
                throw StoreError.refused(.notFound, ["kind": DaemonErrorCode.Kind.session.rawValue], "セッション \(sessionID) は #\(number) に紐づいていない")
            }
            try Self.touchTask(db, number: number, at: Date())
            return (try Self.fetchTasks(db, machine: machineID, numbers: [number]).first!, [.task(number)])
        }
        changed(changes)
        return task
    }
}
