import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// PR の一覧・詳細・リンクのチップ・会話の差分が同じ語と記号を出す（docs/ui-copy.md の用語表。PR の承認は「承認済み」）
@Suite struct PRPresentationTests {
    @Test("CI の印と語。実行中はどの画面も circle.dotted")
    func checks() {
        #expect(CheckState.success.symbol == "checkmark.circle.fill")
        #expect(CheckState.failure.symbol == "xmark.circle.fill")
        #expect(CheckState.pending.symbol == "circle.dotted")
        #expect(CheckState.expected.label == "CI実行中")
        #expect(CheckState.error.label == "CI失敗")
        #expect(CheckRunState.running.symbol == "circle.dotted")
        #expect(CheckRunState.timedOut.symbol == "xmark.circle.fill")
        #expect(CheckRunState.skipped.symbol == "minus.circle")
        #expect(CheckRunState.queued.label == "実行待ち")
    }

    @Test("レビューの判定。判定があればそれ、無ければ最新のレビューの承認・修正依頼・コメントの件数")
    func reviewBadge() {
        #expect(ReviewBadge.describe(decision: .approved, reviews: [])?.0 == "承認済み")
        #expect(ReviewBadge.describe(decision: .changesRequested, reviews: [])?.0 == "修正依頼")
        #expect(ReviewBadge.describe(decision: .reviewRequired, reviews: [.approved])?.0 == "レビュー待ち")
        #expect(ReviewBadge.describe(decision: nil, reviews: [.commented, .approved])?.0 == "承認済み")
        #expect(ReviewBadge.describe(decision: nil, reviews: [.commented, .changesRequested])?.0 == "修正依頼")
        #expect(ReviewBadge.describe(decision: .other, reviews: [.commented, .commented])?.0 == "コメント2件")
        #expect(ReviewBadge.describe(decision: nil, reviews: []) == nil)
        #expect(PRReviewState.approved.symbol == "person.fill.checkmark")
        #expect(PRReviewState.commented.symbol == nil)
    }

    @Test("PR の状態の語と印。詳細は GitHub の state を読み、知らない値は Open。Draft は開いている PR だけ")
    func pullRequestState() {
        typealias State = PullRequestLinkState.State
        #expect(State.badge(State(github: "MERGED"), isDraft: true).0 == "マージ済み")
        #expect(State.badge(State(github: "CLOSED"), isDraft: false).0 == "クローズ済み")
        #expect(State.badge(State(github: "OPEN"), isDraft: true).0 == "Draft")
        #expect(State.badge(State(github: "OPEN"), isDraft: false).0 == "Open")
        #expect(State(github: "UNKNOWN") == .open)
        #expect(State.merged.symbol == "arrow.triangle.merge")
        #expect(State.closed.symbol == "xmark.circle")
        #expect(State.open.symbol == "arrow.triangle.pull")
    }

    @Test("変更の印は A・D・R・M。GitHub の複製も会話の差分の複製も A")
    func fileChanges() {
        #expect(FileChangeKind(github: "COPIED").mark == "A")
        #expect(FileChangeKind(github: "COPIED").name == "追加")
        #expect(FileChangeKind(.copied).mark == "A")
        #expect(FileChangeKind(github: "RENAMED").name == "名前変更")
        #expect(FileChangeKind(.typeChanged).mark == "M")
    }
}
