import Foundation
import Network
import Synchronization

/// 外へ出る経路があるか（`NWPathMonitor`）。経路の変化を OS から受けるだけで、自分からは通信しない
public final class NetworkPath: Sendable {
    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    /// 最初の知らせが来るまでは繋がっているとみなす（起こさないままにしない）。`returns` は経路が無い状態から戻った回数
    private let state = Mutex((satisfied: true, returns: 0))

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.state.withLock { state in
                let satisfied = path.status == .satisfied
                if satisfied, !state.satisfied { state.returns += 1 }
                state.satisfied = satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "uk.whatn.taskboardd.network-path"))
    }

    public static func isSatisfied() -> Bool { shared.state.withLock { $0.satisfied } }

    /// 経路が切れてから戻った回数（起動してから）。前に見た値と比べて、その間に戻ったかを知る（見ていない間の短い断も拾う）
    public static func returns() -> Int { shared.state.withLock { $0.returns } }
}
