import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話とサイドバーの状態の組が、同じ状態に同じ語と記号を出す（docs/ui-copy.md の用語表）
@Suite struct StatusAppearanceTests {
    private func conversation(_ phase: Conversation.Phase, requests: [ConversationRequest] = []) -> Conversation {
        var conversation = Conversation(
            id: "c1", machine: MachineID(rawValue: "m"), taskNumber: nil, agentSessionID: "s1", cwd: "/w", runner: .host, phase: phase, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0))
        conversation.pending = requests
        return conversation
    }

    @Test("状態の組の語と記号")
    func sidebarStatuses() {
        let expected: [SidebarStatus: (String, String)] = [
            .waiting: ("応答待ち", "exclamationmark.circle.fill"),
            .running: ("実行中", "circle.fill"),
            .starting: ("起動中", "circle.dotted"),
            .unread: ("未読", "circle.fill"),
            .idle: ("待機", "circle"),
            .unknown: ("不明", "questionmark.circle"),
        ]
        for status in SidebarStatus.allCases {
            let appearance = StatusAppearance.of(status)
            #expect(appearance.label == expected[status]?.0)
            #expect(appearance.symbol == expected[status]?.1)
        }
    }

    @Test("会話: 問いがあれば応答待ち、ほかは段階の語。問いの無い waiting は答えるものが無いので実行中")
    func conversations() {
        #expect(StatusAppearance.of(conversation(.starting)).label == "起動中")
        #expect(StatusAppearance.of(conversation(.idle)).label == "待機")
        #expect(StatusAppearance.of(conversation(.running)).label == "実行中")
        #expect(StatusAppearance.of(conversation(.waiting)).label == "実行中")
        #expect(StatusAppearance.of(conversation(.stopped)).label == "待機")
        #expect(StatusAppearance.of(conversation(.stopped)).symbol == "circle")
        let asking = conversation(.running, requests: [ConversationRequest(
            id: "r1", kind: .permission, toolName: "Bash", toolUseID: nil,
            waiting: RequestWaiting(id: "r1", since: Date(timeIntervalSince1970: 0), permission: RequestWaiting.Permission(tool: "Bash", summary: "ls")))])
        #expect(StatusAppearance.of(asking).label == "応答待ち")
    }

    @Test("会話: 止まりの異常は応答待ちと同じ記号で、語は種類ごと（答える問いが無いので「応答待ち」にしない）")
    func problems() {
        let now = Date(timeIntervalSince1970: 100)
        var stalled = conversation(.running)
        stalled.stalledSince = now
        var retrying = conversation(.running)
        retrying.apiRetry = ConversationAPIRetry(attempt: 1, retryAt: now, kind: "overloaded")
        var limited = conversation(.stopped)
        limited.limitResumeAt = now
        var offline = conversation(.stopped)
        offline.networkResume = true
        var crashed = conversation(.stopped)
        crashed.lastExit = "終了コード 1"
        crashed.turnStartedAt = now
        let expected: [(Conversation, String)] = [
            (stalled, "応答なし"), (retrying, "送り直し中"), (limited, "利用枠の回復待ち"), (offline, "接続待ち"), (crashed, "異常終了"),
        ]
        for (conversation, label) in expected {
            let appearance = StatusAppearance.of(conversation, now: now)
            #expect(appearance.label == label)
            #expect(appearance.symbol == "exclamationmark.circle.fill")
        }
        // 予期しない終了は 24 時間を過ぎると札から外れ、待機に戻る
        #expect(StatusAppearance.of(crashed, now: now.addingTimeInterval(25 * 3600)).label == "待機")
    }
}
