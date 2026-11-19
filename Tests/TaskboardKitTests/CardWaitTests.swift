import Foundation
import Testing

@testable import TaskboardKit

@Suite("カードの待ち理由")
struct CardWaitTests {
    private let machine = MachineID(rawValue: "m-test")
    private let calendar = Calendar(identifier: .gregorian)
    private var today: Date { BoardTask.dateFormatter.date(from: "2026-10-03")! }
    private let prURL = "https://github.com/o/r/pull/1"
    private let pr2URL = "https://github.com/o/r/pull/2"

    private func task(due: String? = nil, updatedDaysAgo: Int = 0, sessionIDs: [String] = [], column: String = "working") -> BoardTask {
        let updated = calendar.date(byAdding: .day, value: -updatedDaysAgo, to: today)!
        return BoardTask(
            machine: machine, number: 1, boardID: "b", columnID: column, title: "t", due: due,
            sessions: sessionIDs.map { TaskSessionRef(id: 1, agent: "claude", sessionID: $0, cwd: "", linkedAt: updated) },
            createdAt: updated, updatedAt: updated)
    }

    private func conversation(_ phase: Conversation.Phase) -> Conversation {
        Conversation(
            id: "c1", machine: machine, taskNumber: 1, agentSessionID: "s1", cwd: "/", runner: phase == .stopped ? .none : .host, phase: phase,
            createdAt: today, updatedAt: today)
    }

    private func pr(_ url: String? = nil, _ state: PullRequestLinkState.State = .open, draft: Bool = false, checks: CheckState? = nil, review: String? = nil) -> LinkStatus {
        LinkStatus(url: url ?? prURL, fetchedAt: today, pullRequest: PullRequestLinkState(state: state, isDraft: draft, checks: checks, reviewDecision: review))
    }

    private func item(_ blocker: WorkItem.BlockerKind, _ text: String = "") -> WorkItem {
        WorkItem(
            machine: machine, itemID: 1, taskNumber: 1, title: "x", state: .wait, blockerKind: blocker, blockerText: text,
            position: 0, source: "session", createdAt: today, updatedAt: today)
    }

    private func line(_ task: BoardTask, _ signals: CardSignals) -> WaitLine? {
        task.waitLine(signals, today: today, calendar: calendar)
    }

    @Test("期日は名詞句（数字の前後は空けない）")
    func dueAndIdle() {
        #expect(line(task(due: "2026-10-01"), CardSignals()) == WaitLine(text: "期日超過2日", tone: .mine))
        #expect(line(task(due: "2026-10-03"), CardSignals()) == WaitLine(text: "期日は今日", tone: .mine))
        #expect(line(task(due: "2026-10-04"), CardSignals()) == WaitLine(text: "期日は明日", tone: .theirs))
        #expect(line(task(due: "2026-10-13"), CardSignals()) == WaitLine(text: "期日まで10日", tone: .quiet))
    }

    @Test("動いていない日数は待ち理由に出さない（カードの別の札、TaskStallTests）")
    func idleIsNotAWait() {
        for column in ["review_req", "todo", "planning", "working", "review", "deploying"] {
            #expect(line(task(updatedDaysAgo: 30, column: column), CardSignals()) == nil, "\(column)")
        }
    }

    @Test("会話の状態は待ち理由にしない（問いは受信箱の帯が出す）")
    func conversationsAreNotWaits() {
        let t = task(sessionIDs: ["s1"])
        #expect(line(t, CardSignals(conversations: [conversation(.waiting)])) == nil)
        #expect(line(t, CardSignals(conversations: [conversation(.running)])) == nil)
    }

    @Test("自分の番は、相手待ちより先に出す")
    func mineFirst() {
        // 同じ重みなら、作業項目 → PR → 期日 の順
        let both = CardSignals(workItems: [item(.approval, "計画の承認待ち")], links: [pr(checks: .failure)])
        #expect(line(task(), both)?.text == "計画の承認待ち")
    }

