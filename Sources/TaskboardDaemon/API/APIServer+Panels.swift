import Foundation
import Hummingbird
import TaskboardKit

/// 会話が登録する概況。予算と書式の検証は Store の書き込みの入口にあり、MCP（daemon の HTTP を呼ぶ）もここを通る
extension APIServer {
    static func registerPanelRoutes(v1: RouterGroup<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder) {
        // 概況と、紐づけた部品の今の値（アプリと同じ `MachineState.resolve` を、配っている state に当てる）
        v1.get("tasks/{number}/panel") { _, context in
            let number = try context.parameters.require("number", as: Int.self)
            let store = try dependencies.requireStore()
            let panel = try mapStoreError { try store.panel(task: number) }
            var machine = MachineState()
            machine.apply(.stateSnapshot(await state.snapshot()))
            var resolved: [String: PanelResolved] = [:]
            if let panel, let task = machine.tasks[panel.id] {
                for part in panel.parts { resolved[part.id] = machine.resolve(part.spec, task: task) }
            }
            return try json(PanelReadResult(panel: panel, resolved: resolved), encoder)
        }
        v1.put("tasks/{number}/panel") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: PanelSetRequest.self, context: context)
            let requester = await dependencies.feedback?.requesterSessionID(body.requester)
            return try json(try mapStoreError { try dependencies.requireStore().setPanel(task: number, body, requesterSessionID: requester) }, encoder)
        }
        v1.post("tasks/{number}/panel/parts") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            let body = try await request.decode(as: PanelUpdateRequest.self, context: context)
            let requester = await dependencies.feedback?.requesterSessionID(body.requester)
            return try json(try mapStoreError { try dependencies.requireStore().updatePanelPart(task: number, body, requesterSessionID: requester) }, encoder)
        }
        v1.post("tasks/{number}/panel/parts/{id}/approve") { request, context in
            let number = try context.parameters.require("number", as: Int.self)
            // Hummingbird は path の引数を decode しない
            let id = try context.parameters.require("id").removingPercentEncoding ?? context.parameters.require("id")
            let body = try await request.decode(as: PanelDraftApproveRequest.self, context: context)
            let panel = try mapStoreError { try dependencies.requireStore().approvePanelDraft(task: number, partID: id, body: body.body) }
            try await dependencies.requireFeedback().notify(task: number)
            return try json(panel, encoder)
        }
    }
}
