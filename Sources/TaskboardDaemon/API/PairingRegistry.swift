import Foundation
import TaskboardKit

/// ペアリングコードの発行と出し入れ。コードはメモリにだけ持ち、daemon を再起動したら消える。
///
/// 1 本のコードは「未使用 → 予約 → 消費」と進み、予約した要求だけが表に書く。書けなければ `release` で未使用に戻す
/// （同じコードの要求が同時に 2 本来ても、端末は 1 台しかできない）
actor PairingRegistry {
    typealias Clock = @Sendable () -> Date

    static let lifetime: TimeInterval = 5 * 60
    static let maxActive = 5
    static let failureWindow: TimeInterval = 5 * 60
    static let failureLimit = 10
    static let blockDuration: TimeInterval = 5 * 60

    enum Reservation: Equatable {
        case reserved
        /// コードが違う・期限切れ・予約中・使用済み
        case invalid
    }

    private struct Entry {
        let code: String
        let expiresAt: Date
        var reserved: Bool
    }

    private let now: Clock
    /// 発行した順
    private var entries: [Entry] = []
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    init(now: @escaping Clock = { Date() }) {
        self.now = now
    }

    /// 有効なコードが 5 本あれば古いものから捨てる
    func issue() -> PairingCode {
        let date = now()
        prune(date)
        while entries.count >= Self.maxActive { entries.removeFirst() }
        var code = Self.randomCode()
        while entries.contains(where: { $0.code == code }) { code = Self.randomCode() }
        let entry = Entry(code: code, expiresAt: date.addingTimeInterval(Self.lifetime), reserved: false)
        entries.append(entry)
        return PairingCode(code: code, expiresAt: entry.expiresAt)
    }

    /// 接続元が止められていれば、解けるまでの秒数（切り上げ）
    func retryAfter(source: String) -> Int? {
        let date = now()
        guard let until = blockedUntil[source] else { return nil }
        guard until > date else {
            blockedUntil.removeValue(forKey: source)
            failures.removeValue(forKey: source)
            return nil
        }
        return Int(until.timeIntervalSince(date).rounded(.up))
    }

    /// `code` は `PairingCode.normalize` を通した後の値
    func reserve(_ code: String) -> Reservation {
        let date = now()
        prune(date)
        guard let index = entries.firstIndex(where: { $0.code == code }), !entries[index].reserved else { return .invalid }
        entries[index].reserved = true
        return .reserved
    }

    func consume(_ code: String) {
        entries.removeAll { $0.code == code }
    }

    /// 表に書けなかった。期限内なら未使用に戻す（期限切れは次の `prune` で消える）
    func release(_ code: String) {
        guard let index = entries.firstIndex(where: { $0.code == code }) else { return }
        entries[index].reserved = false
    }

    /// 失敗を数える。この失敗で上限に達したら true（以後 `blockDuration` の間 `retryAfter` が値を返す）。
    /// 有効なコードは捨てない（止めた端末が誤ったコードを送り続けても、新しい端末の登録を邪魔できないため）
    @discardableResult
    func recordFailure(source: String) -> Bool {
        let date = now()
        var recent = (failures[source] ?? []).filter { date.timeIntervalSince($0) < Self.failureWindow }
        recent.append(date)
        failures[source] = recent
        guard recent.count >= Self.failureLimit else { return false }
        blockedUntil[source] = date.addingTimeInterval(Self.blockDuration)
        return true
    }

    private func prune(_ date: Date) {
        entries.removeAll { $0.expiresAt <= date && !$0.reserved }
    }

    /// Crockford base32 の 8 文字（40 bit）。`SystemRandomNumberGenerator` は Darwin では arc4random（CSPRNG）
    static func randomCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bits = UInt64.random(in: 0..<(1 << 40))
        var characters: [Character] = []
        for _ in 0..<8 {
            characters.append(alphabet[Int(bits & 31)])
            bits >>= 5
        }
        return String(characters)
    }
}
