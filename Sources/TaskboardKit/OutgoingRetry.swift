import Foundation

/// 送れなかった発言を、人が［再送信］を押す前に送り直す決まり。daemon は同じ client_message_id の 2 回目を重複として捨てるので、
/// 1 回目が実は届いていても二重には送られない
public enum OutgoingRetry {
    private static let delays: [Int] = [1, 2, 4, 8, 16, 30, 30]

    /// つながらなかった失敗か。daemon が理由を付けて断ったものは、送り直しても同じ答えなので送り直さない
    public static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case is URLError: true
        case SessionSourceError.disconnected: true
        case SessionSourceError.httpStatus(let status): status >= 500
        default: false
        }
    }

    /// `attempt` 回目（0 から）の失敗の後に待つ時間。尽きたら nil（［再送信］を出す）
    public static func delay(afterFailure attempt: Int) -> Duration? {
        delays.indices.contains(attempt) ? .seconds(delays[attempt]) : nil
    }
}
