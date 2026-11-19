import Foundation
import Synchronization

/// テストの handler の中で、別のテストの手順が進むまで止めておく
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// 進められる時計
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) { current = Mutex(start) }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// 閉包から触れる、ロック付きの値
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func update(_ body: (inout Value) -> Void) { mutex.withLock { body(&$0) } }
}

