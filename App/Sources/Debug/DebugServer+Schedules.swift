#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 全マシンの定期起動（サイドバーのマシンの順、マシンの中は作った順）
    private static func allSchedules(_ model: AppModel) -> [Schedule] {
        model.orderedMachines.flatMap { $0.state.schedules.values.sorted { $0.scheduleID < $1.scheduleID } }
    }

    /// 定期起動（タスク画面の右の欄・タスクなしの画面・マシンの右クリックの操作と同じ）
    func respondSchedules(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/schedules"):
            let rows: [[String: Any]] = Self.allSchedules(model).map { schedule in
                [
                    "id": schedule.scheduleID, "machine": schedule.machine.rawValue, "name": schedule.name, "enabled": schedule.enabled,
                    "summary": schedule.rule.summary, "task": schedule.taskNumber as Any, "args": schedule.agentArgs,
                    "nextAt": schedule.nextAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                    "lastRun": schedule.lastRun.map { ScheduleRunBadge.describe($0).0 } as Any,
                ]
            }
            return .json(200, ["schedules": rows])
        case ("GET", "/schedules/runs"):
            guard let schedule = request.query["id"].flatMap(Int64.init).flatMap({ id in Self.allSchedules(model).first { $0.scheduleID == id } }) else {
                return .json(404, ["error": "定期起動が無い"])
            }
            do {
                let runs = try await model.scheduleRuns(schedule)
                return .json(200, ["runs": runs.map { ["id": $0.id, "trigger": $0.trigger.rawValue, "status": ScheduleRunBadge.describe($0).0] }])
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        case ("POST", "/schedules/form"):
            // {"id": 3} で編集、id を省くと追加のシートを出す（保存はしない）。{"close": true} で閉じる
            let body = request.jsonBody ?? [:]
            if body["close"] as? Bool == true {
                model.scheduleSheet = nil
                return .json(200, ["ok": true])
            }
            if let id = (body["id"] as? Int).map(Int64.init) {
                guard let schedule = Self.allSchedules(model).first(where: { $0.scheduleID == id }) else { return .json(404, ["error": "定期起動が無い"]) }
                model.scheduleSheet = ScheduleDraft(schedule)
            } else {
                guard let machine = model.writableMachines.first ?? model.fleet.allBoards.first?.machine else { return .json(404, ["error": "マシンが無い"]) }
                model.scheduleSheet = ScheduleDraft(machine: machine)
            }
            return .json(200, ["ok": true])
        case ("POST", "/schedules/create"):
            let body = request.jsonBody ?? [:]
            let machine = (body["machine"] as? String).map(MachineID.init(rawValue:)) ?? model.fleet.allBoards.first?.machine ?? MachineID(rawValue: "local")
            var draft = ScheduleDraft(machine: machine)
            draft.name = body["name"] as? String ?? ""
            if let minutes = body["intervalMinutes"] as? Int {
                draft.repeatKind = .interval
                draft.intervalMinutes = minutes
            } else if let cron = body["cron"] as? String {
                draft.repeatKind = .cron
                draft.cron = cron
            }
            applyLaunchFields(body, to: &draft.launch)
            if let task = body["task"] as? Int {
                draft.destination = .existing
                draft.taskNumber = task
            } else if let board = body["board"] as? String, let column = body["column"] as? String {
                draft.boardID = board
                draft.columnID = column
            } else {
                draft.destination = .none
            }
            if (body["overlap"] as? String) == "parallel" { draft.overlap = .parallel }
            if let problem = draft.validate() { return .json(400, ["error": problem]) }
            do {
                try await model.saveSchedule(draft)
                return .json(200, ["ok": true])
            } catch {
                return .json(502, ["error": "\(error)"])
            }
        case ("POST", "/schedules/run"), ("POST", "/schedules/enable"), ("POST", "/schedules/delete"):
            let body = request.jsonBody ?? [:]
            guard let id = (body["id"] as? Int).map(Int64.init), let schedule = Self.allSchedules(model).first(where: { $0.scheduleID == id }) else {
                return .json(404, ["error": "定期起動が無い"])
            }
            switch request.path {
            case "/schedules/run":
                do {
                    let run = try await model.runSchedule(schedule)
                    return .json(200, ["run": run.id, "requestID": run.requestID as Any, "status": ScheduleRunBadge.describe(run).0])
                } catch {
                    return .json(502, ["error": "\(error)"])
                }
            case "/schedules/enable":
                model.setSchedule(schedule, enabled: body["enabled"] as? Bool ?? true)
            default:
                model.deleteSchedule(schedule)
            }
            return .json(200, ["ok": true])
        default:
            return nil
        }
    }
}
#endif
