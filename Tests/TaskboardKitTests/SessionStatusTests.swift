import Foundation
import Testing
@testable import TaskboardKit

@Suite struct SidebarStatusTests {
    @Test("会話の状態をサイドバーの組に揃える")
    func statuses() {
        let machine = MachineID(rawValue: "m")
        func conversation(_ phase: Conversation.Phase) -> Conversation {
            Conversation(
                id: "c", machine: machine, taskNumber: nil, agentSessionID: "s", cwd: "/", runner: .host, phase: phase, createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0))
        }
        // 問いの無い waiting は答えるものが無いので実行中（見張り盤の札と同じ判定）
        #expect(SidebarStatus.of(conversation(.waiting)) == .running)
        #expect(SidebarStatus.of(conversation(.running)) == .running)
        #expect(SidebarStatus.of(conversation(.starting)) == .starting)
        #expect(SidebarStatus.of(conversation(.idle)) == .idle)
        // 止まった会話は待機。止まっているのは資源のためで、送れば起きる
        #expect(SidebarStatus.of(conversation(.stopped)) == .idle)
        #expect(SidebarStatus.allCases.map(\.rawValue).contains("stopped") == false)
        // 組の並びは応答待ちが先頭
        #expect(SidebarStatus.allCases.first == .waiting)
    }
}

@Suite struct ConversationPrewarmScheduleTests {
    private let mac = MachineID(rawValue: "mac")
    private let studio = MachineID(rawValue: "studio")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func target(_ machine: MachineID, cwd: String = "~/dev/認証", model: String? = "claude-opus-5-5[1m]", effort: String? = "medium")
        -> ConversationPrewarmTarget
    {
        ConversationPrewarmTarget(machine: machine, request: ConversationPrewarmRequest(cwd: cwd, model: model, effort: effort))
    }

    @Test("会話を選んでいないときは呼ばない")
    func noTarget() {
        #expect(!ConversationPrewarmSchedule.shouldCall(nil, last: nil, now: now))
    }

    @Test("初めてなら呼ぶ。同じ条件をすぐ後にもう一度は呼ばない")
    func sameSoon() {
        let first = target(mac)
        #expect(ConversationPrewarmSchedule.shouldCall(first, last: nil, now: now))
        #expect(!ConversationPrewarmSchedule.shouldCall(first, last: .init(target: first, at: now), now: now.addingTimeInterval(30)))
    }

    @Test("cwd・モデル・effort・マシンのどれかが変われば呼び直す")
    func changed() {
        let last = ConversationPrewarmSchedule.Call(target: target(mac), at: now)
        let later = now.addingTimeInterval(1)
        #expect(ConversationPrewarmSchedule.shouldCall(target(mac, cwd: "~/dev/taskboard"), last: last, now: later))
        #expect(ConversationPrewarmSchedule.shouldCall(target(mac, model: nil), last: last, now: later))
        #expect(ConversationPrewarmSchedule.shouldCall(target(mac, effort: "high"), last: last, now: later))
        #expect(ConversationPrewarmSchedule.shouldCall(target(studio), last: last, now: later))
    }

    @Test("daemon が捨てる 120 秒の少し前を過ぎたら、同じ条件でも呼び直す")
    func expired() {
        let first = target(mac)
        let last = ConversationPrewarmSchedule.Call(target: first, at: now)
        #expect(!ConversationPrewarmSchedule.shouldCall(first, last: last, now: now.addingTimeInterval(99)))
        #expect(ConversationPrewarmSchedule.shouldCall(first, last: last, now: now.addingTimeInterval(100)))
    }
}
