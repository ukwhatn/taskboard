import Foundation
import Testing

@testable import TaskboardKit

@Suite("タスクのリンクの並び")
struct LinkOrderTests {
    private func link(_ n: Int64, _ kind: TaskLink.Kind = .githubPR) -> TaskLink {
        TaskLink(id: n, url: "https://example.com/\(n)", kind: kind, addedAt: Date(timeIntervalSince1970: 0))
    }

    private func status(_ n: Int64, pr: PullRequestLinkState.State? = nil, jira: JiraLinkState.Category? = nil, devin: String? = nil) -> LinkStatus {
        LinkStatus(
            url: "https://example.com/\(n)", fetchedAt: Date(timeIntervalSince1970: 0), pullRequest: pr.map { PullRequestLinkState(state: $0) },
            jira: jira.map { JiraLinkState(key: "A-\(n)", statusName: "x", category: $0) }, devin: devin.map { DevinLinkState(status: $0) })
    }

    @Test("マージ済み・クローズの PR、完了の Jira、終了・期限切れの Devin は後ろへ。それぞれの中は足した順のまま")
    func settledLast() {
        let links = (1...8).map { link(Int64($0)) }
        let statuses = [
            status(1, pr: .merged), status(2, pr: .open), status(3, pr: .closed), status(4, jira: .done), status(5, jira: .indeterminate),
            status(6, devin: "finished"), status(7, devin: "expired"),
        ]
        let order = TaskLink.ordered(links, statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.url, $0) }))
        #expect(order.active.map(\.id) == [2, 5, 8])
        #expect(order.settled.map(\.id) == [1, 3, 4, 6, 7])
    }

    @Test("状態が取れていないリンクは終わっていないとみなす")
    func unknownIsActive() {
        let order = TaskLink.ordered([link(1), link(2, .other)], statuses: [:])
        #expect(order.active.map(\.id) == [1, 2])
        #expect(order.settled.isEmpty)
    }

    @Test("リンクが無ければどちらも空")
    func empty() {
        let order = TaskLink.ordered([], statuses: [:])
        #expect(order.active.isEmpty && order.settled.isEmpty)
    }
}
