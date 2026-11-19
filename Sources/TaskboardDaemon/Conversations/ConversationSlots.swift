import Foundation

/// 1 台で同時に動かす host の会話の枠。目安（`soft`）を超えて起こすときは使っていない会話を 1 つ止め、絶対の上限（`hard`）を超えては起こさない。
/// 起こす前に予約し（数えるのと予約を同じ lock の中で行う）、起こし終えたら予約を外す。動いている会話は会話の actor が知らせる
final class ConversationSlots: @unchecked Sendable {
    let soft: Int
    let hard: Int
    private let lock = NSLock()
    private var live: Set<String> = []
    private var reserved: Set<String> = []

    init(soft: Int, hard: Int) {
        self.soft = soft
        self.hard = hard
    }

    /// 目安は `max(6, 総メモリ / 3GiB)`（Claude Desktop と同じ式）、絶対の上限はその 2 倍
    static func standard(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> ConversationSlots {
        let soft = max(6, Int(memory / (3 << 30)))
        return ConversationSlots(soft: soft, hard: soft * 2)
    }

    /// 起こす枠を取る。絶対の上限（`withinSoft` なら目安）に達していれば false
    func reserve(_ id: String, withinSoft: Bool = false) -> Bool {
        lock.withLock {
            guard !live.contains(id), !reserved.contains(id) else {
                reserved.insert(id)
                return true
            }
            guard live.union(reserved).count < (withinSoft ? soft : hard) else { return false }
            reserved.insert(id)
            return true
        }
    }

    func release(_ id: String) {
        _ = lock.withLock { reserved.remove(id) }
    }

    func setLive(_ id: String, _ value: Bool) {
        lock.withLock {
            if value { live.insert(id) } else { live.remove(id) }
        }
    }

    /// 動いている会話と起こしている会話の数が目安を超えている
    var overSoft: Bool { lock.withLock { live.union(reserved).count > soft } }

    var count: Int { lock.withLock { live.union(reserved).count } }
}
