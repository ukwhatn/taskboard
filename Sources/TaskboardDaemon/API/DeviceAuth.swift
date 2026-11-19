import CryptoKit
import Foundation

/// 端末の token の認証のキャッシュ（`[SHA-256: 端末 id]`）と、端末が開いている WebSocket の登録。
///
/// 2 つを同じ actor に置くのは、`revoke` がキャッシュから外すのと登録済みの接続に閉じろと伝えるのを続けて行い、
/// その後に `register` が通る接続を作らないため（upgrade の判定の後に止められた接続は `register` が nil を返す）
actor DeviceAuth {
    typealias Clock = @Sendable () -> Date

    /// `lastSeenAt` を表に書く間隔（端末ごと）
    static let lastSeenWriteInterval: TimeInterval = 60

    struct Registration: Sendable {
        let id: UUID
        /// 止められたら 1 回届いて終わる。handler が終わって外したときは何も届かずに終わる
        let revoked: AsyncStream<Void>
    }

    private let now: Clock
    private var deviceByHash: [String: String] = [:]
    private var lastSeen: [String: Date] = [:]
    private var lastWritten: [String: Date] = [:]
    private var sockets: [String: [UUID: AsyncStream<Void>.Continuation]] = [:]

    init(now: @escaping Clock = { Date() }) {
        self.now = now
    }

    static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(_ records: [Store.DeviceRecord]) {
        deviceByHash = Dictionary(records.map { ($0.tokenHash, $0.info.id) }, uniquingKeysWith: { first, _ in first })
    }

    func add(deviceID: String, tokenHash: String) {
        deviceByHash[tokenHash] = deviceID
    }

    /// 認証が通れば端末 id と、表に書くべき `lastSeenAt`（前に書いてから 60 秒経っていなければ nil）
    func authenticate(tokenHash: String) -> (deviceID: String, persistLastSeen: Date?)? {
        guard let id = deviceByHash[tokenHash] else { return nil }
        let date = now()
        lastSeen[id] = date
        if let written = lastWritten[id], date.timeIntervalSince(written) < Self.lastSeenWriteInterval {
            return (id, nil)
        }
        lastWritten[id] = date
        return (id, date)
    }

    /// 表に書いていない分も含めた最後の接続
    func lastSeen(deviceID: String) -> Date? { lastSeen[deviceID] }

    /// 止められていれば nil（handler はその場で 4401 で閉じる）
    func register(deviceID: String) -> Registration? {
        guard deviceByHash.values.contains(deviceID) else { return nil }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        sockets[deviceID, default: [:]][id] = continuation
        return Registration(id: id, revoked: stream)
    }

    func unregister(deviceID: String, id: UUID) {
        sockets[deviceID]?.removeValue(forKey: id)?.finish()
        if sockets[deviceID]?.isEmpty == true { sockets.removeValue(forKey: deviceID) }
    }

    /// キャッシュから外し、登録済みの接続に閉じろと伝える。伝えた接続の数を返す
    @discardableResult
    func revoke(deviceID: String) -> Int {
        deviceByHash = deviceByHash.filter { $0.value != deviceID }
        lastSeen.removeValue(forKey: deviceID)
        lastWritten.removeValue(forKey: deviceID)
        let registered = sockets.removeValue(forKey: deviceID) ?? [:]
        for continuation in registered.values {
            continuation.yield()
            continuation.finish()
        }
        return registered.count
    }
}
