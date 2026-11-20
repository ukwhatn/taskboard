import Foundation
import Hummingbird
import TaskboardKit

/// 作業ディレクトリの候補・スラッシュコマンドの一覧・利用枠
extension APIServer {
    static func registerWorkdirRoutes(v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("workdirs") { _, _ in
            try json(try mapStoreError { try dependencies.requireStore().workingDirectories() }, encoder)
        }
        v1.get("workdirs/complete") { request, _ in
            let prefix = request.uri.queryParameters.get("prefix").map { String($0) } ?? ""
            return try json(WorkdirCompleter.complete(prefix, home: NSHomeDirectory()), encoder)
        }
        v1.get("commands") { request, _ in
            let cwd = request.uri.queryParameters.get("cwd").map { String($0) }
            return try json(SlashCommandCatalog.list(cwd: cwd, home: NSHomeDirectory()), encoder)
        }
        v1.post("workdirs/bookmarks") { request, context in
            let body = try await request.decode(as: WorkdirBookmarkRequest.self, context: context)
            return try json(try mapStoreError { try dependencies.requireStore().addWorkdirBookmark(path: body.path) }, encoder)
        }
        v1.delete("workdirs/bookmarks/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            try mapStoreError { try dependencies.requireStore().deleteWorkdirBookmark(id: id) }
            return Response(status: .noContent)
        }

        // 利用枠と context（`taskboard hook statusline` が送る）
        v1.get("usage") { _, _ in
            try json(await state.usageSnapshot(), encoder)
        }
        // 別のマシンで受けた同じアカウントの枠（アプリが中継する）
        v1.post("usage/claude/accounts") { request, context in
            let body = try await request.decode(as: ClaudeAccountUsageRelay.self, context: context)
            await state.adopt(body)
            return Response(status: .noContent)
        }
        // 貯めた利用状況（`UsageRecorder`）。from・to は UNIX 秒、bucket は粒度の秒
        v1.get("usage/history") { request, _ in
            let query = request.uri.queryParameters
            guard let from = query.get("from", as: Int.self), let to = query.get("to", as: Int.self), let bucket = query.get("bucket", as: Int.self),
                let validated = UsageHistoryQuery.validated(
                    from: Date(timeIntervalSince1970: TimeInterval(from)), to: Date(timeIntervalSince1970: TimeInterval(to)), bucketSeconds: bucket, now: Date())
            else { throw APIError.invalid("from・to（UNIX 秒、from < to、90 日まで）と bucket（300〜604800 秒、2,000 区切りまで）が要る") }
            return try json(try mapStoreError { try dependencies.requireStore().usageHistory(validated) }, encoder)
        }
        daemonOnly.post("usage/claude") { request, context in
            let body = try await request.decode(as: ClaudeUsageReport.self, context: context)
            await state.record(body)
            return Response(status: .noContent)
        }
    }
}
