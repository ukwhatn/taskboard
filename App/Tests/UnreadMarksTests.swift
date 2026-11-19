import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// サイドバーのタスクの行の「未読」の印（`UnreadMarks`）。この端末で、画面に出していない間に終わったターン
@Suite struct UnreadMarksTests {
    private let studio = MachineID(rawValue: "studio")
    private let laptop = MachineID(rawValue: "laptop")

    private func store() -> UserDefaults {
        let name = "tb-unread-marks-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func conversation(_ id: String = "c1", machine: MachineID? = nil, phase: Conversation.Phase) -> Conversation {
        Conversation(
            id: id, machine: machine ?? studio, taskNumber: 1, agentSessionID: "s1", cwd: "/w", runner: .host, phase: phase,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func state(_ conversations: [Conversation] = []) -> MachineState {
        var state = MachineState(connected: true)
        state.conversations = Dictionary(uniqueKeysWithValues: conversations.map { (ConversationKey(machine: $0.machine, id: $0.id), $0) })
        return state
    }

    private func key(_ conversation: Conversation) -> ConversationKey { ConversationKey(machine: conversation.machine, id: conversation.id) }

    @Test("動いていた会話が止まったら、画面に出していなければ未読にする")
    func finishedTurnIsUnread() {
        var marks = UnreadMarks(store: store())
        marks.observe([studio: state([conversation(phase: .running)])], shown: [])
        #expect(!marks.isUnread(conversation(phase: .running)))
        let changed = marks.observe([studio: state([conversation(phase: .idle)])], shown: [])
        #expect(changed)
        #expect(marks.isUnread(conversation(phase: .idle)))
    }

    @Test("回答待ちから止まった会話も、プロセスが無くなった会話も未読にする")
    func waitingAndStoppedCount() {
        var marks = UnreadMarks(store: store())
        marks.observe([studio: state([conversation("c1", phase: .waiting), conversation("c2", phase: .starting)])], shown: [])
        marks.observe([studio: state([conversation("c1", phase: .idle), conversation("c2", phase: .stopped)])], shown: [])
        #expect(marks.isUnread(conversation("c1", phase: .idle)))
        #expect(marks.isUnread(conversation("c2", phase: .stopped)))
    }

    @Test("画面に出している間に終わったターンは未読にしない")
    func shownTurnIsRead() {
        var marks = UnreadMarks(store: store())
        let running = conversation(phase: .running)
        marks.observe([studio: state([running])], shown: [])
        marks.observe([studio: state([conversation(phase: .idle)])], shown: [key(running)])
        #expect(!marks.isUnread(running))
    }

    @Test("初めて見たときに止まっている会話は未読にしない（アプリを閉じている間に終わったターンは数えない）")
    func firstSightIsNotUnread() {
        var marks = UnreadMarks(store: store())
        let changed = marks.observe([studio: state([conversation(phase: .idle)])], shown: [])
        #expect(!changed)
        #expect(!marks.isUnread(conversation(phase: .idle)))
    }

    @Test("未読の会話は、画面に出すか、また動き出すと既読になる")
    func showingOrResumingClears() {
        var marks = UnreadMarks(store: store())
        marks.observe([studio: state([conversation("c1", phase: .running), conversation("c2", phase: .running)])], shown: [])
        marks.observe([studio: state([conversation("c1", phase: .idle), conversation("c2", phase: .idle)])], shown: [])
        let changed = marks.observe([studio: state([conversation("c1", phase: .idle), conversation("c2", phase: .running)])], shown: [key(conversation("c1", phase: .idle))])
        #expect(changed)
        #expect(!marks.isUnread(conversation("c1", phase: .idle)))
        #expect(!marks.isUnread(conversation("c2", phase: .running)))
    }

    @Test("［既読にする］で消す")
    func markReadClears() {
        var marks = UnreadMarks(store: store())
        marks.observe([studio: state([conversation(phase: .running)])], shown: [])
        marks.observe([studio: state([conversation(phase: .idle)])], shown: [])
        marks.markRead([conversation(phase: .idle)])
        #expect(!marks.isUnread(conversation(phase: .idle)))
    }

    @Test("接続が切れているマシンの印は残し、一覧から無くなった会話の印は消す")
    func reconcileOnlyListedMachines() {
        var marks = UnreadMarks(store: store())
        let other = conversation("c9", machine: laptop, phase: .running)
        marks.observe([studio: state([conversation(phase: .running)]), laptop: state([other])], shown: [])
        marks.observe([studio: state([conversation(phase: .idle)]), laptop: state([conversation("c9", machine: laptop, phase: .idle)])], shown: [])
        marks.observe([studio: state([])], shown: [])
        #expect(!marks.isUnread(conversation(phase: .idle)), "一覧から消えた")
        #expect(marks.isUnread(conversation("c9", machine: laptop, phase: .idle)), "laptop は一覧を読めていない")
    }

    @Test("印はアプリを開き直しても残る")
    func persists() {
        let defaults = store()
        var marks = UnreadMarks(store: defaults)
        marks.observe([studio: state([conversation(phase: .running)])], shown: [])
        marks.observe([studio: state([conversation(phase: .idle)])], shown: [])
        let reopened = UnreadMarks(store: defaults)
        #expect(reopened.isUnread(conversation(phase: .idle)))
    }
}
