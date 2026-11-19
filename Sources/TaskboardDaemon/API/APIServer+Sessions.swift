import Foundation
import Hummingbird
import TaskboardKit

/// オーケストレーター・会話のアカウントの切り替え・止まったセッションの再開
extension APIServer {
    static func registerSessionRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        // どの経路もオーケストレーターの今の様子（`OrchestratorInfo`）を返す
        v1.get("orchestrator") { _, _ in
            try json(await dependencies.requireKeeper().info(), encoder)
        }
        // prompt が空なら daemon が `OrchestratorInfo.startPrompt` を入れる
        v1.post("orchestrator/start") { request, context in
            let body = try await request.decode(as: LaunchRequest.self, context: context)
            return try json(try await APIServer.mapConversationError { try await dependencies.requireKeeper().start(body) }, encoder)
        }
        // 今の会話を破棄して新しく起こす。body（`OrchestratorRestartRequest`）は中身が無いので読まない
        v1.post("orchestrator/restart") { _, _ in
            try json(try await APIServer.mapConversationError { try await dependencies.requireKeeper().restart() }, encoder)
        }
        v1.post("orchestrator/prompt") { request, context in
            let body = try await request.decode(as: OrchestratorPromptRequest.self, context: context)
            return try json(try await APIServer.mapConversationError { try await dependencies.requireKeeper().prompt(body.text) }, encoder)
        }

        // Claude Code のアカウントを替える。会話は止めて、次に送ったときに起こす
        v1.post("sessions/account") { request, context in
            let body = try await request.decode(as: SessionAccountRequest.self, context: context)
            guard let id = body.conversationID else { throw APIError.invalid("conversation_id が要る") }
            guard let conversations = dependencies.conversations else { throw APIError.unavailable("会話を扱えない") }
            return try json(
                SessionResumeResult(conversation: try await APIServer.mapConversationError { try await conversations.switchAccount(id, account: body.account) }),
                encoder)
        }
        // 止まったセッションを会話で起こし直す
        v1.post("tasks/{number}/sessions/resume") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: SessionResumeRequest.self, context: context)
            guard let conversations = dependencies.conversations else { throw APIError.unavailable("会話を扱えない") }
            return try json(try await APIServer.mapConversationError { try await conversations.resume(task: number, body) }, encoder)
        }
        // 紐づいたセッションの会話の題・最後の指示・ブランチ（止まったセッションを見分ける）
        let summaries = TranscriptSummaryReader(projects: dependencies.transcripts)
        v1.get("tasks/{number}/sessions/history") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            guard let task = try dependencies.requireStore().task(number: number) else { throw APIError.notFound(.task, "タスク #\(number) が無い") }
            var seen = Set<String>()
            var histories: [SessionHistory] = []
            for ref in task.sessions where seen.insert(ref.sessionID).inserted {
                histories.append(ref.agent == "claude" ? await summaries.history(sessionID: ref.sessionID) : SessionHistory(sessionID: ref.sessionID))
            }
            return try json(histories, encoder)
        }
    }
}
