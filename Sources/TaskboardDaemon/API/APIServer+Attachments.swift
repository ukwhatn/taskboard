import Foundation
import Hummingbird
import Logging
import NIOCore
import TaskboardKit

/// 会話に貼った画像とファイルの置き場への保存
extension APIServer {
    /// 本文（画像のバイト列そのもの）を置き場に保存する。会話の添付が、同じ上限・種類の確かめ・失敗の応答を使う
    static func saveAttachment(_ request: Request, dependencies: Dependencies) async throws -> AttachmentUploadResponse {
        guard let store = dependencies.attachments else { throw APIError.unavailable("画像の置き場が無い") }
        let body: ByteBuffer
        do {
            // 投げたままにすると code の無い 413 になり、アプリが上限の文を組めない
            body = try await request.body.collect(upTo: ChatAttachment.maxBytes)
        } catch is NIOTooManyBytesError {
            throw tooLarge()
        }
        guard body.readableBytes > 0 else { throw APIError.invalid("本文が空") }
        do {
            return try store.save(Data(body.readableBytesView))
        } catch AttachmentStoreError.tooLarge {
            throw tooLarge()
        } catch AttachmentStoreError.unsupported {
            throw APIError(.unsupportedMediaType, .attachmentUnsupported, AttachmentStoreError.unsupported.description)
        } catch let error as AttachmentStoreError {
            throw APIError(.internalServerError, .internalError, error.description)
        }
    }

    /// 画像でないファイルを置く。中身は確かめない（agent が名前と中身で読む）
    static func saveFile(_ request: Request, name: String, dependencies: Dependencies) async throws -> AttachmentUploadResponse {
        guard let store = dependencies.attachments else { throw APIError.unavailable("添付の置き場が無い") }
        let body: ByteBuffer
        do {
            body = try await request.body.collect(upTo: ChatAttachment.maxFileBytes)
        } catch is NIOTooManyBytesError {
            throw tooLarge(limit: ChatAttachment.maxFileBytes)
        }
        guard body.readableBytes > 0 else { throw APIError.invalid("本文が空") }
        do {
            return try store.saveFile(Data(body.readableBytesView), name: name)
        } catch AttachmentStoreError.tooLarge {
            throw tooLarge(limit: ChatAttachment.maxFileBytes)
        } catch let error as AttachmentStoreError {
            throw APIError(.internalServerError, .internalError, error.description)
        }
    }

    private static func tooLarge(limit: Int = ChatAttachment.maxBytes) -> APIError {
        APIError(.contentTooLarge, .attachmentTooLarge, AttachmentStoreError.tooLarge.description, params: ["limit": String(limit / 1024 / 1024)])
    }
}
