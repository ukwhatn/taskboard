import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 使っていないworktreeの削除のシート（読み込み中・一覧・選んだ状態・結果）。Mac の幅（560）で、外観を変えて描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct WorktreeCleanupSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    static let worktrees: [WorktreeInfo] = [
        WorktreeInfo(
            path: "/Users/me/.herdr/worktrees/taskboard/feature-worktree-clean", repo: "/Users/me/dev/taskboard", branch: "feature/worktree-clean",
            base: "origin/develop", hasWorkspace: true),
        WorktreeInfo(
            path: "/Users/me/.herdr/worktrees/taskboard/fix-login-redirect-with-a-rather-long-branch-name", repo: "/Users/me/dev/taskboard",
            branch: "fix/login-redirect-with-a-rather-long-branch-name", base: "origin/develop"),
        WorktreeInfo(
            path: "/Users/me/.herdr/worktrees/taskboard/feature-screens", repo: "/Users/me/dev/taskboard", branch: "feature/screens", base: "origin/develop",
            users: [WorktreeUser(kind: .pane, id: "w1:p1"), WorktreeUser(kind: .conversation, id: "c1", title: "画面の整理")],
            blockers: [WorktreeBlocker(.inUse, count: 2), WorktreeBlocker(.uncommitted, count: 3), WorktreeBlocker(.untracked, count: 1)]),
        WorktreeInfo(
            path: "/Users/me/.herdr/worktrees/taskboard/feature-sidebar", repo: "/Users/me/dev/taskboard", branch: "feature/sidebar", base: "origin/develop",
            blockers: [WorktreeBlocker(.unpushed, count: 2), WorktreeBlocker(.unmerged, count: 4)]),
        WorktreeInfo(
            path: "/Users/me/dev/taskboard", repo: "/Users/me/dev/taskboard", branch: "main", blockers: [WorktreeBlocker(.main)]),
        WorktreeInfo(
            path: "/Users/me/.herdr/worktrees/docs/old-experiment", repo: "/Users/me/dev/docs", branch: "old-experiment",
            blockers: [WorktreeBlocker(.noBase), WorktreeBlocker(.locked)]),
        WorktreeInfo(path: "/Users/me/.herdr/worktrees/docs/detached", repo: "/Users/me/dev/docs", blockers: [WorktreeBlocker(.noBranch)]),
    ]

    static let results: [WorktreeRemoveResult] = [
        WorktreeRemoveResult(path: worktrees[0].path, outcome: .removed, branch: "feature/worktree-clean", branchDeleted: true),
        WorktreeRemoveResult(
            path: worktrees[1].path, outcome: .removed, branch: "fix/login-redirect-with-a-rather-long-branch-name",
            message: "error: the branch 'fix/login-redirect-with-a-rather-long-branch-name' is not fully merged"),
        WorktreeRemoveResult(path: worktrees[3].path, outcome: .refused, blockers: [WorktreeBlocker(.untracked, count: 1)], branch: "feature/sidebar"),
        WorktreeRemoveResult(
            path: worktrees[5].path, outcome: .failed, branch: "old-experiment", message: "fatal: '/Users/me/.herdr/worktrees/docs/old-experiment' contains modified or untracked files, use --force to delete it"),
    ]

    private func render(
        _ phase: WorktreeCleanupPhase, selection: Set<String> = [], error: String? = nil, name: String, height: CGFloat = 760, testName: String = #function
    ) throws {
        let (width, appearance) = try Matrix.parse(name)
        let view = WorktreeCleanupView(phase: phase, machineName: "このMac", selection: .constant(selection), error: error).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: height), variant: appearance), named: name, testName: testName)
    }

    @Test("読み込み中", arguments: Matrix.cases([560]))
    func loading(name: String) throws {
        try render(.loading, name: name, height: 260)
    }

    @Test("一覧（初めは何も選ばない。消せないものは理由を出して選べない）", arguments: Matrix.cases([560]))
    func listed(name: String) throws {
        try render(.loaded(Self.worktrees), name: name)
    }

    @Test("一覧（消せる 2 件を選んだ）", arguments: Matrix.cases([560]))
    func selected(name: String) throws {
        try render(.loaded(Self.worktrees), selection: [Self.worktrees[0].path, Self.worktrees[1].path], name: name)
    }

    @Test("一覧が空", arguments: Matrix.cases([560]))
    func empty(name: String) throws {
        try render(.loaded([]), name: name, height: 260)
    }

    @Test("一覧を読めなかった", arguments: Matrix.cases([560]))
    func loadFailed(name: String) throws {
        let failure = UserFacingError("worktreeを読み込めませんでした", cause: String(localized: "ネットワークにつながっていません"), remedy: UserFacingError.checkNetwork)
        try render(.failed, error: failure.text, name: name, height: 280)
    }

    @Test("削除の結果（消した・ブランチが残った・断られた・失敗）", arguments: Matrix.cases([560]))
    func finished(name: String) throws {
        try render(.finished(Self.results), name: name)
    }
}
