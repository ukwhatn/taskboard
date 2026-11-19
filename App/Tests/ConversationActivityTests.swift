import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@Suite("会話の末尾の、engine が今していることの行")
struct ConversationActivityTests {
    @Test("圧縮の経過は 1 分まで秒、それより長ければ分と秒。始まりより前の時計は 0 秒")
    func elapsed() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(ConversationActivityRow.elapsed(from: start, to: start) == "0秒")
        #expect(ConversationActivityRow.elapsed(from: start, to: start.addingTimeInterval(59.9)) == "59秒")
        #expect(ConversationActivityRow.elapsed(from: start, to: start.addingTimeInterval(60)) == "1分0秒")
        #expect(ConversationActivityRow.elapsed(from: start, to: start.addingTimeInterval(3_725)) == "62分5秒")
        #expect(ConversationActivityRow.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0秒")
    }

    @Test("会話が圧縮中か、応答が止まったときだけ行を出す。両方なら止まり")
    func activity() {
        var conversation = Conversation(
            id: "c1", machine: MachineID(rawValue: "m"), taskNumber: nil, agentSessionID: "s", cwd: "/w", runner: .host, phase: .running,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        #expect(ConversationActivity(conversation) == nil && ConversationActivity(nil) == nil)
        let compaction = ConversationCompaction(startedAt: Date(timeIntervalSince1970: 10), outputChars: 120)
        conversation.compaction = compaction
        #expect(ConversationActivity(conversation) == .compacting(compaction))
        // 圧縮のまま止まったら、止まりを出す（［生成を停止］を押せる）
        let since = Date(timeIntervalSince1970: 20)
        conversation.stalledSince = since
        #expect(ConversationActivity(conversation) == .stalled(since: since))
    }

    @Test("送り直しは止まりの次、圧縮の前に並べる。止まりも送り直しも無ければ圧縮")
    func retryOrder() {
        var conversation = Conversation(
            id: "c1", machine: MachineID(rawValue: "m"), taskNumber: nil, agentSessionID: "s", cwd: "/w", runner: .host, phase: .running,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let compaction = ConversationCompaction(startedAt: Date(timeIntervalSince1970: 10))
        let retry = ConversationAPIRetry(attempt: 3, maxRetries: 10, retryAt: Date(timeIntervalSince1970: 40), kind: "unknown")
        conversation.compaction = compaction
        #expect(ConversationActivity(conversation) == .compacting(compaction))
        conversation.apiRetry = retry
        #expect(ConversationActivity(conversation) == .apiRetry(retry))
        conversation.stalledSince = Date(timeIntervalSince1970: 20)
        #expect(ConversationActivity(conversation) == .stalled(since: Date(timeIntervalSince1970: 20)))
    }

    @Test("右の時間：送り直しは次に送るまでの残り（0.4 秒前は「あと1秒」、過ぎたら空）")
    func clock() {
        let at = Date(timeIntervalSince1970: 1_000)
        let retry = ConversationActivity.apiRetry(ConversationAPIRetry(attempt: 1, retryAt: at, kind: "overloaded"))
        #expect(ConversationActivityRow.clockText(retry, now: at.addingTimeInterval(-12)) == "あと12秒")
        #expect(ConversationActivityRow.clockText(retry, now: at.addingTimeInterval(-0.4)) == "あと1秒")
        #expect(ConversationActivityRow.clockText(retry, now: at.addingTimeInterval(-75)) == "あと1分15秒")
        #expect(ConversationActivityRow.clockText(retry, now: at) == "")
        #expect(ConversationActivityRow.clockText(retry, now: at.addingTimeInterval(30)) == "")
    }

    @Test("送り直しの理由は種類ごと。つながらない（status なしの unknown）と status 付きの unknown を分け、知らない種類は理由を添えない。status の数字は出さない")
    func retryText() {
        #expect(ConversationActivityRow.retryTitle(kind: "unknown", status: nil) == "APIに接続できません。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "unknown", status: 418) == "APIがエラーを返しました。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "overloaded", status: 529) == "APIが混み合っています。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "rate_limit", status: 429) == "利用枠の上限に達しています。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "authentication_failed", status: 401) == "認証できません。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "server_error", status: 500) == "APIがエラーを返しました。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "cloud_credential_error", status: nil) == "クラウドの認証情報を取得できません。送り直しています…")
        #expect(ConversationActivityRow.retryTitle(kind: "新しい種類", status: nil) == "送り直しています…")
        let at = Date(timeIntervalSince1970: 0)
        #expect(ConversationActivityRow.retryProgress(ConversationAPIRetry(attempt: 3, maxRetries: 10, retryAt: at, kind: "unknown")) == "3/10回目")
        #expect(ConversationActivityRow.retryProgress(ConversationAPIRetry(attempt: 3, retryAt: at, kind: "unknown")) == "3回目")
    }
}
