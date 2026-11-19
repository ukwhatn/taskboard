import Foundation
import Testing

@testable import TaskboardKit

@Suite("リンクの知らせの差分")
struct LinkNoticeTests {
    private let url = "https://github.com/o/r/pull/1"
    private let me = "Me-Dev"

    private func pr(
        _ state: PullRequestLinkState.State = .open, draft: Bool = false, head: String? = "a1", checks: CheckState? = nil, failed: [String] = [],
        mergeable: PullRequestSnapshot.Mergeable? = .mergeable, mergedBy: String? = nil, reviews: [PullRequestSnapshot.Review] = [],
        comments: [PullRequestSnapshot.Comment] = [], inline: [PullRequestSnapshot.Comment]? = []
    ) -> LinkSnapshot {
        .pullRequest(
            PullRequestSnapshot(
                state: state, isDraft: draft, headSHA: head, checks: checks, failedChecks: failed, mergeable: mergeable, mergedBy: mergedBy,
                reviews: reviews, comments: comments, inlineComments: inline))
    }

    private func diff(_ old: LinkSnapshot, _ new: LinkSnapshot) -> [LinkNotice] {
        LinkNotice.diff(url: url, old: old, new: new, viewerLogin: me)
    }

    private func kinds(_ old: LinkSnapshot, _ new: LinkSnapshot) -> [LinkNotice.Kind] { diff(old, new).map(\.kind) }

    @Test("同じ様子なら何も知らせない")
    func unchanged() {
        let snapshot = pr(checks: .success, reviews: [.init(id: "R1", author: "alice", state: "APPROVED", hasBody: false)])
        #expect(diff(snapshot, snapshot).isEmpty)
    }

    @Test("マージは誰がしたかを載せ、クローズ・開き直しと分ける")
    func stateChanges() {
        #expect(diff(pr(), pr(.merged, mergedBy: "bob")) == [LinkNotice(kind: .merged, url: url, actor: "bob")])
        #expect(kinds(pr(), pr(.closed)) == [.closed])
        #expect(kinds(pr(.closed), pr(.open)) == [.reopened])
    }

    @Test("ready になった・draft に戻った")
    func draft() {
        #expect(kinds(pr(draft: true), pr(draft: false)) == [.ready])
        #expect(kinds(pr(draft: false), pr(draft: true)) == [.draft])
    }

    @Test("新しいコミットは head の SHA が変わったとき。片方が取れていなければ知らせない")
    func commits() {
        #expect(diff(pr(head: "a1"), pr(head: "b2")) == [LinkNotice(kind: .commits, url: url, target: "b2")])
        #expect(diff(pr(head: nil), pr(head: "b2")).isEmpty)
    }

