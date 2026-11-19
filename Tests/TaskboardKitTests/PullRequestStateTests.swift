import Foundation
import Testing

@testable import TaskboardKit

@Suite("GitHub の PR の文字列（レビュー・変更の種類・チェック）の読み方")
struct PullRequestStateTests {
    @Test("レビューの判定と状態。知らない値は other")
    func reviewStates() {
        let cases: [(String, PRReviewState)] = [
            ("APPROVED", .approved), ("CHANGES_REQUESTED", .changesRequested), ("REVIEW_REQUIRED", .reviewRequired), ("COMMENTED", .commented),
            ("DISMISSED", .dismissed), ("PENDING", .pending), ("", .other), ("approved", .other), ("NEW_STATE", .other),
        ]
        for (value, state) in cases { #expect(PRReviewState(github: value) == state, "\(value)") }
    }

    @Test("変更の種類は A・D・R・M の 4 つ。複製と未追跡は追加、型の変更と衝突と知らない値は変更")
    func fileChanges() {
        let github: [(String, FileChangeKind)] = [
            ("ADDED", .added), ("COPIED", .added), ("DELETED", .deleted), ("RENAMED", .renamed), ("MODIFIED", .modified), ("CHANGED", .modified), ("X", .modified),
        ]
        for (value, kind) in github { #expect(FileChangeKind(github: value) == kind, "\(value)") }
        let local: [(ConversationDiffFile.Change, FileChangeKind)] = [
            (.added, .added), (.untracked, .added), (.copied, .added), (.deleted, .deleted), (.renamed, .renamed), (.modified, .modified),
            (.typeChanged, .modified), (.unmerged, .modified),
        ]
        for (change, kind) in local { #expect(FileChangeKind(change) == kind, "\(change)") }
    }

    @Test("チェック 1 件の状態と、PR 全体の CI の状態への寄せ方。取り消し・スキップ・中立・古い結果は数えない")
    func checkRuns() {
        let cases: [(String, CheckRunState, CheckState?)] = [
            ("SUCCESS", .success, .success), ("FAILURE", .failure, .failure), ("ERROR", .failure, .failure), ("TIMED_OUT", .timedOut, .failure),
            ("STARTUP_FAILURE", .startupFailure, .failure), ("ACTION_REQUIRED", .actionRequired, .failure), ("CANCELLED", .cancelled, nil),
            ("SKIPPED", .skipped, nil), ("NEUTRAL", .neutral, nil), ("STALE", .stale, nil), ("QUEUED", .queued, .pending), ("WAITING", .queued, .pending),
            ("REQUESTED", .queued, .pending), ("PENDING", .queued, .pending), ("EXPECTED", .queued, .pending), ("IN_PROGRESS", .running, .pending),
            ("", .running, .pending),
        ]
        for (value, state, rollup) in cases {
            #expect(CheckRunState(github: value) == state, "\(value)")
            #expect(state.rollup == rollup, "\(value)")
        }
    }
}
