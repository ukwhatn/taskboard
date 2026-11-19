import Foundation
import Testing

@testable import TaskboardKit

@Suite("使っていないworktreeの応答の型")
struct WorktreeWireTests {
    @Test("一覧の応答を読み、理由が空のものだけ消せる。知らない理由は unknown に読み、消せない側に倒す")
    func decodesList() throws {
        let json = """
            {"worktrees":[
              {"path":"/w/a","repo":"/r","branch":"a","base":"origin/develop","users":[],"blockers":[],"hasWorkspace":true},
              {"path":"/w/b","repo":"/r","users":[{"kind":"pane","id":"w1:p1","title":"作業"}],
               "blockers":[{"kind":"inUse","count":1},{"kind":"someNewReason"}],"hasWorkspace":false}
            ]}
            """
        let response = try WireJSON.decoder().decode(WorktreeListResponse.self, from: Data(json.utf8))
        let (a, b) = (response.worktrees[0], response.worktrees[1])
        #expect(a.removable)
        #expect(a.base == "origin/develop")
        #expect(a.hasWorkspace)
        #expect(!b.removable)
        #expect(b.branch == nil)
        #expect(b.users == [WorktreeUser(kind: .pane, id: "w1:p1", title: "作業")])
        #expect(b.blockers == [WorktreeBlocker(.inUse, count: 1), WorktreeBlocker(.unknown)])
    }

    @Test("削除の要求と結果は往復しても変わらない")
    func roundTrips() throws {
        let request = WorktreeRemoveRequest(paths: ["/w/a", "/w/日本語"])
        #expect(try WireJSON.decoder().decode(WorktreeRemoveRequest.self, from: WireJSON.encoder().encode(request)) == request)
        let response = WorktreeRemoveResponse(results: [
            WorktreeRemoveResult(path: "/w/a", outcome: .removed, branch: "a", branchDeleted: true),
            WorktreeRemoveResult(path: "/w/b", outcome: .refused, blockers: [WorktreeBlocker(.unmerged, count: 2)], branch: "b"),
            WorktreeRemoveResult(path: "/w/c", outcome: .failed, message: "fatal: contains modified or untracked files"),
        ])
        #expect(try WireJSON.decoder().decode(WorktreeRemoveResponse.self, from: WireJSON.encoder().encode(response)) == response)
    }
}
