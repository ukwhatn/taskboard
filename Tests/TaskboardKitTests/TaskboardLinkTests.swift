import Foundation
import Testing

@testable import TaskboardKit

@Suite("taskboard:// の組み立てと読み取り")
struct TaskboardLinkTests {
    private let machine = MachineID(rawValue: "studio")

    @Test("組み立てた URL を読むと同じ行き先に戻る")
    func roundTrip() {
        let links: [TaskboardLink] = [
            .pullRequest(url: "https://github.com/o/r/pull/1?a=b&c"), .orchestrator(nil), .orchestrator(machine),
            .unassigned(machine),
            .conversation(ConversationKey(machine: machine, id: "c-1")), .boards, .board(machine: machine, id: "default"),
            .task(TaskKey(machine: machine, number: 12)), .task(TaskKey(machine: machine, number: 12), doc: 5),
        ]
        for link in links {
            #expect(TaskboardLink(url: link.url) == link, "\(link.url)")
        }
    }

    @Test("今の URL の書き方を読む")
    func parses() {
        #expect(TaskboardLink(url: URL(string: "taskboard://task/studio/12/doc/5")!) == .task(TaskKey(machine: machine, number: 12), doc: 5))
        #expect(TaskboardLink(url: URL(string: "taskboard://pr?url=https://github.com/o/r/pull/1")!) == .pullRequest(url: "https://github.com/o/r/pull/1"))
        #expect(TaskboardLink(url: URL(string: "taskboard://task/studio/12")!).map(\.url.absoluteString) == "taskboard://task/studio/12")
    }

    @Test("前の版の daemon が送る URL: PR の一覧の PR はその PR、ほかの一覧の画面と端末のセッションは全体のボード")
    func parsesOldLinks() {
        #expect(TaskboardLink(url: URL(string: "taskboard://prs?url=https://github.com/o/r/pull/1")!) == .pullRequest(url: "https://github.com/o/r/pull/1"))
        for text in ["taskboard://prs", "taskboard://inbox", "taskboard://sessions", "taskboard://schedules", "taskboard://session/studio/w1:p2"] {
            #expect(TaskboardLink(url: URL(string: text)!) == .boards, "\(text)")
        }
    }

    @Test("読めない URL は nil（別の scheme、足りない部分、番号でない番号、知らない行き先）")
    func rejects() {
        for text in ["https://example.com/task/studio/1", "taskboard://task/studio", "taskboard://task/studio/x", "taskboard://nope", "taskboard://board/studio", "taskboard://unassigned"] {
            #expect(TaskboardLink(url: URL(string: text)!) == nil, "\(text)")
        }
        // 文書の id が読めなければタスクだけ
        #expect(TaskboardLink(url: URL(string: "taskboard://task/studio/3/doc/x")!) == .task(TaskKey(machine: machine, number: 3)))
    }

    private func schedule(task: Int?) -> Schedule {
        Schedule(
            scheduleID: 1, machine: machine, name: "朝", enabled: true, rule: .interval(minutes: 60), cwd: "/tmp", kind: .claude, agentArgs: [],
            prompt: "", taskNumber: task, overlap: .skip, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func run(conversation: String? = nil) -> ScheduleRun {
        ScheduleRun(
            id: 1, scheduleID: 1, scheduledAt: Date(timeIntervalSince1970: 0), trigger: .schedule, conversationID: conversation,
            createdAt: Date(timeIntervalSince1970: 0))
    }

    @Test("定期起動の実行の行き先: 会話 → タスク → タスクなし。state があれば、今ある会話だけを選ぶ")
    func scheduleRun() {
        var state = MachineState()
        let conversation = Conversation(
            id: "c-1", machine: machine, taskNumber: 4, agentSessionID: "a", cwd: "/tmp", runner: .host, phase: .idle,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        state.conversations[conversation.key] = conversation

        #expect(TaskboardLink.scheduleRun(schedule(task: 4), run(conversation: "c-1"), in: state) == .conversation(conversation.key))
        #expect(TaskboardLink.scheduleRun(schedule(task: 4), run(conversation: "gone"), in: state) == .task(TaskKey(machine: machine, number: 4)))
        #expect(TaskboardLink.scheduleRun(schedule(task: nil), run(), in: state) == .unassigned(machine))
        // 通知（state を持たない）は、記録にあるものを順に選ぶ
        #expect(TaskboardLink.scheduleRun(schedule(task: 4), run(conversation: "gone"), in: nil) == .conversation(ConversationKey(machine: machine, id: "gone")))
        // 会話の無い回（前の版の pane の回）は、タスクへ
        #expect(TaskboardLink.scheduleRun(schedule(task: 4), run(), in: nil) == .task(TaskKey(machine: machine, number: 4)))
    }
}
