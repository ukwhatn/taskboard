import Foundation
import TaskboardKit

/// 会話 ID の予約。同じ会話を 2 か所で動かさない（2 つの端末からの再開、会話の補助のプロセス）。
/// 会話はプロセスが終わるまで持つ。確かめと予約を 1 回の呼び出しで行い、actor の再入の間に別の起動が割り込まないよう、actor にせず lock で守る
public final class SessionReservations: @unchecked Sendable {
    private let lock = NSLock()
    /// `key` → 持ち主（会話の id か、補助のプロセスの鍵）
    private var owners: [String: String] = [:]

    public init() {}

    static func key(_ kind: AgentKind, _ agentSessionID: String) -> String { kind.rawValue + "/" + agentSessionID }

    /// 空いていれば `owner` で取って true。同じ持ち主がもう持っていても true
    func reserve(_ agentSessionID: String, owner: String) -> Bool {
        lock.withLock {
            if let current = owners[agentSessionID] { return current == owner }
            owners[agentSessionID] = owner
            return true
        }
    }

    /// `from` が持つ（か誰も持っていない）予約を `to` に移す。外してから取り直すと、その間に別の起動が入る。ほかの持ち主なら false
    func transfer(_ agentSessionID: String, from: String, to: String) -> Bool {
        lock.withLock {
            if let current = owners[agentSessionID], current != from, current != to { return false }
            owners[agentSessionID] = to
            return true
        }
    }

    func owner(of agentSessionID: String) -> String? {
        lock.withLock { owners[agentSessionID] }
    }

    /// `owner` が持つ予約を全部外す
    func release(owner: String) {
        lock.withLock { owners = owners.filter { $0.value != owner } }
    }

    /// その会話 ID の予約を、`owner` が持っていれば外す（`/clear` で会話 ID が替わったとき）
    func release(_ agentSessionID: String, owner: String) {
        lock.withLock {
            if owners[agentSessionID] == owner { owners.removeValue(forKey: agentSessionID) }
        }
    }
}
