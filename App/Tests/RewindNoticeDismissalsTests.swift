import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 巻き戻しの［元に戻す］のバーを消した・送った印（`RewindNoticeDismissals`）。画面を作り直しても、アプリを開き直しても出ない
@Suite struct RewindNoticeDismissalsTests {
    private let studio = MachineID(rawValue: "studio")
    private let laptop = MachineID(rawValue: "laptop")

    private func store() -> UserDefaults {
        let name = "tb-rewind-notice-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func conversation(_ id: String = "c1", machine: MachineID? = nil, session: String = "s1", canUndo: Bool = true) -> Conversation {
        Conversation(
            id: id, machine: machine ?? studio, taskNumber: nil, agentSessionID: session, cwd: "/w", runner: .host, phase: .idle, canUndoRewind: canUndo,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func key(_ conversation: Conversation) -> ConversationKey { ConversationKey(machine: conversation.machine, id: conversation.id) }

    @Test("巻き戻しを元に戻せる会話はバーを出し、消した（送った）印を付けると出さない")
    func dismissHidesNotice() {
        var marks = RewindNoticeDismissals(store: store())
        let rewound = conversation()
        #expect(marks.shows(for: rewound))
        marks.dismiss(rewound)
        #expect(!marks.shows(for: rewound))
        #expect(marks.shows(for: conversation("c2")), "別の会話は出る")
    }

    @Test("巻き戻すと agentSessionID が替わるので、消した後でもまた出る")
    func rewindingAgainShowsAgain() {
        var marks = RewindNoticeDismissals(store: store())
        marks.dismiss(conversation(session: "s1"))
        #expect(marks.shows(for: conversation(session: "s2")))
    }

    @Test("巻き戻しを元に戻せない会話はバーを出さず、印も付けない")
    func nothingToUndo() {
        let defaults = store()
        var marks = RewindNoticeDismissals(store: defaults)
        let plain = conversation(canUndo: false)
        #expect(!marks.shows(for: plain))
        marks.dismiss(plain)
        #expect(defaults.stringArray(forKey: AppPreferences.rewindNoticeDismissalsKey) == nil)
    }

    @Test("アプリを開き直しても印が残る")
    func survivesRelaunch() {
        let defaults = store()
        var first = RewindNoticeDismissals(store: defaults)
        first.dismiss(conversation())
        let relaunched = RewindNoticeDismissals(store: defaults)
        #expect(!relaunched.shows(for: conversation()))
        #expect(relaunched.shows(for: conversation(session: "s2")))
    }

    @Test("100 件を超えたら古いものから落ちる。印を付け直した会話は新しい側に入る")
    func dropsOldestOverLimit() {
        let defaults = store()
        var marks = RewindNoticeDismissals(store: defaults)
        for index in 0..<RewindNoticeDismissals.limit { marks.dismiss(conversation("c\(index)")) }
        marks.dismiss(conversation("c0"))
        marks.dismiss(conversation("extra"))
        #expect(marks.shows(for: conversation("c1")), "いちばん古い印が落ちる")
        #expect(!marks.shows(for: conversation("c0")), "付け直した印は残る")
        #expect(!marks.shows(for: conversation("extra")))
        #expect(!marks.shows(for: conversation("c\(RewindNoticeDismissals.limit - 1)")))
        #expect(defaults.stringArray(forKey: AppPreferences.rewindNoticeDismissalsKey)?.count == RewindNoticeDismissals.limit)
    }

    @Test("保存先に 100 件を超えて入っていても、読み込みで新しい方の 100 件に切る")
    func trimsOnLoad() {
        let defaults = store()
        defaults.set((0..<(RewindNoticeDismissals.limit + 5)).map { "studio\nc\($0)\ns1" } + ["壊れた行"], forKey: AppPreferences.rewindNoticeDismissalsKey)
        let marks = RewindNoticeDismissals(store: defaults)
        #expect(marks.shows(for: conversation("c4")))
        #expect(!marks.shows(for: conversation("c5")))
    }

    @Test("元に戻して canUndoRewind が false になった会話の印は消える")
    func reconcileDropsUndone() {
        var marks = RewindNoticeDismissals(store: store())
        marks.dismiss(conversation())
        let undone = conversation(canUndo: false)
        let changed = marks.reconcile(listed: [studio: [key(undone): undone]])
        #expect(changed)
        // 同じ会話がまた巻き戻されたら、前の印は残っておらず出る
        #expect(marks.shows(for: conversation()))
    }

    @Test("一覧から無くなった会話の印は消え、残っている会話の印は残る")
    func reconcileDropsGone() {
        var marks = RewindNoticeDismissals(store: store())
        let kept = conversation("kept")
        let gone = conversation("gone")
        marks.dismiss(kept)
        marks.dismiss(gone)
        let changed = marks.reconcile(listed: [studio: [key(kept): kept]])
        #expect(changed)
        #expect(!marks.shows(for: kept))
        #expect(marks.shows(for: gone))
        let again = marks.reconcile(listed: [studio: [key(kept): kept]])
        #expect(!again, "消すものが無ければ false")
    }

    @Test("一覧を読み終えていないマシンの印は残す")
    func reconcileKeepsUnlistedMachines() {
        let defaults = store()
        var marks = RewindNoticeDismissals(store: defaults)
        let away = conversation("c1", machine: laptop)
        marks.dismiss(away)
        let noneRead = marks.reconcile(listed: [:])
        let otherRead = marks.reconcile(listed: [studio: [:]])
        #expect(!noneRead, "どのマシンも読んでいない")
        #expect(!otherRead, "別のマシンを読み終えただけ")
        #expect(!RewindNoticeDismissals(store: defaults).shows(for: away))
        let ownRead = marks.reconcile(listed: [laptop: [:]])
        #expect(ownRead, "そのマシンを読み終えて会話が無ければ消す")
        #expect(RewindNoticeDismissals(store: defaults).shows(for: away))
    }
}
