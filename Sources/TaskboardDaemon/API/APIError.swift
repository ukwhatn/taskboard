import Foundation
import HTTPTypes
import Hummingbird
import TaskboardKit

/// 断る応答。`{"error":{"message","code","params"}}` を返す。`message` はエージェントとログのための文で、
/// アプリは `code` と `params` から画面の文を組む（docs/ui-copy.md「エラー」）
struct APIError: HTTPResponseError, CustomStringConvertible {
    var status: HTTPResponse.Status
    var message: String
    var code: DaemonErrorCode
    var params: [String: String] = [:]
    var headers: HTTPFields = [:]

    init(_ status: HTTPResponse.Status, _ code: DaemonErrorCode, _ message: String, params: [String: String] = [:], headers: HTTPFields = [:]) {
        self.status = status
        self.code = code
        self.message = message
        self.params = params
        self.headers = headers
    }

    static func notFound(_ kind: DaemonErrorCode.Kind, _ message: String) -> APIError {
        APIError(.notFound, .notFound, message, params: ["kind": kind.rawValue])
    }

    static func unavailable(_ message: String) -> APIError { APIError(.serviceUnavailable, .unavailable, message) }

    static func invalid(_ message: String) -> APIError { APIError(.badRequest, .invalidRequest, message) }

    var description: String { "APIError(\(status.code) \(code.rawValue)): \(message)" }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        var response = try context.responseEncoder.encode(DaemonRejection.Body(message: message, code: code, params: params), from: request, context: context)
        response.status = status
        response.headers.append(contentsOf: headers)
        return response
    }
}

extension StoreError {
    var apiError: APIError {
        switch self {
        case .boardNotFound: .notFound(.board, description)
        case .columnNotFound: .notFound(.column, description)
        case .taskNotFound: .notFound(.task, description)
        case .workItemNotFound: .notFound(.workItem, description)
        case .docNotFound: .notFound(.document, description)
        case .askNotFound: .notFound(.ask, description)
        case .commentNotFound: .notFound(.comment, description)
        case .revisionNotFound: .notFound(.revision, description)
        case .scheduleNotFound: .notFound(.schedule, description)
        case .wakeNotFound: .notFound(.wake, description)
        case .watchNotFound: .notFound(.watch, description)
        case .docFormatMismatch(let name, _): APIError(.conflict, .docFormatMismatch, description, params: ["name": name])
        case .askNotOpen: APIError(.conflict, .askNotOpen, description)
        case .askUnanswered(let ids): APIError(.badRequest, .askUnanswered, description, params: ["count": String(ids.count)])
        case .commentNotDraft: APIError(.conflict, .commentNotDraft, description)
        case .boardArchived(let name): APIError(.conflict, .boardArchived, description, params: ["name": name])
        case .refused(let code, let params, _): APIError(code.status, code, description, params: params)
        case .invalid: .invalid(description)
        case .conflict: APIError(.conflict, .invalidRequest, description)
        case .integrityCheckFailed, .missingTable: APIError(.internalServerError, .internalError, description)
        }
    }
}

extension DaemonErrorCode {
    /// `StoreError.refused` で返す状態コード
    var status: HTTPResponse.Status {
        switch self {
        case .notFound: .notFound
        case .boardLast, .boardHasTasks, .columnHasTasks, .askNotOpen, .commentNotDraft, .boardArchived, .docFormatMismatch, .scheduleRunExists,
            .orchestratorRunning, .orchestratorMissing, .orchestratorStarting, .orchestratorResident, .sessionRunning,
            .notWaiting, .questionPending:
            .conflict
        case .attachmentMissing: .notFound
        case .attachmentTooLarge: .contentTooLarge
        case .attachmentUnsupported: .unsupportedMediaType
        case .deviceNotAllowed: .forbidden
        case .pairingTooManyFailures: .tooManyRequests
        case .sessionCommandFailed, .githubFailed: .badGateway
        case .unavailable: .serviceUnavailable
        case .internalError: .internalServerError
        default: .badRequest
        }
    }
}
