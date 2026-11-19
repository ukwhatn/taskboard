import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("ターンの応答とツールの拾い方")
struct ConversationTurnActivityTests {
    func message(_ kind: ChatMessage.Kind, _ text: String = "", role: ChatMessage.Role = .assistant, tool: (String, String)? = nil, parent: String? = nil)
        -> ChatMessage
    {
        var made = ChatMessage(id: UUID().uuidString, role: role, kind: kind, text: text, toolName: tool?.1, toolID: tool?.0)
        made.parentToolID = parent
        return made
    }

    @Test("最後に始めてまだ終わっていないツールを使っているツールにし、変わったときだけ true を返す")
    func tools() {
        var activity = ConversationTurnActivity()
        var changed = false
        changed = activity.note([message(.toolUse, tool: ("t1", "Read"))])
        #expect(changed)
        #expect(activity.toolName == "Read")
        changed = activity.note([message(.toolUse, tool: ("t2", "Bash"))])
        #expect(changed)
        changed = activity.note([message(.toolUse, tool: ("t2", "Bash"))])
        #expect(!changed, "同じツールの 2 回目（codex の始まりと終わりの item）")
        changed = activity.note([message(.toolResult, tool: ("t2", "Bash"))])
        #expect(changed)
        #expect(activity.toolName == "Read", "前に始めたツールに戻る")
        changed = activity.note([message(.toolUse, tool: ("s1", "Grep"), parent: "t9")])
        #expect(!changed, "サブエージェントのツールは見ない")
        changed = activity.reset()
        #expect(changed)
        #expect(activity.toolName == nil)
        changed = activity.reset()
        #expect(!changed)
    }

    @Test("応答は主の流れの assistant の文の最後のもの。考え中・人の発言・サブエージェント・空白だけの文は入れない")
    func reply() {
        var activity = ConversationTurnActivity()
        _ = activity.note([message(.text, "初めの文"), message(.text, "人の文", role: .user)])
        #expect(activity.reply == "初めの文")
        var thinking = message(.text, "考え中")
        thinking.thinking = true
        _ = activity.note([thinking, message(.text, "子の文", parent: "t1"), message(.text, "  \n")])
        #expect(activity.reply == "初めの文")
        _ = activity.note([message(.text, "\n終わりの文 Done.\n")])
        #expect(activity.reply == "終わりの文 Done.")
        _ = activity.reset()
        #expect(activity.reply == nil)
    }

    @Test("DaemonState はツールを全体に載せて変わったときだけ配り、生成中でなくなった会話と消えた会話のツールは消す")
    func stateToolActivity() async throws {
        let machine = MachineID(rawValue: "m")
        let state = DaemonState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let (subscription, events) = await state.subscribe()
        let t0 = Date(timeIntervalSince1970: 1_791_100_000)
        var conversation = Conversation(
            id: "c1", machine: machine, taskNumber: nil, agentSessionID: "s1", cwd: "/", runner: .host, phase: .running, createdAt: t0, updatedAt: t0)
        await state.setToolActivity(id: "c1", toolName: "Bash")
        #expect(await state.snapshot().conversationActivities.isEmpty, "載っていない会話の分は持たない")
        await state.upsert(conversation)
        await state.setToolActivity(id: "c1", toolName: "Bash")
        await state.setToolActivity(id: "c1", toolName: "Bash")
        let key = ConversationKey(machine: machine, id: "c1")
        #expect(await state.snapshot().conversationActivities == [ConversationToolActivity(conversation: key, toolName: "Bash")])
        conversation.phase = .idle
        await state.upsert(conversation)
        #expect(await state.snapshot().conversationActivities.isEmpty)
        await state.setToolActivity(id: "c1", toolName: "Read")
        await state.removeConversation(id: "c1")
        #expect(await state.snapshot().conversationActivities.isEmpty)
        await state.unsubscribe(subscription)
        var tools: [String?] = []
        for await event in events {
            if case .conversationActivity(let activity) = event { tools.append(activity.toolName) }
        }
        #expect(tools == ["Bash", nil, "Read"], "同じツールは 2 回配らない")
    }
}
