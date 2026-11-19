import Foundation
import Hummingbird
import TaskboardKit

/// route が使う依存の取り出しと、エラーの API の応答への読み替え（どの `registerXRoutes` も同じものを使う）
extension APIServer.Dependencies {
    func requireStore() throws -> Store {
        guard let store else { throw APIError.unavailable("store が無い") }
        return store
    }

    func requireKeeper() throws -> OrchestratorKeeper {
        guard let orchestrator else { throw APIError.unavailable("オーケストレーターの見張りが無い") }
        return orchestrator
    }

    func requireScheduler() throws -> Scheduler {
        guard let scheduler else { throw APIError.unavailable("スケジューラが無い") }
        return scheduler
    }

    func requireCodex() throws -> CodexMachine {
        guard let codex else { throw APIError.unavailable("codex のマシンの接続が無い") }
        return codex
    }

    func requirePRs() throws -> PullRequestSync {
        guard let prs else { throw APIError.unavailable("PR の取得が無い") }
        return prs
    }

    func requireFeedback() throws -> FeedbackService {
        guard let feedback else { throw APIError.unavailable("feedback service が無い") }
        return feedback
    }

    func requireHooks() throws -> HookService {
        guard let hooks else { throw APIError.unavailable("hook service が無い") }
        return hooks
    }
}

extension APIServer {
    static func mapStoreError<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as StoreError {
            throw error.apiError
        }
    }

    static func mapStoreError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as StoreError {
            throw error.apiError
        }
    }
}
