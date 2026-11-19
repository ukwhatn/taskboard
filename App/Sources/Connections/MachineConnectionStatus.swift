import SwiftUI
import TaskboardKit

/// 接続先のマシンの接続の状態。設定の［接続先］の行、セッションの一覧、サイドバーと概観の見出しは、これで語と文を決める
enum MachineConnectionStatus: Equatable {
    /// 状態がまだ 1 度も届いていない
    case notConnected
    case connecting
    case failed(Failure)
    case connected
    /// 版の違う会話の host が、動いている会話が全部終わるのを待って入れ替わる間。その間は会話を起動できない
    case updatingHost(remaining: Int)

    enum Failure: Equatable {
        /// 端末のトークンで接続していて、接続先のMacでその端末の登録が解除された
        case unpaired
        case unauthorized
        case forbidden
        case unreachable
    }

    /// `paired`: 端末のトークンで接続している（`SavedConnection.pairedDeviceID`）
    static func of(_ state: MachineState?, paired: Bool) -> MachineConnectionStatus {
        guard let state else { return .notConnected }
        if state.connected {
            if let host = state.machine?.agentHost, host.draining { return .updatingHost(remaining: host.remaining.count) }
            return .connected
        }
        switch state.authFailure {
        case .unauthorized: return .failed(paired ? .unpaired : .unauthorized)
        case .forbidden: return .failed(.forbidden)
        default: return state.lastError == nil ? .connecting : .failed(.unreachable)
        }
    }

    /// 資格情報を直さないと繋がらない
    var needsCredentials: Bool {
        if case .failed(let failure) = self { return failure != .unreachable }
        return false
    }

    /// 見出しの横に添える短い語。何も添えなくてよいときは nil
    var shortLabel: String? {
        switch self {
        case .notConnected, .connecting, .failed: String(localized: "未接続")
        case .connected, .updatingHost: nil
        }
    }

    /// 接続先の行に出す文。失敗は事象・原因・対処で組む
    var detail: String {
        switch self {
        case .notConnected: String(localized: "未接続")
        case .connecting: String(localized: "接続しています…")
        case .connected: String(localized: "接続済み")
        case .updatingHost(let remaining):
            remaining == 0
                ? String(localized: "接続済み（更新しています）")
                : String(localized: "接続済み（更新を待っています。動いている会話\(remaining)件を終了すると、会話を起動できます）")
        case .failed(let failure): failure.error.text
        }
    }
}

extension MachineConnectionStatus.Failure {
    var error: UserFacingError {
        let event: LocalizedStringResource = "接続できません"
        switch self {
        case .unpaired:
            return UserFacingError(event, cause: String(localized: "このデバイスの登録が解除されています"), remedy: String(localized: "QRコードで追加し直してください"))
        case .unauthorized, .forbidden:
            let reason = UserFacingError.reason(self == .unauthorized ? SessionSourceError.unauthorized : .forbidden)
            return UserFacingError(event, cause: reason.cause, remedy: reason.remedy)
        case .unreachable:
            // 繋がらない理由は端末からは分からない（一度も繋がっていないこともある）ので、原因は書かない
            return UserFacingError(event, remedy: UserFacingError.checkNetwork)
        }
    }
}
