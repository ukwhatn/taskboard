import Foundation
import Hummingbird
import TaskboardKit

/// 使っていない worktree の一覧と削除。端末の token でも通す（`docs/daemon.md`「認証」。iPhone のマシンの行からも使う）
extension APIServer {
    static func registerWorktreeRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        @Sendable func cleaner() throws -> WorktreeCleaner {
            guard let cleaner = dependencies.worktrees else { throw APIError.unavailable("worktree の管理が無い") }
            return cleaner
        }

        v1.get("worktrees") { _, _ in
            try json(WorktreeListResponse(worktrees: await cleaner().list()), encoder)
        }
        v1.post("worktrees/remove") { request, context in
            let body = try await request.decode(as: WorktreeRemoveRequest.self, context: context)
            return try json(WorktreeRemoveResponse(results: await cleaner().remove(paths: body.paths)), encoder)
        }
    }
}
