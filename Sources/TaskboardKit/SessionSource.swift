import Foundation

/// `Fleet` に足すセッション情報の供給元。本番の daemon は 1 本の接続（`StreamSource`）、fixtures とテストは全体と以後の変化（`SnapshotSource`）
public protocol SessionSource: Sendable {}

/// 全体を取ってから以後の変化を読む供給元（fixtures・テスト）
public protocol SnapshotSource: SessionSource {
    /// 現在の全体。
    func snapshot() async throws -> StateSnapshot
    /// 以後の変化。最初に `stateSnapshot` が 1 回流れることは保証しない（`snapshot()` と組み合わせて使う）。
    func events() -> AsyncThrowingStream<DaemonEvent, any Error>
}

/// `DaemonClient` と fixtures に共通の失敗。画面の文はアプリの `UserFacingError` が組む（docs/ui-copy.md「エラー」）
public enum SessionSourceError: Error, Sendable, Hashable {
    /// daemon の bearer token が違う（401）
    case unauthorized
    /// Cloudflare Access に断られた（403。service token の失効・取り消し・ポリシー外）
    case forbidden
    case httpStatus(Int)
    /// daemon が理由を付けて断った（`{"error":{"message","code","params"}}`）
    case rejected(DaemonRejection)
    case invalidResponse
    case disconnected
}

extension SessionSourceError: CustomStringConvertible {
    /// ログとエージェント向けの表記。画面には出さない
    public var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .httpStatus(let code): "httpStatus(\(code))"
        case .rejected(let rejection): rejection.message
        case .invalidResponse: "invalidResponse"
        case .disconnected: "disconnected"
        }
    }

    /// daemon の失敗の本文から理由を読む。読めなければ状態コードだけ
    public static func from(status: Int, body: Data) -> SessionSourceError {
        guard let inner = try? JSONDecoder().decode(DaemonRejection.Body.self, from: body).error, !inner.message.isEmpty else { return .httpStatus(status) }
        return .rejected(DaemonRejection(status: status, message: inner.message, code: inner.code.flatMap(DaemonErrorCode.init(rawValue:)), params: inner.params ?? [:]))
    }
}
