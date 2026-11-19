import Foundation
import Hummingbird
import TaskboardKit

/// ボードとタスクと作業項目。DaemonState への反映は Store の流れ（`StatePublisher`）が持つ
extension APIServer {
    static func registerBoardRoutes(v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("boards") { _, _ in
            try json(try dependencies.requireStore().boards(), encoder)
        }
        v1.post("boards") { request, context in
            let body = try await request.decode(as: BoardCreateRequest.self, context: context)
            guard !body.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError.invalid("name が要る") }
            let board = try mapStoreError { try dependencies.requireStore().createBoard(name: body.name, columns: body.columns) }
            return try json(board, encoder)
        }
        v1.patch("boards/{id}") { request, context in
            let id = try context.parameters.require("id")
            let body = try await request.decode(as: BoardUpdateRequest.self, context: context)
            let edit = try mapStoreError { try dependencies.requireStore().editBoard(id: id, body) }
            return try json(edit.board, encoder)
        }
        v1.delete("boards/{id}") { _, context in
            let id = try context.parameters.require("id")
            try mapStoreError { try dependencies.requireStore().deleteBoard(id: id) }
            await dependencies.slack?.remove(board: id)
            return Response(status: .noContent)
        }
        v1.get("tasks") { request, _ in
            let all = try dependencies.requireStore().tasks()
            if let boardID = request.uri.queryParameters.get("board") {
                return try json(all.filter { $0.boardID == boardID }, encoder)
            }
            return try json(all, encoder)
        }
        v1.post("tasks") { request, context in
            var body = try await request.decode(as: TaskCreateRequest.self, context: context)
            if body.title.trimmingCharacters(in: .whitespaces).isEmpty { body.title = SessionGuidance.untitledTaskTitle }
            let task = try mapStoreError { try dependencies.requireStore().createTask(body) }
            return try json(task, encoder)
        }
        v1.patch("tasks/{number}") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: TaskUpdateRequest.self, context: context)
            let store = try dependencies.requireStore()
            let before = try store.task(number: number)
            let task = try mapStoreError { try store.updateTask(number: number, body) }
            // host の会話は settings.json の hook で題を付け直さない（`TASKBOARD_CONVERSATION_ID` があれば hook は何もしない）
            if before?.title != task.title { await dependencies.conversations?.taskRetitled(task) }
            return try json(task, encoder)
        }
        v1.delete("tasks/{number}") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            try mapStoreError { try dependencies.requireStore().deleteTask(number: number) }
            return Response(status: .noContent)
        }
        daemonOnly.post("import/taskherd") { request, context in
            let body = try await request.decode(as: TaskherdImportRequest.self, context: context)
            let (result, _, _) = try mapStoreError { try dependencies.requireStore().importTaskherd(body) }
            return try json(result, encoder)
        }

        // 作業項目
        v1.get("tasks/{number}/work") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            return try json(try mapStoreError { try dependencies.requireStore().workItems(task: number) }, encoder)
        }
        v1.post("tasks/{number}/work") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: WorkItemCreateRequest.self, context: context)
            guard !body.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw APIError.invalid("title が要る") }
            let item = try mapStoreError { try dependencies.requireStore().createWorkItem(task: number, body) }
            return try json(item, encoder)
        }
        v1.patch("work/{id}") { request, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let body = try await request.decode(as: WorkItemUpdateRequest.self, context: context)
            let item = try mapStoreError { try dependencies.requireStore().updateWorkItem(id: id, body) }
            return try json(item, encoder)
        }
        v1.post("work/{id}/finish") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            let number = try mapStoreError { try dependencies.requireStore().finishManualWork(id: id) }
            try await dependencies.requireFeedback().notify(task: number)
            return Response(status: .noContent)
        }
        v1.delete("work/{id}") { _, context in
            let id = try context.parameters.require("id", as: Int64.self)
            _ = try mapStoreError { try dependencies.requireStore().deleteWorkItem(id: id) }
            return Response(status: .noContent)
        }
    }
}