    @Test("PR: CI 失敗・修正依頼・承認済みは自分の番、レビュー待ちは相手、CI 実行中は情報。draft と閉じた PR は見ない")
    func pullRequests() {
        #expect(line(task(), CardSignals(links: [pr(checks: .failure)])) == WaitLine(text: "CI失敗", tone: .mine))
        #expect(line(task(), CardSignals(links: [pr(checks: .error)]))?.text == "CI失敗")
        #expect(line(task(), CardSignals(links: [pr(review: "CHANGES_REQUESTED")])) == WaitLine(text: "修正依頼あり", tone: .mine))
        #expect(line(task(), CardSignals(links: [pr(checks: .success, review: "APPROVED")])) == WaitLine(text: "承認済み・マージ待ち", tone: .mine))
        #expect(line(task(), CardSignals(links: [pr(checks: .pending, review: "APPROVED")])) == WaitLine(text: "CI実行中", tone: .quiet))
        #expect(line(task(), CardSignals(links: [pr(review: "REVIEW_REQUIRED")])) == WaitLine(text: "レビュー待ち", tone: .theirs))
        #expect(line(task(), CardSignals(links: [pr(checks: .pending)])) == WaitLine(text: "CI実行中", tone: .quiet))
        #expect(line(task(), CardSignals(links: [pr(checks: .expected)]))?.text == "CI実行中")
        #expect(line(task(), CardSignals(links: [pr(draft: true, checks: .failure)])) == nil)
        #expect(line(task(), CardSignals(links: [pr(nil, .merged)])) == nil)
        #expect(line(task(), CardSignals(links: [pr(nil, .closed, checks: .failure)])) == nil)
        // PR が 2 本なら重い方
        #expect(line(task(), CardSignals(links: [pr(review: "REVIEW_REQUIRED"), pr(pr2URL, checks: .failure)]))?.text == "CI失敗")
        // Jira だけのリンクは待ち理由にしない
        let jira = LinkStatus(url: "https://x.atlassian.net/browse/A-1", fetchedAt: today, jira: JiraLinkState(key: "A-1", statusName: "進行中", category: .indeterminate))
        #expect(line(task(), CardSignals(links: [jira])) == nil)
    }

    @Test("レビューを頼まれている PR があれば自分の番")
    func reviewRequested() {
        #expect(line(task(updatedDaysAgo: 9), CardSignals(reviewRequested: true)) == WaitLine(text: "レビュー依頼あり", tone: .mine))
    }

    @Test("レビューを出した PR は「レビュー済み」で相手待ち。頼まれ直せば自分の番に戻る")
    func reviewed() {
        let review = task(updatedDaysAgo: 9, column: "review_req")
        #expect(line(review, CardSignals(reviewed: true)) == WaitLine(text: "レビュー済み", tone: .theirs))
        #expect(line(review, CardSignals(reviewRequested: true, reviewed: true)) == WaitLine(text: "レビュー依頼あり", tone: .mine))
        // 相手の PR の「レビュー待ち」より、自分が出したことを先に出す
        #expect(line(review, CardSignals(links: [pr(review: "REVIEW_REQUIRED")], reviewed: true)) == WaitLine(text: "レビュー済み", tone: .theirs))
        // 自分の番（CI の失敗など）は先に立つ
        #expect(line(review, CardSignals(links: [pr(checks: .failure)], reviewed: true)) == WaitLine(text: "CI失敗", tone: .mine))
    }

    @Test("完了・見送りの列のカードには出さない")
    func terminal() {
        let signals = CardSignals(links: [pr(checks: .failure)], terminal: true, conversations: [conversation(.waiting)])
        #expect(line(task(due: "2026-10-01", updatedDaysAgo: 30, sessionIDs: ["s1"]), signals) == nil)
    }

    @Test("作業項目の待ちの文が無ければ、種別の名詞句")
    func workItemKinds() {
        #expect(line(task(), CardSignals(workItems: [item(.review)])) == WaitLine(text: "レビュー待ち", tone: .quiet))
        #expect(line(task(), CardSignals(workItems: [item(.approval)])) == WaitLine(text: "承認・回答待ち", tone: .mine))
        #expect(line(task(), CardSignals(workItems: [item(.ci)]))?.text == "CI待ち")
        #expect(line(task(), CardSignals(workItems: [item(.deploy)]))?.text == "デプロイ待ち")
        #expect(line(task(), CardSignals(workItems: [item(.item)]))?.text == "別の項目待ち")
        #expect(line(task(), CardSignals(workItems: [item(.external)]))?.text == "外部待ち")
    }
}
