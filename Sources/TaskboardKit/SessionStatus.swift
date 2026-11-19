import Foundation

/// 会話の状態。並びは case の順（答えが要るものが先頭）
public enum SidebarStatus: String, CaseIterable, Sendable, Comparable {
    case waiting, running, starting, unread, idle, unknown

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// 見張り盤の札と同じ判定（`ConversationTile.State.of`）を組に寄せる。問いと止まりの異常は応答待ち、問いの無い waiting は実行中。
    /// 止まった会話は待機（止まっているのは資源のためで、送れば起きる）。未読はこの端末の印で、ここでは見ない
    public static func of(_ conversation: Conversation, now: Date = Date()) -> SidebarStatus {
        SidebarStatus(ConversationTile.State.of(conversation, unread: false, now: now))
    }

    public init(_ state: ConversationTile.State?) {
        switch state {
        case .request, .problem: self = .waiting
        case .running: self = .running
        case .starting: self = .starting
        case .unread: self = .unread
        case .idle, nil: self = .idle
        }
    }
}

/// 事前起動の宛先（マシンと条件）
public struct ConversationPrewarmTarget: Hashable, Sendable {
    public var machine: MachineID
    public var request: ConversationPrewarmRequest

    public init(machine: MachineID, request: ConversationPrewarmRequest) {
        self.machine = machine
        self.request = request
    }
}

/// 起動の画面から事前起動を呼ぶかの判定。daemon は 1 本だけ持ち、新しい prewarm で前を捨て、120 秒で捨てる
public enum ConversationPrewarmSchedule {
    public struct Call: Hashable, Sendable {
        public var target: ConversationPrewarmTarget
        public var at: Date

        public init(target: ConversationPrewarmTarget, at: Date) {
            self.target = target
            self.at = at
        }
    }

    /// daemon が捨てる 120 秒より少し早く呼び直す（捨てた直後に［起動］を押すと待ちが戻るため）
    public static let refreshAfter: TimeInterval = 100

    /// 同じ条件を続けて呼ぶと、daemon は起こしかけのプロセスを捨てて起こし直すので呼ばない
    public static func shouldCall(_ target: ConversationPrewarmTarget?, last: Call?, now: Date) -> Bool {
        guard let target else { return false }
        guard let last, last.target == target else { return true }
        return now.timeIntervalSince(last.at) >= refreshAfter
    }
}
