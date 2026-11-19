import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import TaskboardKit

/// 要求を送ってきた側。daemon の token（token ファイル）か、ペアリングで出した端末の token
enum Principal: Sendable, Hashable {
    case daemonToken
    case device(String)
}

/// `/v1` の要求の context。`Authenticator` が `principal` を入れ、ルートと WebSocket の handler はそれを読む（ヘッダを読み直さない）
public struct TaskboardRequestContext: RequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let webSocket: WebSocketHandlerReference<Self>
    var principal: Principal?
    /// 接続の相手の IP（ペアリングの失敗の上限を数える。`CF-Connecting-IP` が無いとき）
    let remoteAddress: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        webSocket = .init()
        remoteAddress = source.channel.remoteAddress?.ipAddress
    }
}

enum AuthResponse {
    static let headerName = HTTPField.Name(DaemonAuthHeader.name)!

    static func unauthorized() -> HTTPError {
        HTTPError(.unauthorized, headers: [headerName: DaemonAuthHeader.invalid], message: "token が違うか、止められている")
    }

    static func forbidden() -> HTTPError {
        HTTPError(.forbidden, headers: [headerName: DaemonAuthHeader.forbidden], message: "端末の token ではできない")
    }

    static func deviceOnly() -> HTTPError {
        HTTPError(.forbidden, headers: [headerName: DaemonAuthHeader.forbidden], message: "daemon の token ではできない")
    }
}

/// `Authorization: Bearer` を daemon の token と比べ、違えば端末の token として引く。どちらでもなければ 401（`X-Taskboard-Auth: invalid`）。
///
/// `upgradeUnauthenticated` の group（WebSocket だけ）では、認証に落ちた upgrade も principal 無しで通し、handler が 101 の後に 4401 で閉じる。
/// hummingbird-websocket 2.8.0 は upgrade の判定で断った要求に、ヘッダの無い 400 を固定で返すため（印の無い応答はアプリが Access の拒否と取り違える）
struct Authenticator: RouterMiddleware {
    typealias Context = TaskboardRequestContext

    let token: String
    let devices: DeviceAuth
    let store: Store?
    var upgradeUnauthenticated = false
    let logger: Logger

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        var context = context
        context.principal = await principal(request)
        if context.principal == nil {
            guard upgradeUnauthenticated, request.headers[.upgrade]?.lowercased() == "websocket" else { throw AuthResponse.unauthorized() }
        }
        return try await next(request, context)
    }

    private func principal(_ request: Request) async -> Principal? {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else { return nil }
        let presented = String(header.dropFirst("Bearer ".count))
        if Self.constantTimeEquals(presented, token) { return .daemonToken }
        // 端末の token は SHA-256 で引くので、比べるのは hash の辞書の鍵（長さとタイミングから token は辿れない）
        guard let (id, persist) = await devices.authenticate(tokenHash: DeviceAuth.hash(token: presented)) else { return nil }
        if let persist, let store {
            do {
                try store.touchDevice(id: id, at: persist)
            } catch {
                logger.warning("device lastSeenAt write failed", metadata: ["device": .string(id), "error": .string("\(error)")])
            }
        }
        return .device(id)
    }

    /// 長さが違っても同じ時間で比べる（タイミングで token の一致を探られないため）。
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            let cx = i < x.count ? x[i] : 0
            let cy = i < y.count ? y[i] : 0
            diff |= Int(cx ^ cy)
        }
        return diff == 0
    }
}

/// 端末の token では 403（`X-Taskboard-Auth: forbidden`）。端末を拾った人が、hook や CLI のふりをしたりできないため
struct DaemonTokenOnly: RouterMiddleware {
    typealias Context = TaskboardRequestContext

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard context.principal == .daemonToken else { throw AuthResponse.forbidden() }
        return try await next(request, context)
    }
}
