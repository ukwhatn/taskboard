import Foundation
import TaskboardKit

/// 定期起動の操作。タスク画面の右の欄・タスクなしの画面・マシンの右クリックから使う
extension AppModel {
    /// 作る・直す・消すのは iPhone 以外（iPhone は読む・有効・今すぐ実行だけ）
    static var canEditSchedules: Bool { !isPhone }

    /// タスクを常設タスクにしている定期起動（カードの ⏱）
    func schedule(forTask key: TaskKey) -> Schedule? {
        schedules(forTask: key).first
    }

    /// タスクに結んだ定期起動（作った順）
    func schedules(forTask key: TaskKey) -> [Schedule] {
        (fleet.machineState(for: key.machine).map { Array($0.schedules.values) } ?? []).filter { $0.taskNumber == key.number }.sorted { $0.scheduleID < $1.scheduleID }
    }

    func setSchedule(_ schedule: Schedule, enabled: Bool) {
        guard let source = source(for: schedule.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateSchedule(id: schedule.scheduleID, ScheduleUpdateRequest(enabled: enabled))
            } catch {
                fail(enabled ? "定期起動を有効にできませんでした" : "定期起動を無効にできませんでした", error, in: window)
            }
        }
    }

    func deleteSchedule(_ schedule: Schedule) {
        guard let source = source(for: schedule.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.deleteSchedule(id: schedule.scheduleID)
            } catch {
                fail("定期起動を削除できませんでした", error, in: window)
            }
        }
    }

    func runSchedule(_ schedule: Schedule) async throws -> ScheduleRun {
        try await requireSource(schedule.machine).runSchedule(id: schedule.scheduleID)
    }

    func scheduleRuns(_ schedule: Schedule) async throws -> [ScheduleRun] {
        if fleet.terminalSource(for: schedule.machine) == nil { return schedule.lastRun.map { [$0] } ?? [] }
        return try await requireSource(schedule.machine).scheduleRuns(id: schedule.scheduleID)
    }

    func saveSchedule(_ draft: ScheduleDraft) async throws {
        let source = try requireSource(draft.launch.machine)
        let launch = draft.launch.request()
        let taskNumber = draft.destination == .existing ? draft.taskNumber : nil
        let newTask = draft.destination == .newTask ? ScheduleCreateRequest.NewTask(boardID: draft.boardID, columnID: draft.columnID) : nil
        if let existing = draft.existing {
            _ = try await source.updateSchedule(
                id: existing.scheduleID,
                ScheduleUpdateRequest(
                    name: draft.name, rule: draft.rule, cwd: launch.cwd, kind: launch.kind, agentArgs: launch.agentArgs, prompt: launch.prompt,
                    taskNumber: taskNumber, clearTask: draft.destination == .none, newTask: newTask, overlap: draft.overlap))
        } else {
            _ = try await source.createSchedule(
                ScheduleCreateRequest(
                    name: draft.name, rule: draft.rule, cwd: launch.cwd, kind: launch.kind, agentArgs: launch.agentArgs, prompt: launch.prompt,
                    taskNumber: taskNumber, newTask: newTask, overlap: draft.overlap))
        }
    }
}
