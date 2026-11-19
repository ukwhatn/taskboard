import Foundation
import Hummingbird
import TaskboardKit

/// マシンの設定（常駐・自動停止）と定期起動と起こす予定
extension APIServer {
    static func registerScheduleRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("settings") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().settings() }, encoder)
        }
        v1.patch("settings") { request, context in
            let body = try await request.decode(as: MachineSettingsUpdate.self, context: context)
            let store = try dependencies.requireStore()
            let old = try mapStoreError { try store.settings() }
            let updated = try mapStoreError { try store.updateSettings(body) }
            await dependencies.orchestrator?.settingsChanged(from: old, to: updated)
            return try json(updated, encoder)
        }

        // 定期起動
        v1.get("schedules") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().schedules() }, encoder)
        }
        v1.post("schedules") { request, context in
            let body = try await request.decode(as: ScheduleCreateRequest.self, context: context)
            let (schedule, _) = try mapStoreError { try dependencies.requireStore().createSchedule(body) }
            return try json(schedule, encoder)
        }
        v1.patch("schedules/{id}") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: ScheduleUpdateRequest.self, context: context)
            let (schedule, _) = try mapStoreError { try dependencies.requireStore().updateSchedule(id: id, body) }
            return try json(schedule, encoder)
        }
        v1.delete("schedules/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try mapStoreError { try dependencies.requireStore().deleteSchedule(id: id) }
            return Response(status: .noContent)
        }
        v1.get("schedules/{id}/runs") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try mapStoreError { try dependencies.requireStore().scheduleRuns(id: id) }, encoder)
        }
        v1.post("schedules/{id}/run") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let scheduler = try dependencies.requireScheduler()
            return try json(try await mapStoreError { try await scheduler.runNow(id: id) }, encoder)
        }

        // 起こす予定（届けるのは `WakeService`）
        v1.get("wakes") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().wakes() }, encoder)
        }
        v1.post("wakes") { request, context in
            let body = try await request.decode(as: WakeCreateRequest.self, context: context)
            return try json(try mapStoreError { try dependencies.requireStore().createWake(body) }, encoder)
        }
        v1.post("wakes/{id}/cancel") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try mapStoreError { try dependencies.requireStore().cancelWake(id: id) }, encoder)
        }

        // GitHub の issue・PR の見張り（取るのは `GitHubSync`、届けるのは `WatchNotices`）。作ったら 1 回取って元の様子にする
        v1.get("watches") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().watches() }, encoder)
        }
        v1.post("watches") { request, context in
            let body = try await request.decode(as: WatchCreateRequest.self, context: context)
            // コマンドはこの Mac のユーザーの権限で動くので、端末の token（拾った端末）からは作らせない
            if body.command != nil {
                guard context.principal == .daemonToken else { throw AuthResponse.forbidden() }
                guard dependencies.commandWatcher != nil else { throw APIError.unavailable("コマンドの監視を動かしていない") }
            }
            let store = try dependencies.requireStore()
            // lead に届くリンクの知らせと同じものを待つ監視は作らず、PR をリンクして指示をリンクのメモに残す（同じ待ちを二重に持たせない）
            if body.coveredByLinkNotices, let number = try await leadTask(of: body, store: store, state: state, dependencies: dependencies),
                let link = try mapStoreError({ try store.linkInsteadOfWatch(body, task: number) })
            {
                return try json(WatchCreated(watch: nil, snapshot: nil, link: link), encoder)
            }
            let (created, existing) = try mapStoreError { try store.createWatch(body) }
            // 最初の取得より前に足す（リンクの元の様子も同じ取得で取る）
            var link: AutoLinkResult?
            if body.link != false, let url = created.url, Store.watchURL(url)?.kind == .githubPR,
                let number = try mapStoreError({ try store.destinationTask(of: created) })
            {
                link = try mapStoreError { try store.linkIfUnlinked(task: number, url: url) }
            }
            if !existing {
                if let url = created.url {
                    await dependencies.github?.syncWatch(url: url)
                } else if created.kind == .command {
                    await dependencies.commandWatcher?.sweep()
                } else {
                    await dependencies.github?.syncRepoWatch(id: created.watchID)
                }
            }
            let watch = try mapStoreError { try store.watch(id: created.watchID) } ?? created
            let snapshot = try mapStoreError { try store.watchSnapshot(id: created.watchID) }
            return try json(WatchCreated(watch: watch, snapshot: snapshot, existing: existing, link: link), encoder)
        }
        v1.post("watches/{id}/cancel") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            return try json(try mapStoreError { try dependencies.requireStore().cancelWatch(id: id) }, encoder)
        }
    }

    /// 監視の届け先がタスクの lead なら、そのタスク。タスク宛ては届けるときの lead に届くのでそのまま。会話宛ては、その会話が今の lead のときだけ
    /// （委譲先が自分で受ける監視は、lead に届くリンクの知らせでは代わりにならない）
    private static func leadTask(of body: WatchCreateRequest, store: Store, state: DaemonState, dependencies: Dependencies) async throws -> Int? {
        if let number = body.taskNumber { return number }
        guard let id = body.conversationID, let number = try mapStoreError({ try store.conversation(id: id) })?.taskNumber else { return nil }
        let lead: TaskDeliveryTarget? =
            if let feedback = dependencies.feedback { await feedback.lead(task: number) } else {
                await TaskDeliveryTarget.lead(task: number, state: state, conversations: nil)
            }
        return lead == .conversation(id) ? number : nil
    }
}
