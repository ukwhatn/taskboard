import Foundation
import Hummingbird
import Logging
import NIOCore
import TaskboardKit

/// チャットのファイルの札を押したときの中身（`ChatMessage.files`）。transcript のその行を読み直し、セッションが見た時点の中身を返す。
/// ディスクの今のファイルは読まない（セッションが見ていないものを見せない）
extension APIServer {
    static func registerChatFileRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, logger: Logger) {
        // host の会話の札。生きている発言は transcript の位置を持たないので `at` は省ける（daemon が transcript を末尾から探す）
        v1.get("conversations/{id}/files/{tool_id}") { request, context in
            guard let service = dependencies.conversations else { throw APIError.unavailable("会話の host が無い") }
            let raw = try context.parameters.require("id")
            let id = raw.removingPercentEncoding ?? raw
            let query = try FileQuery(request, context)
            let body = try await mapConversationError {
                try await service.file(id, toolID: query.toolID, at: query.offset, path: query.path, part: query.part)
            }
            logger.debug("conversation file", metadata: ["conversation": .string(id), "tool": .string(query.toolID), "part": .string(query.part.rawValue)])
            return file(body)
        }

        v1.get("conversations/{id}/images/{line_id}/{index}") { request, context in
            guard let service = dependencies.conversations else { throw APIError.unavailable("会話の host が無い") }
            let raw = try context.parameters.require("id")
            let query = try ImageQuery(request, context)
            let body = try await mapConversationError {
                try await service.image(raw.removingPercentEncoding ?? raw, lineID: query.lineID, index: query.index, at: query.offset)
            }
            return file(body)
        }
    }

    /// 人の発言の画像の口の引数。`line_id` は発言の行の uuid（`ChatMessage.lineID`）、`index` は行の中の画像の順番、`at` は `ChatImage.offset`
    private struct ImageQuery {
        var lineID: String
        var index: Int
        var offset: UInt64?

        init(_ request: Request, _ context: TaskboardRequestContext) throws {
            lineID = try context.parameters.require("line_id")
            guard lineID.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil else { throw APIError.invalid("line_id の形が違う") }
            guard let index = context.parameters.get("index", as: Int.self), index >= 0 else { throw APIError.invalid("index は 0 以上の数") }
            self.index = index
            let query = request.uri.queryParameters
            if query.has("at") {
                guard let offset = query.get("at", as: UInt64.self) else { throw APIError.invalid("at は数") }
                self.offset = offset
            }
        }
    }

    private struct FileQuery {
        var toolID: String
        var offset: UInt64?
        var path: String?
        var part: ChatFile.Part

        init(_ request: Request, _ context: TaskboardRequestContext) throws {
            toolID = try context.parameters.require("tool_id")
            guard toolID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { throw APIError.invalid("tool_id の形が違う") }
            let query = request.uri.queryParameters
            if query.has("at") {
                guard let offset = query.get("at", as: UInt64.self) else { throw APIError.invalid("at は数") }
                self.offset = offset
            }
            guard let part = ChatFile.Part(rawValue: query.get("part").map { String($0) } ?? ChatFile.Part.content.rawValue) else {
                throw APIError.invalid("part は content か original")
            }
            self.part = part
            path = query.get("path").map { String($0) }
        }
    }

    private static func file(_ body: TranscriptFiles.Body) -> Response {
        let (data, type): (Data, String) =
            switch body {
            case .text(let text): (Data(text.utf8), "text/plain; charset=utf-8")
            case .diff(let text): (Data(text.utf8), "text/x-diff; charset=utf-8")
            case .image(let data, let type): (data, type)
            }
        return Response(status: .ok, headers: [.contentType: type], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
