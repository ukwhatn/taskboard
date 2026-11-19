import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話が止まった理由")
struct ConversationStopCauseTests {
    @Test("記録の文から理由を引き、理由から同じ文に戻る。前の daemon が書いた文も同じ理由になる")
    func roundTrip() {
        let written: [(String, ConversationStopCause)] = [
            ("止めた", .person), ("終了した", .closed), ("taskboard が止めた", .taskboard), ("操作のために止めた", .suspended), ("使われていないので止めた", .idle),
            ("質問を defer で終えた", .deferred), ("定期起動の回が終わったので止めた", .finished), ("agent host が起き直した", .hostRestarted),
            ("agent host に無い", .hostMissing), ("起こせなかった", .startFailed),
        ]
        for (text, cause) in written {
            #expect(ConversationStopCause(lastExit: text) == cause)
            #expect(cause.lastExit == text)
        }
    }

    @Test("決まった文でない理由（終了コード・signal・空の文）はそのまま残し、人が止めたとは読まない")
    func unexpected() {
        for text in ["終了コード 1 で終わった", "signal 9 で終わった", "", "止めた "] {
            #expect(ConversationStopCause(lastExit: text) == .unexpected(text))
            #expect(ConversationStopCause(lastExit: text).lastExit == text)
            #expect(ConversationStopCause(lastExit: text) != .person)
        }
    }

    @Test("止めると作業の途中で止まるのは、生成中・問いの答え待ち・起こしている途中。止めると記録が消えるのはタスクにも用途にも結ばれていない会話")
    func predicates() {
        func conversation(_ phase: Conversation.Phase, task: Int? = 1, purpose: Conversation.Purpose? = nil) -> Conversation {
            Conversation(
                id: "c1", machine: MachineID(rawValue: "m1"), taskNumber: task, agentSessionID: "s1", cwd: "/tmp", runner: phase == .stopped ? .none : .host,
                phase: phase, purpose: purpose, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        }
        #expect([Conversation.Phase.starting, .running, .waiting].allSatisfy { conversation($0).interruptedByStop })
        #expect(![Conversation.Phase.idle, .stopped].contains { conversation($0).interruptedByStop })
        #expect(!conversation(.idle, task: nil, purpose: .schedule).removedOnStop)
    }

    @Test("終了したのは、止まっていて理由が「終了した」か定期起動の回の終わり。人の停止・自動停止・動いている会話は終了でない。人の停止と終了は起こさない")
    func closed() {
        func conversation(_ phase: Conversation.Phase, _ cause: ConversationStopCause?) -> Conversation {
            var conversation = Conversation(
                id: "c1", machine: MachineID(rawValue: "m1"), taskNumber: 1, agentSessionID: "s1", cwd: "/tmp", runner: .none, phase: phase,
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
            conversation.lastExit = cause?.lastExit
            return conversation
        }
        #expect(conversation(.stopped, .closed).isClosed && conversation(.stopped, .finished).isClosed)
        #expect(![ConversationStopCause.person, .idle, .taskboard, .unexpected("終了コード 1 で終わった")].contains { conversation(.stopped, $0).isClosed })
        #expect(!conversation(.stopped, nil).isClosed && !conversation(.idle, .closed).isClosed)
        #expect(ConversationStopCause.person.keepsStopped && ConversationStopCause.closed.keepsStopped)
        #expect(![ConversationStopCause.idle, .taskboard, .finished].contains { $0.keepsStopped })
    }
}
