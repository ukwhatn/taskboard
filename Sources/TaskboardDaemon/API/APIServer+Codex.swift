import Foundation
import Hummingbird
import TaskboardKit

/// codex のマシンの接続（アカウント・モデルの一覧・コネクタ）。利用枠は state の `usage.codex`
extension APIServer {
    static func registerCodexRoutes(v1: RouterGroup<TaskboardRequestContext>, dependencies: Dependencies, encoder: JSONEncoder) {
        v1.get("codex") { _, _ in
            try json(await dependencies.requireCodex().info(), encoder)
        }
        v1.post("codex/connectors/refresh") { _, _ in
            try json(await dependencies.requireCodex().refreshConnectors(), encoder)
        }
        // 認証のページと戻り先のアドレスは、頼んだ端末への応答と要求にだけ載せ、ログに出さない
        v1.post("codex/connectors/login") { request, context in
            let body = try await request.decode(as: CodexConnectorLoginRequest.self, context: context)
            guard !body.name.isEmpty else { throw APIError.invalid("name が空") }
            return try await loginError { try json(try await dependencies.requireCodex().startLogin(name: body.name), encoder) }
        }
        v1.post("codex/connectors/login/callback") { request, context in
            let body = try await request.decode(as: CodexConnectorCallbackRequest.self, context: context)
            return try await loginError {
                try await dependencies.requireCodex().deliverCallback(loginId: body.loginId, url: body.callbackURL)
                return Response(status: .noContent)
            }
        }
        v1.post("codex/connectors/login/cancel") { request, context in
            let body = try await request.decode(as: CodexConnectorLoginCancel.self, context: context)
            try await dependencies.requireCodex().cancelLogin(loginId: body.loginId)
            return Response(status: .noContent)
        }
        v1.post("codex/connectors/logout") { request, context in
            let body = try await request.decode(as: CodexConnectorLogoutRequest.self, context: context)
            guard !body.name.isEmpty else { throw APIError.invalid("name が空") }
            do {
                return try json(try await dependencies.requireCodex().logout(name: body.name), encoder)
            } catch let error as CodexMachine.LogoutError {
                switch error {
                case .notConnected: throw APIError.unavailable("codex に接続できていない")
                case .unknownConnector: throw APIError.invalid("その名前のコネクタが無い")
                case .codexUnavailable: throw APIError.unavailable("codex を起こせない")
                case .refused: throw APIError(.badGateway, .sessionCommandFailed, "codex が認証の解除を断った")
                case .timedOut: throw APIError(.badGateway, .sessionCommandFailed, "codex が認証の解除に時間内に答えなかった")
                }
            }
        }
    }

    private static func loginError(_ body: () async throws -> Response) async throws -> Response {
        do {
            return try await body()
        } catch let error as CodexOAuthLogins.Failure {
            switch error {
            case .notConnected: throw APIError.unavailable("codex に接続できていない")
            case .refused(let message): throw APIError(.badGateway, .sessionCommandFailed, "codex が断った: \(message)")
            case .outdated: throw APIError(.conflict, .codexOutdated, "codex の版が古く、認証の照らし合わせ（loginId）を返さない")
            case .unopenablePage: throw APIError(.badGateway, .sessionCommandFailed, "認証のページが https でも localhost の http でもない")
            case .noLogin: throw APIError.invalid("待っている認証が無い")
            case .callbackMismatch: throw APIError.invalid("認証の後に開いたページのアドレスが違う")
            case .callbackUnreachable: throw APIError(.badGateway, .sessionCommandFailed, "戻り先のアドレスを開けない")
            }
        }
    }
}
