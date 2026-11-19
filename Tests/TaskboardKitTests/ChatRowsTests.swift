import Foundation
import Testing

@testable import TaskboardKit

@Suite("チャットの行の並び")
struct ChatRowsTests {
    private func text(_ id: String, _ role: ChatMessage.Role = .assistant) -> ChatMessage { ChatMessage(id: id, role: role, kind: .text, text: id) }
    private func call(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .toolUse, text: id, toolName: "Bash", toolID: "t-\(id)") }
    private func result(_ id: String, of call: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .toolResult, text: id, toolID: "t-\(call)") }
    private func injected(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .text, text: id, injected: true) }
    private func thought(_ id: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: id, thinking: true) }

    private func shape(_ rows: [ChatRows.Row]) -> [String] {
        rows.map { row in
            switch row {
            case .message(let message): message.id
            case .tools(let members): "[" + members.map(\.id).joined(separator: " ") + "]"
            }
        }
    }

    @Test("続いたツールの呼び出しと差し込んだ文を 1 組にまとめ、呼び出しの結果は組に入れない。文・人の発言・印で組が切れる")
    func groupsRuns() {
        let messages = [
            text("u1", .user), call("c1"), result("r1", of: "c1"), injected("i1"), call("c2"), result("r2", of: "c2"), text("a1"),
            call("c3"), result("r3", of: "c3"), ChatMessage(id: "n1", role: .user, kind: .notice, text: "中断しました"), call("c4"), call("c5"),
        ]
        #expect(shape(ChatRows.rows(messages, groupsTools: true)) == ["u1", "[c1 i1 c2]", "a1", "c3", "n1", "[c4 c5]"])
    }

    @Test("組の間に挟まる思考は組の中に入れる。組の前と後ろの思考は組に入れず、1 行ずつ出す。組にしないときは 1 行ずつ")
    func thinkingBetweenTools() {
        let interleaved = [thought("k0"), call("c1"), thought("k1"), call("c2"), thought("k2"), text("a1")]
        #expect(shape(ChatRows.rows(interleaved, groupsTools: true)) == ["k0", "[c1 k1 c2]", "k2", "a1"])
        #expect(shape(ChatRows.rows(interleaved, groupsTools: false)) == ["k0", "c1", "k1", "c2", "k2", "a1"])
        // 呼び出しが 1 件だけなら、思考は組の外
        #expect(shape(ChatRows.rows([thought("k0"), call("c1"), thought("k1")], groupsTools: true)) == ["k0", "c1", "k1"])
        // 思考だけが続いても組にしない
        #expect(shape(ChatRows.rows([thought("k0"), thought("k1")], groupsTools: true)) == ["k0", "k1"])
        // 思考が前に付いても、組の id は最初の呼び出しから作る
        let before = ChatRows.rows([call("c1"), thought("k1"), call("c2")], groupsTools: true)
        let after = ChatRows.rows([thought("k0"), call("c1"), thought("k1"), call("c2")], groupsTools: true)
        #expect(before.map(\.id) == ["tools/c1"] && after.map(\.id) == ["k0", "tools/c1"])
    }

    @Test("思考の印は true のときだけ書き、無い JSON（前の版の daemon）は思考でないとして読む。前の版のアプリは鍵を知らず、返答の文として出す")
    func thinkingWire() throws {
        let plain = String(decoding: try JSONEncoder().encode(text("a1")), as: UTF8.self)
        #expect(!plain.contains("thinking"))
        let wire = try JSONEncoder().encode(thought("k1"))
        let object = try #require(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(object["kind"] as? String == "text" && object["thinking"] as? Bool == true)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: wire).isThinking)
        #expect(!text("a1").isThinking)
    }

    @Test("サブエージェントの発言は本筋の行にせず、呼び出しの id ごとに古い順でまとめる。中の行は parent を渡して同じ規則で組む")
    func subagents() {
        func child(_ message: ChatMessage, of parent: String = "t-agent") -> ChatMessage {
            var message = message
            message.parentToolID = parent
            return message
        }
        let messages = [
            text("u1", .user), call("agent"), child(text("s1", .user)), child(call("s2")), child(result("s3", of: "s2")), child(call("s4")),
            child(text("n1"), of: "t-s4"), result("r1", of: "agent"), text("a1"),
        ]
        #expect(shape(ChatRows.rows(messages, groupsTools: true)) == ["u1", "agent", "a1"])
        let children = ChatRows.subagents(messages)
        #expect(children.mapValues { $0.map(\.id) } == ["t-agent": ["s1", "s2", "s3", "s4"], "t-s4": ["n1"]])
        #expect(shape(ChatRows.rows(children["t-agent"] ?? [], groupsTools: true, parent: "t-agent")) == ["s1", "[s2 s4]"])
        #expect(ChatRows.subagents([text("u1", .user)]).isEmpty)
    }

    @Test("組にしないときは、呼び出しに結んだ結果だけを外して 1 件ずつ。呼び出しの無い結果は行に出す")
    func ungrouped() {
        let messages = [call("c1"), result("r1", of: "c1"), call("c2"), result("orphan", of: "gone")]
        #expect(shape(ChatRows.rows(messages, groupsTools: false)) == ["c1", "c2", "orphan"])
        #expect(shape(ChatRows.rows(messages, groupsTools: true)) == ["[c1 c2]", "orphan"])
        #expect(ChatRows.rows([], groupsTools: true).isEmpty)
    }

    @Test("組の id は最初の行の id から作り、後ろに行が増えても変わらない（開いた状態を保つ）")
    func stableID() {
        let before = ChatRows.rows([call("c1"), call("c2")], groupsTools: true)
        let after = ChatRows.rows([call("c1"), call("c2"), call("c3")], groupsTools: true)
        #expect(before.map(\.id) == after.map(\.id))
    }

    @Test("前・次の人の発言へ：前は送った発言の 1 つ前（初めは末尾）、先頭では動かない。次は 1 つ後ろで、末尾の後と初めは nil（下端へ戻す）。差し込んだ文と組には止まらない")
    func promptStep() {
        let rows = ChatRows.rows([text("u1", .user), call("c1"), call("c2"), text("a1"), injected("i1"), text("u2", .user), text("a2"), text("u3", .user)], groupsTools: true)
        #expect(ChatRows.promptStep(rows, forward: false, from: nil) == "u3")
        #expect(ChatRows.promptStep(rows, forward: false, from: "u3") == "u2")
        #expect(ChatRows.promptStep(rows, forward: false, from: "u2") == "u1")
        #expect(ChatRows.promptStep(rows, forward: false, from: "u1") == "u1")
        #expect(ChatRows.promptStep(rows, forward: true, from: "u1") == "u2")
        #expect(ChatRows.promptStep(rows, forward: true, from: "u3") == nil)
        #expect(ChatRows.promptStep(rows, forward: true, from: nil) == nil)
        // 送った発言が一覧から消えていたら、初めと同じ
        #expect(ChatRows.promptStep(rows, forward: false, from: "gone") == "u3")
        #expect(ChatRows.promptStep([], forward: false, from: nil) == nil)
    }

    @Test("差し込んだ文は人の発言でないので、巻き戻しの対象にしない")
    func injectedIsNotRewindTarget() {
        #expect(!injected("i1").isRewindTarget)
        #expect(text("u1", .user).isRewindTarget)
    }

    @Test("差し込んだ印は true のときだけ書き、無い JSON（前の版の daemon）は差し込みでないとして読む")
    func wire() throws {
        let plain = try JSONEncoder().encode(text("u1", .user))
        #expect(!String(decoding: plain, as: UTF8.self).contains("injected"))
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: try JSONEncoder().encode(injected("i1")))
        #expect(decoded.isInjected)
        #expect(!(try JSONDecoder().decode(ChatMessage.self, from: plain)).isInjected)
    }

    @Test("発言 1 件の形は、ツールの呼び出し・思考・taskboard の知らせ・差し込んだ文・そのほかの順で決める")
    func messageShape() {
        #expect(ChatRows.shape(of: call("c1")) == .toolCall)
        #expect(ChatRows.shape(of: thought("k1")) == .thinking)
        let notice = ChatMessage(id: "p1", role: .user, kind: .text, text: TaskboardNotice.limitResumePrompt)
        #expect(ChatRows.shape(of: notice) == .notice(.limitResume))
        #expect(ChatRows.shape(of: injected("i1")) == .injected)
        #expect(ChatRows.shape(of: text("u1", .user)) == .plain)
        #expect(ChatRows.shape(of: text("a1")) == .plain)
        #expect(ChatRows.shape(of: result("r1", of: "c1")) == .plain)
        #expect(ChatRows.shape(of: ChatMessage(id: "n1", role: .user, kind: .notice, text: "中断しました")) == .plain)
    }

    @Test("サブエージェントの発言は、入れ子のサブエージェントの分も集める")
    func descendants() {
        let outer = ChatMessage(id: "o1", role: .assistant, kind: .toolUse, text: "o1", toolName: "Agent", toolID: "t-inner", parentToolID: "t-agent")
        let said = ChatMessage(id: "o2", role: .assistant, kind: .text, text: "o2", parentToolID: "t-agent")
        let inner = ChatMessage(id: "n1", role: .assistant, kind: .text, text: "n1", parentToolID: "t-inner")
        let subagents = ["t-agent": [outer, said], "t-inner": [inner]]
        #expect(Set(ChatRows.descendants(of: "t-agent", in: subagents).map(\.id)) == ["o1", "o2", "n1"])
        #expect(ChatRows.descendants(of: "t-inner", in: subagents).map(\.id) == ["n1"])
        #expect(ChatRows.descendants(of: "t-none", in: subagents).isEmpty)
    }
}
