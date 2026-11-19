import Foundation
import Testing

@testable import TaskboardKit

@Suite("権限の確認の「今後は聞かない」候補（wire）")
struct PermissionSuggestionTests {
    private let waiting = RequestWaiting(id: "r1", since: Date(timeIntervalSince1970: 0), permission: .init(tool: "Bash", summary: "ls"))

    @Test("問いと答えは省ける欄で行き来し、省いたときは欄を書かない")
    func roundTrip() throws {
        let suggestions = [PermissionSuggestion(id: "0", kind: .rule, subject: "Bash(ls)", scope: .folder)]
        let request = ConversationRequest(id: "r1", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting, suggestions: suggestions)
        #expect(try JSONDecoder().decode(ConversationRequest.self, from: JSONEncoder().encode(request)) == request)
        let answer = ConversationAnswerRequest(requestID: "r1", allow: true, suggestionID: "0")
        #expect(try JSONDecoder().decode(ConversationAnswerRequest.self, from: JSONEncoder().encode(answer)) == answer)
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationAnswerRequest(requestID: "r", allow: true))) as? [String: Any]
        #expect(bare?["suggestionID"] == nil)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConversationRequest(id: "r1", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting)))
            as? [String: Any]
        #expect(plain?["suggestions"] == nil)
    }

    @Test("候補の無い古い JSON はそのまま読め、この版が知らない種類と残す先は unknown にして問いを捨てない。画面に出すのは知っている種類と残す先だけ")
    func oldAndNewJSON() throws {
        let old = #"{"id":"r1","kind":"permission","toolName":"Bash","waiting":{"id":"r1","since":0}}"#
        #expect(try JSONDecoder().decode(ConversationRequest.self, from: Data(old.utf8)).suggestions == nil)
        let newer =
            #"{"id":"r1","kind":"permission","toolName":"Bash","waiting":{"id":"r1","since":0},"suggestions":[{"id":"0","kind":"rule","subject":"Bash(ls)","scope":"folder"},{"id":"1","kind":"hook","subject":"x","scope":"session"},{"id":"2","kind":"rule","subject":"Bash(ls)","scope":"organization","extra":1}]}"#
        let request = try JSONDecoder().decode(ConversationRequest.self, from: Data(newer.utf8))
        #expect(request.suggestions?.map(\.kind) == [.rule, .unknown, .rule])
        #expect(request.suggestions?.last?.scope == .unknown)
        #expect(PermissionSuggestion.shown(request.suggestions).map(\.id) == ["0"])
        // 古い daemon は suggestionID を読み飛ばす（ただの許可になる）
        let answer = try JSONDecoder().decode(ConversationAnswerRequest.self, from: Data(#"{"requestID":"r1","allow":true,"suggestionID":"0","later":1}"#.utf8))
        #expect(answer.suggestionID == "0" && answer.allow == true)
    }

    @Test("通知の［常に許可］は許可の規則だけ。フォルダの追加・モードの変更・知らない種類だけなら出さない")
    func alwaysSuggestion() {
        func request(_ suggestions: [PermissionSuggestion]?) -> ConversationRequest {
            ConversationRequest(id: "r1", kind: .permission, toolName: "Bash", toolUseID: nil, waiting: waiting, suggestions: suggestions)
        }
        let directory = PermissionSuggestion(id: "0", kind: .directory, subject: "/w", scope: .session)
        let rule = PermissionSuggestion(id: "1", kind: .rule, subject: "Bash(ls)", scope: .session)
        #expect(request([directory, rule]).alwaysSuggestion == rule)
        #expect(request([directory, PermissionSuggestion(id: "2", kind: .mode, subject: "acceptEdits", scope: .session)]).alwaysSuggestion == nil)
        #expect(request(nil).alwaysSuggestion == nil)
    }
}
