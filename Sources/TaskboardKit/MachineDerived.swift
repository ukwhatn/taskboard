import Foundation

/// `MachineState` から数えたものの控え（タスクごとの作業項目と会話、置き場ごとのセッションと会話、受信箱）。
/// 画面はカード・行の 1 つごとに引くので、毎回全部をなめると、タスクと会話の多いマシン（Studio のタスク 584 件）で主スレッドが止まった。
/// `MachineState` の欄が変わると作り直す（各欄の `didSet`）。写した `MachineState` どうしは同じ控えを分け合う。`==` と hash には入れない
struct MachineDerived: Hashable, @unchecked Sendable {
    private let box = Box()

    static func == (lhs: MachineDerived, rhs: MachineDerived) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    /// 値が無ければ `make` で作って覚える。`make` は鍵の外で呼ぶ（中で別の控えを引いてよい）
    func value<Value>(_ key: Key, _ make: () -> Value) -> Value {
        if let value = box.lock.withLock({ box.values[key] }) as? Value { return value }
        let value = make()
        box.lock.withLock { box.values[key] = value }
        return value
    }

    /// 受信箱。`now` が前に数えた時刻から、中身が時刻で変わる時刻（`Inbox.validUntil`）の前までなら、前に数えたものを返す
    func inbox(window: TimeInterval, now: Date, _ make: () -> Inbox) -> Inbox {
        if let cached = box.lock.withLock({ box.inbox[window] }), cached.isValid(at: now) { return cached }
        let inbox = make()
        box.lock.withLock { box.inbox[window] = inbox }
        return inbox
    }

    /// 同じ中身から数えた控えか（写した `MachineState` どうしは同じ控えを分け合い、欄が変わると別の控えになる）
    func isSame(as other: MachineDerived) -> Bool { box === other.box }

    enum Key: Hashable {
        case workByTask
        case conversationsByTask
        case membersByHome
        case memberRows(SessionHome)
        case runningAgentSessionIDs
    }

    struct Inbox {
        var items: [InboxItem]
        var computedAt: Date
        var validUntil: Date

        func isValid(at now: Date) -> Bool { computedAt <= now && now < validUntil }
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var values: [Key: Any] = [:]
        var inbox: [TimeInterval: Inbox] = [:]
    }
}