    @Test("CI はまとめた状態が実行中から終わりに移ったときだけ。落ちたチェックの名前を載せる")
    func checks() {
        #expect(diff(pr(checks: .pending), pr(checks: .failure, failed: ["lint", "test"])) == [
            LinkNotice(kind: .checksFailed, url: url, target: "a1", detail: "lint, test")
        ])
        #expect(kinds(pr(checks: .expected), pr(checks: .success)) == [.checksPassed])
        #expect(kinds(pr(checks: .error), pr(checks: .error)).isEmpty)
        #expect(kinds(pr(checks: .success), pr(checks: .pending)).isEmpty, "実行中に移ったことは知らせない")
        #expect(kinds(pr(checks: .pending), pr(checks: nil)).isEmpty)
        #expect(kinds(pr(checks: nil), pr(checks: .success)) == [.checksPassed], "取った間に走り終えていた")
    }

    @Test("同じ head の回し直しは、失敗 → 実行中 → 成功で 2 回知らせる")
    func rerunOnSameHead() {
        let steps = [pr(checks: .pending), pr(checks: .failure, failed: ["test"]), pr(checks: .pending), pr(checks: .success)]
        let notices = zip(steps, steps.dropFirst()).flatMap { diff($0, $1) }
        #expect(notices.map(\.kind) == [.checksFailed, .checksPassed])
        #expect(kinds(pr(checks: .success), pr(checks: .failure)) == [.checksFailed], "実行中を見ないまま落ちた回し直し")
    }

    @Test("head が変わったら、前と同じ結果でも新しい head の結果として知らせる")
    func checksOnNewHead() {
        #expect(diff(pr(head: "a1", checks: .success), pr(head: "b2", checks: .success)).map(\.kind) == [.commits, .checksPassed])
        #expect(diff(pr(head: "a1", checks: .success), pr(head: "b2", checks: .pending)).map(\.kind) == [.commits])
    }

    @Test("落ちたチェックの名前は 1 行・80 字まで")
    func failedNamesClipped() {
        let long = String(repeating: "あ", count: 100)
        let notice = diff(pr(checks: .pending), pr(checks: .failure, failed: ["a\nb", long, "c"])).first
        #expect(notice?.detail?.count == 80)
        #expect(notice?.detail?.hasPrefix("a b, あ") == true)
        #expect(notice?.detail?.contains("\n") == false)
    }

    @Test("conflict は CONFLICTING に移ったとき出て、MERGEABLE に移ったときだけ削除される。UNKNOWN は無視する")
    func conflicts() {
        #expect(kinds(pr(mergeable: .mergeable), pr(mergeable: .conflicting)) == [.conflict])
        #expect(kinds(pr(mergeable: .conflicting), pr(mergeable: .mergeable)) == [.conflictResolved])
        #expect(kinds(pr(mergeable: nil), pr(mergeable: .mergeable)).isEmpty, "前が分からないなら削除されたとは言わない")
        let unknown = PullRequestSnapshot.Mergeable?.none
        let carried = pr(mergeable: unknown).merged(over: pr(mergeable: .conflicting))
        #expect(kinds(pr(mergeable: .conflicting), carried).isEmpty, "UNKNOWN は前の値を持ち越す")
        #expect(kinds(carried, pr(mergeable: .conflicting)).isEmpty)
        #expect(kinds(pr(.open, mergeable: .mergeable), pr(.merged, mergeable: .conflicting)) == [.merged], "閉じた PR の conflict は知らせない")
    }

    @Test("レビュー：承認・修正の依頼・本文のあるコメント。自分のものと本文の無いコメント（行のコメントの入れ物）は除く")
    func reviews() {
        let new: [PullRequestSnapshot.Review] = [
            .init(id: "R1", author: "alice", state: "APPROVED", hasBody: false),
            .init(id: "R2", author: "carol", state: "CHANGES_REQUESTED", hasBody: true),
            .init(id: "R3", author: "dave", state: "COMMENTED", hasBody: true),
            .init(id: "R4", author: "erin", state: "COMMENTED", hasBody: false),
            .init(id: "R5", author: "me-dev", state: "APPROVED", hasBody: true),
            .init(id: "R6", author: "frank", state: "PENDING", hasBody: true),
            .init(id: "R7", author: "gina", state: "DISMISSED", hasBody: true),
        ]
        #expect(diff(pr(), pr(reviews: new)) == [
            LinkNotice(kind: .approved, url: url, actor: "alice", target: "R1"),
            LinkNotice(kind: .changesRequested, url: url, actor: "carol", target: "R2"),
            LinkNotice(kind: .reviewed, url: url, actor: "dave", target: "R3"),
        ])
        #expect(diff(pr(reviews: new), pr(reviews: new)).isEmpty)
    }

    @Test("会話のコメントは新しい id だけ。自分のものは大文字小文字を区別せずに除く")
    func comments() {
        let old: [PullRequestSnapshot.Comment] = [.init(id: "IC1", author: "alice", url: "\(url)#issuecomment-1")]
        let new = old + [
            .init(id: "IC2", author: "bob", url: "\(url)#issuecomment-2"), .init(id: "IC3", author: "ME-DEV", url: "\(url)#issuecomment-3"),
        ]
        #expect(diff(pr(comments: old), pr(comments: new)) == [
            LinkNotice(kind: .comment, url: url, actor: "bob", target: "IC2", targetURL: "\(url)#issuecomment-2")
        ])
    }

    @Test("行のコメントと返信。前より古い id（編集で戻ってきたもの）と、初めて取った回は知らせない")
    func inline() {
        let old: [PullRequestSnapshot.Comment] = [.init(id: "100", author: "alice", url: "\(url)#discussion_r100")]
        let fetched: [PullRequestSnapshot.Comment] = [
            .init(id: "90", author: "zed", url: "\(url)#discussion_r90"),
            .init(id: "101", author: "bob", url: "\(url)#discussion_r101"),
            .init(id: "102", author: "carol", url: "\(url)#discussion_r102", replyTo: "100"),
            .init(id: "103", author: "me-dev", url: "\(url)#discussion_r103", replyTo: "101"),
        ]
        let new = pr(inline: fetched).merged(over: pr(inline: old))
        #expect(diff(pr(inline: old), new) == [
            LinkNotice(kind: .inlineComment, url: url, actor: "bob", target: "101", targetURL: "\(url)#discussion_r101"),
            LinkNotice(kind: .inlineReply, url: url, actor: "carol", target: "102", targetURL: "\(url)#discussion_r102"),
        ])
        #expect(diff(pr(inline: nil), pr(inline: fetched)).isEmpty, "初めて取った回は元にするだけ")
        #expect(diff(new, pr(inline: nil).merged(over: new)).isEmpty, "取らなかった回は前のまま")
    }

    @Test("行のコメントは前の分と足し合わせ、新しい 100 件だけを持つ")
    func inlineMergeKeepsNewest() {
        let old = (1...80).map { PullRequestSnapshot.Comment(id: String($0), author: "a", url: nil) }
        let fetched = (60...130).map { PullRequestSnapshot.Comment(id: String($0), author: "b", url: nil) }
        guard case .pullRequest(let merged) = pr(inline: fetched).merged(over: pr(inline: old)) else { Issue.record("PR でない"); return }
        let ids = merged.inlineComments?.compactMap { Int($0.id) } ?? []
        #expect(ids.count == 100 && ids.min() == 31 && ids.max() == 130)
    }

    @Test("issue：クローズ（理由）・開き直し・新しいコメント")
    func issue() {
        func issue(_ state: String, reason: String? = nil, comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
            .issue(IssueSnapshot(state: state, stateReason: reason, comments: comments))
        }
        let issueURL = "https://github.com/o/r/issues/2"
        #expect(LinkNotice.diff(url: issueURL, old: issue("OPEN"), new: issue("CLOSED", reason: "NOT_PLANNED"), viewerLogin: me) == [
            LinkNotice(kind: .closed, url: issueURL, detail: "NOT_PLANNED")
        ])
        #expect(LinkNotice.diff(url: issueURL, old: issue("CLOSED"), new: issue("OPEN", reason: "REOPENED"), viewerLogin: me).map(\.kind) == [.reopened])
        let comment = PullRequestSnapshot.Comment(id: "IC9", author: "bob", url: "\(issueURL)#issuecomment-9")
        let mine = PullRequestSnapshot.Comment(id: "IC10", author: "me-dev", url: nil)
        #expect(LinkNotice.diff(url: issueURL, old: issue("OPEN"), new: issue("OPEN", comments: [comment, mine]), viewerLogin: me).map(\.kind) == [.comment])
    }

    @Test("PR と issue が入れ替わった様子は比べない")
    func mismatchedKinds() {
        #expect(LinkNotice.diff(url: url, old: .issue(IssueSnapshot(state: "OPEN")), new: pr(.merged), viewerLogin: me).isEmpty)
    }

    @Test("対応が必要なのは、CI の失敗・レビュー・コメント・conflict・マージ・クローズ・新しく出た issue・PR・タグに入った・Devin の動き全部")
    func needsAction() {
        let wakes: Set<LinkNotice.Kind> = [
            .checksFailed, .approved, .changesRequested, .reviewed, .comment, .inlineComment, .inlineReply, .conflict, .merged, .closed, .opened, .tagged,
            .devinWaiting, .devinPullRequest, .devinFinished, .devinExpired,
        ]
        for kind in LinkNotice.Kind.allCases {
            #expect(LinkNotice(kind: kind, url: url).needsAction == wakes.contains(kind), "\(kind)")
        }
    }

    @Test("同じ対象の状態の移りは新しい方だけを残し、レビューとコメントは全部残す")
    func collapse() {
        let other = "https://github.com/o/r/pull/2"
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let notices: [LinkNotice] = [
            LinkNotice(kind: .draft, url: url), LinkNotice(kind: .checksFailed, url: url, detail: "x"), LinkNotice(kind: .comment, url: url, target: "1"),
            LinkNotice(kind: .ready, url: url), LinkNotice(kind: .draft, url: other), LinkNotice(kind: .checksPassed, url: url),
            LinkNotice(kind: .comment, url: url, target: "2"),
        ]
        let records = notices.enumerated().map { TaskLinkNotice(id: Int64($0.offset + 1), taskNumber: 1, notice: $0.element, createdAt: at) }
        #expect(TaskLinkNotice.collapsed(records).map(\.id) == [3, 4, 5, 6, 7])
    }

    @Test("様子と知らせは JSON で読み戻せる")
    func roundTrip() throws {
        let snapshot = pr(
            checks: .failure, failed: ["t"], mergeable: .conflicting, reviews: [.init(id: "R", author: "a", state: "APPROVED", hasBody: true)],
            comments: [.init(id: "C", author: "b", url: "u")], inline: [.init(id: "1", author: "c", url: nil, replyTo: "0")])
        #expect(try JSONDecoder().decode(LinkSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        let notice = LinkNotice(kind: .inlineReply, url: url, actor: "c", target: "1", detail: nil, targetURL: "u")
        #expect(try JSONDecoder().decode(LinkNotice.self, from: JSONEncoder().encode(notice)) == notice)
    }
}
