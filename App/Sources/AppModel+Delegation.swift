import Foundation
import TaskboardKit

/// 委任範囲のタスクの上書き。案件の初期値は案件の設定の保存（`updateBoard`）で送る
extension AppModel {
    /// タスクの上書きを丸ごと送る。空なら全部を案件の設定に戻す
    func saveDelegation(_ scope: DelegationScope, of task: BoardTask) async throws {
        _ = try await requireSource(task.machine).updateTask(number: task.number, TaskUpdateRequest(delegation: scope))
    }
}
