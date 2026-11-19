import Foundation
import Testing

@testable import TaskboardKit

@Suite("Codex の承認の選択肢")
struct ConversationDecisionTests {
    private let waiting = RequestWaiting(id: "codex-0", since: Date(timeIntervalSince1970: 0), permission: .init(tool: "Bash", summary: "touch a.txt"))

    @Test("問いの選択肢と答えは省ける欄で行き来する。省いたときは欄を書かない")
    func roundTrip() throws {
        let request = ConversationRequest(
            id: "codex-0", kind: .permission, toolName: "Bash", toolUseID: "exec-1", waiting: waiting, decisions: [.accept, .acceptForSession, .decline, .cancel])
        #expect(try JSONDecoder().decode(ConversationRequest.self, from: JSONEncoder().encode(request)) == request)
        let answer = ConversationAnswerRequest(requestID: "codex-0", allow: true, decision: .acceptForSession)
        #expect(try JSONDecoder().decode(ConversationAnswerRequest.self, from: JSONEncoder().encode(answer)) == answer)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationAnswerRequest(requestID: "r", allow: false))) as? [String: Any]
        #expect(plain?["decision"] == nil)
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationRequest(id: "r", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting))) as? [String: Any]
        #expect(bare?["decisions"] == nil)
    }

    @Test("選択肢の無い古い JSON はそのまま読め、この版が知らない選択肢は unknown にする（問いを捨てない）")
    func oldAndNewJSON() throws {
        let old = #"{"id":"r1","kind":"permission","toolName":"Bash","waiting":{"id":"r1","since":0}}"#
        let request = try JSONDecoder().decode(ConversationRequest.self, from: Data(old.utf8))
        #expect(request.decisions == nil && request.kind == .permission)
        let newer = #"{"id":"r1","kind":"permission","toolName":"Bash","waiting":{"id":"r1","since":0},"decisions":["accept","acceptForever","cancel"]}"#
        #expect(try JSONDecoder().decode(ConversationRequest.self, from: Data(newer.utf8)).decisions == [.accept, .unknown, .cancel])
        let answer = try JSONDecoder().decode(ConversationAnswerRequest.self, from: Data(#"{"requestID":"r1","allow":true}"#.utf8))
        #expect(answer.decision == nil && answer.allow == true)
    }

    @Test("許可の側は accept と acceptForSession。古い daemon にも同じ向きで届くよう allow に読み替える")
    func allows() {
        #expect(ConversationDecision.accept.allows && ConversationDecision.acceptForSession.allows)
        #expect(!ConversationDecision.decline.allows && !ConversationDecision.cancel.allows && !ConversationDecision.unknown.allows)
    }
}
