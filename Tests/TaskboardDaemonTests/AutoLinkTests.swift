import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-autolink")
private let pr = "https://github.com/o/r/pull/41"

private func open(comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .open, headSHA: "a1", mergeable: .mergeable, comments: comments, inlineComments: []))
}

private func merged(comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .merged, headSHA: "a1", mergeable: .mergeable, mergedBy: "bob", comments: comments, inlineComments: []))
}

private func comment(_ id: Int) -> PullRequestSnapshot.Comment {
    .init(id: "IC\(id)", author: "bob", url: "\(pr)#issuecomment-\(id)")
}

@Suite("PR をタスクへ自動でリンクする")
struct AutoLinkTests {
    private func world() throws -> (Store, BoardTask, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let first = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t1"))
        let second = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t2"))
        return (store, first, second)
    }

    @Test("どのタスクにも無い URL だけを足す。同じタスクにあれば足さず、ほかのタスクにあればそのタスクを返す")
    func linksOnlyUnlinked() throws {
        let (store, first, second) = try world()
        #expect(try store.linkIfUnlinked(task: first.number, url: pr) == .linked(task: first.number))
        #expect(try store.task(number: first.number)?.links.map(\.url) == [pr])
        #expect(try store.linkIfUnlinked(task: first.number, url: pr) == .alreadyLinked(task: first.number))
        #expect(try store.linkIfUnlinked(task: second.number, url: pr) == .linkedElsewhere(task: first.number))
        #expect(try store.task(number: second.number)?.links.isEmpty == true)
        #expect(throws: StoreError.taskNotFound(999)) { try store.linkIfUnlinked(task: 999, url: pr) }
    }

    @Test("リンクの知らせで届く PR の監視は作らず、指示をリンクのメモに残す。ほかのタスクにリンク済みなら何もしない")
    func linkInsteadOfWatch() throws {
        let (store, first, second) = try world()
        let request = WatchCreateRequest(url: pr, taskNumber: first.number, prompt: "マージされたら worktree を片付ける")
        #expect(try store.linkInsteadOfWatch(request, task: first.number) == .linked(task: first.number))
        #expect(try store.task(number: first.number)?.links.map(\.note) == ["マージされたら worktree を片付ける"])
        #expect(try store.linkInsteadOfWatch(WatchCreateRequest(url: pr, taskNumber: first.number, prompt: "CI が落ちたら直す"), task: first.number) == .alreadyLinked(task: first.number))
        #expect(try store.task(number: first.number)?.links.map(\.note) == ["CI が落ちたら直す"])
        #expect(try store.linkInsteadOfWatch(WatchCreateRequest(url: pr, taskNumber: first.number), task: first.number) == .alreadyLinked(task: first.number))
        #expect(try store.task(number: first.number)?.links.map(\.note) == ["CI が落ちたら直す"])
        #expect(try store.linkInsteadOfWatch(WatchCreateRequest(url: pr, taskNumber: second.number, prompt: "x"), task: second.number) == nil)
        #expect(try store.task(number: second.number)?.links.isEmpty == true)
        #expect(try store.watches().isEmpty)
    }

    @Test("リンクの知らせで足りるのは、絞り込み・タグ・1 回だけ・期限の無い PR の監視で、リンクを止めていないものだけ")
    func coveredByLinkNotices() {
        #expect(WatchCreateRequest(url: pr, prompt: "x").coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: pr, events: [.merged]).coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: pr, tagPattern: "*-prod").coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: pr, once: true).coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: pr, expiresAt: Date()).coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: pr, link: false).coveredByLinkNotices)
        #expect(!WatchCreateRequest(url: "https://github.com/o/r/issues/41").coveredByLinkNotices)
        #expect(!WatchCreateRequest(repo: "o/r").coveredByLinkNotices)
    }

    @Test("リンクの知らせに、そのリンクのメモを作成時の指示として載せる")
    func noticeCarriesLinkNote() {
        let notice = TaskLinkNotice(id: 1, taskNumber: 3, notice: LinkNotice(kind: .merged, url: pr, actor: "bob"), createdAt: Date())
        let text = LinkNotices.text(task: 3, notices: [notice], omitted: 0, notes: [pr: "マージされたら片付ける"])
        #expect(text.hasSuffix("動き:\n- r#41: マージされた（bob） \(pr)\n作成時の指示:\n- r#41: マージされたら片付ける"))
        #expect(!LinkNotices.text(task: 3, notices: [notice], omitted: 0, notes: [:]).contains("作成時の指示:"))
    }

    @Test("同じタスクに届く見張りが受ける動きは、リンクの知らせにしない（見張りの知らせ 1 通にする）。見張りが受けない動きと、ほかのタスクのリンクは今までどおり")
    func watchCoversLinkNotices() throws {
        let (store, first, second) = try world()
        _ = try store.linkIfUnlinked(task: first.number, url: pr)
        _ = try store.updateTask(number: second.number, TaskUpdateRequest(addLinks: [pr]))
        let watch = try store.createWatch(WatchCreateRequest(url: pr, events: [.merged], taskNumber: first.number)).watch.watchID
        let tasks: Set<Int> = [first.number, second.number]
        for snapshot in [open(), merged(comments: [comment(1)])] {
            try store.recordLinkSnapshot(url: pr, snapshot: snapshot, viewerLogin: "me", tasks: tasks, at: Date())
            try store.recordWatchSnapshot(url: pr, snapshot: snapshot, viewerLogin: "me", at: Date())
        }
        #expect(try store.undeliveredLinkNotices(task: first.number).map(\.notice.kind) == [.comment])
        #expect(Set(try store.undeliveredLinkNotices(task: second.number).map(\.notice.kind)) == [.merged, .comment])
        #expect(try store.undeliveredWatchEvents(watch: watch).map(\.notice.kind) == [.merged])
    }

    @Test("会話宛ての見張りは、その会話が結ばれたタスクのリンクの知らせを肩代わりする")
    func conversationWatchCoversItsTask() throws {
        let (store, first, _) = try world()
        _ = try store.linkIfUnlinked(task: first.number, url: pr)
        let conversation = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", model: "haiku", runner: .none))
        _ = try store.createWatch(WatchCreateRequest(url: pr, conversationID: conversation.id))
        for snapshot in [open(), open(comments: [comment(1)])] {
            try store.recordLinkSnapshot(url: pr, snapshot: snapshot, viewerLogin: "me", tasks: [first.number], at: Date())
            try store.recordWatchSnapshot(url: pr, snapshot: snapshot, viewerLogin: "me", at: Date())
        }
        #expect(try store.undeliveredLinkNotices(task: first.number).isEmpty)
    }

    @Test("まだ元の様子を取っていない見張りは、リンクの知らせを肩代わりしない（その回の動きを見張りは知らせないため）")
    func freshWatchDoesNotCover() throws {
        let (store, first, _) = try world()
        _ = try store.linkIfUnlinked(task: first.number, url: pr)
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [first.number], at: Date())
        _ = try store.createWatch(WatchCreateRequest(url: pr, taskNumber: first.number))
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [first.number], at: Date())
        #expect(try store.undeliveredLinkNotices(task: first.number).map(\.notice.kind) == [.comment])
    }
}
