import Foundation
import GRDB
import TaskboardKit
import Testing
import TestSupport

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-link")
private let pr = "https://github.com/o/r/pull/1"
private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

extension Store {
    /// リンクの前の様子（本番は `recordLinkSnapshot` が SQL で読み書きするので、読み返すのはテストだけ）
    fileprivate func linkSnapshot(taskLinkID: Int64) throws -> LinkSnapshot? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT snapshot FROM taskLinkSnapshot WHERE taskLinkId = ?", arguments: [taskLinkID])
                .map { try JSONDecoder().decode(LinkSnapshot.self, from: Data($0.utf8)) }
        }
    }
}

private func open(checks: CheckState? = nil, reviews: [PullRequestSnapshot.Review] = [], comments: [PullRequestSnapshot.Comment] = []) -> LinkSnapshot {
    .pullRequest(PullRequestSnapshot(state: .open, headSHA: "a1", checks: checks, mergeable: .mergeable, reviews: reviews, comments: comments, inlineComments: []))
}

private func comment(_ id: Int, by author: String = "bob") -> PullRequestSnapshot.Comment {
    .init(id: "IC\(id)", author: author, url: "\(pr)#issuecomment-\(id)")
}

@Suite("リンクの知らせの記録")
struct LinkNoticeStoreTests {
    private func world() throws -> (Store, Board) {
        let store = try Store(inMemory: machine)
        return (store, try store.createBoard(name: "a", columns: nil))
    }

    private func task(_ store: Store, _ board: Board, links: [String] = [pr]) throws -> BoardTask {
        try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "t", links: links))
    }

    @Test("初めて見たリンクは元を記録するだけ。次からは差を知らせにし、様子の書き換えと一緒に入れる")
    func recordsTogether() throws {
        let (store, board) = try world()
        let task = try task(store, board)
        let link = try #require(task.links.first)
        #expect(try store.recordLinkSnapshot(url: pr, snapshot: open(checks: .pending), viewerLogin: "me", tasks: [task.number], at: t0).isEmpty)
        #expect(try store.linkSnapshot(taskLinkID: link.id) == open(checks: .pending))
        #expect(try store.undeliveredLinkNotices(task: task.number).isEmpty)

        let touched = try store.recordLinkSnapshot(url: pr, snapshot: open(checks: .failure), viewerLogin: "me", tasks: [task.number], at: t0 + 60)
        #expect(touched == [task.number])
        #expect(try store.linkSnapshot(taskLinkID: link.id) == open(checks: .failure))
        let notices = try store.undeliveredLinkNotices(task: task.number)
        #expect(notices.map(\.notice.kind) == [.checksFailed] && notices.first?.createdAt == t0 + 60)
        #expect(try store.recordLinkSnapshot(url: pr, snapshot: open(checks: .failure), viewerLogin: "me", tasks: [task.number], at: t0 + 120).isEmpty)
    }

    @Test("同じ URL を 2 つのタスクに結ぶと、どちらのリンクも自分の前の様子と比べて知らせを受ける")
    func sameURLTwoTasks() throws {
        let (store, board) = try world()
        let first = try task(store, board)
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [first.number], at: t0)
        let second = try task(store, board)
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [first.number, second.number], at: t0 + 60)
        #expect(try store.undeliveredLinkNotices(task: first.number).map(\.notice.kind) == [.comment])
        #expect(try store.undeliveredLinkNotices(task: second.number).isEmpty, "後から結んだ方は、そこで元を記録しただけ")

        try store.recordLinkSnapshot(
            url: pr, snapshot: open(comments: [comment(1), comment(2)]), viewerLogin: "me", tasks: [first.number, second.number], at: t0 + 120)
        #expect(try store.undeliveredLinkNotices(task: first.number).map(\.notice.target) == ["IC1", "IC2"])
        #expect(try store.undeliveredLinkNotices(task: second.number).map(\.notice.target) == ["IC2"])
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1), comment(2), comment(3)]), viewerLogin: "me", tasks: [first.number], at: t0 + 180)
        #expect(try store.undeliveredLinkNotices(task: second.number).count == 1, "見ていないタスク（終端の列）のリンクは比べない")
    }

    @Test("同じタスクに同じ URL を 2 本結んでも、知らせは 1 回")
    func duplicateLinkInTask() throws {
        let (store, board) = try world()
        let task = try task(store, board, links: [pr, pr])
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [task.number], at: t0)
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [task.number], at: t0 + 60)
        #expect(try store.undeliveredLinkNotices(task: task.number).count == 1)
    }

    @Test("リンクを外すと前の様子も消え、結び直したら初めて見たのと同じ扱い")
    func unlinkAndRelink() throws {
        let (store, board) = try world()
        let task = try task(store, board)
        let link = try #require(task.links.first)
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [task.number], at: t0)
        _ = try store.updateTask(number: task.number, TaskUpdateRequest(removeLinkIDs: [link.id]))
        #expect(try store.linkSnapshot(taskLinkID: link.id) == nil)
        let relinked = try store.updateTask(number: task.number, TaskUpdateRequest(addLinks: [pr]))
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [task.number], at: t0 + 60)
        #expect(try store.undeliveredLinkNotices(task: task.number).isEmpty)
        #expect(try store.linkSnapshot(taskLinkID: try #require(relinked.links.first).id) == open(comments: [comment(1)]))
    }

    @Test("届けた知らせは 7 日で削除し、届けていないものは残す。読む API は届けていない数と新しい 20 件")
    func retentionAndList() throws {
        let (store, board) = try world()
        let task = try task(store, board)
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [task.number], at: t0)
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: (1...25).map { comment($0) }), viewerLogin: "me", tasks: [task.number], at: t0 + 60)
        let all = try store.undeliveredLinkNotices(task: task.number)
        try store.markLinkNoticesDelivered(ids: Array(all.prefix(5).map(\.id)), at: t0 + 120)
        let list = try store.linkNotices(task: task.number)
        #expect(list.undelivered == 20 && list.notices.count == 20)
        #expect(list.notices.first?.notice.target == "IC25", "新しい順")

        try store.purgeDeliveredLinkNotices(at: t0 + 120 + Store.finishedRowRetention - 1)
        #expect(try store.linkNotices(task: task.number, limit: 100).notices.count == 25)
        try store.purgeDeliveredLinkNotices(at: t0 + 120 + Store.finishedRowRetention + 1)
        #expect(try store.linkNotices(task: task.number, limit: 100).notices.count == 20, "届けた 5 件だけが削除される")
        #expect(try store.tasksWithUndeliveredLinkNotices() == [task.number])
    }

    @Test("タスクを削除すると知らせも削除される")
    func cascadesWithTask() throws {
        let (store, board) = try world()
        let task = try task(store, board)
        try store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [task.number], at: t0)
        try store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [task.number], at: t0 + 60)
        try store.deleteTask(number: task.number)
        #expect(try store.tasksWithUndeliveredLinkNotices().isEmpty)
    }

    @Test("v20 の DB に v21 を当てると、前のリンクは様子なしで読め、知らせを引く index ができる。backup の確認は v21 の表を見る")
    func migrationV21() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v21-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v20 feedback and session lookup indexes")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO board (id, name, position, createdAt) VALUES ('b1', 'default', 0, ?)", arguments: [t0])
                try db.execute(
                    sql: "INSERT INTO task (number, boardId, columnId, title, note, createdAt, updatedAt) VALUES (7, 'b1', 'working', 't', '', ?, ?)",
                    arguments: [t0, t0])
                try db.execute(sql: "INSERT INTO taskLink (id, taskNumber, url, kind, note, addedAt) VALUES (3, 7, ?, 'github_pr', '', ?)", arguments: [pr, t0])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")
        #expect(try store.linkSnapshot(taskLinkID: 3) == nil)
        #expect(try store.task(number: 7)?.links.map(\.url) == [pr])
        let plan = try store.database.read { db in
            try String.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN SELECT * FROM taskLinkNotice WHERE taskNumber = 7 AND deliveredAt IS NULL ORDER BY createdAt, id",
                adapter: ColumnMapping(["detail": "detail"])
            ).joined(separator: " / ")
        }
        #expect(plan.contains("USING INDEX taskLinkNotice_task"), "\(plan)")
        let backup = try store.backup(label: "v21")
        try store.close()
        #expect(try Store.verify(backupAt: backup).tasks == 1)
        let broken = try DatabaseQueue(path: backup.path)
        try broken.write { db in try db.execute(sql: "DROP TABLE taskLinkNotice") }
        try broken.close()
        #expect(throws: StoreError.missingTable("taskLinkNotice")) { try Store.verify(backupAt: backup) }
    }
}

/// gh の代わり。`pr view`・`issue view` は `pr-<番号>.json`・`issue-<番号>.json`、`auth status` は `status.json`（既定のアカウントが Me-Dev）、
/// `api … pulls/<番号>/comments` は `inline-<番号>.json`、`api graphql`（repo の見張りの search）は `graphql-<owner>-<name>.json`、
/// タグの一覧の `api graphql` は `tags-<owner>-<name>.json`、`api … compare/<base>...<head>` は `compare-<base>...<head>.txt`（`--jq .status` の出力）を返す。`ratelimit` があれば auth 以外を rate limit で断る。
/// `auth token --user <login>` は `token-<login>` があるときだけ通る。呼ばれた引数を、auth は `auth.log`、ほかは `calls.log` に書く。
/// `slow` があれば、それを消して、読んだ中身を 1 秒後に返す（取っている間に GitHub の様子が変わった）
struct FakeGitHub {
    static let shared = SharedExecutable(
        name: "tb-test-link-gh-v3.sh",
        script: """
            #!/bin/sh
            D="$(dirname "$0")"
            if [ "$1" = auth ]; then echo "$*" >> "$D/auth.log"; [ "$2" = status ] && [ -f "$D/status.json" ] && { cat "$D/status.json"; exit 0; }; [ "$2" = token ] && [ -f "$D/token-$6" ] && { echo ghp_fake; exit 0; }; exit 1; fi
            echo "$*" >> "$D/calls.log"
            [ -f "$D/ratelimit" ] && { echo "HTTP 403: API rate limit exceeded for user ID 1." >&2; exit 1; }
            for a in "$@"; do
              case "$a" in
                https://*) n="${a##*/}" ;;
                *pulls/*/comments*) p="${a##*pulls/}"; n="${p%%/*}" ;;
                q=repo:*) r="${a#q=repo:}"; r="$(printf %s "${r%% *}" | tr / -)" ;;
                owner=*) o="${a#owner=}" ;;
                name=*) nm="${a#name=}" ;;
                */compare/*) p="${a##*/compare/}"; c="${p%%\\?*}" ;;
              esac
            done
            case "$*" in
              "api graphql "*refPrefix*) f="$D/tags-$o-$nm.json" ;;
              "api graphql "*) f="$D/graphql-$r.json" ;;
              *"/compare/"*) f="$D/compare-$c.txt" ;;
              "pr view "*) f="$D/pr-$n.json" ;;
              "issue view "*) f="$D/issue-$n.json" ;;
              *pulls/*/comments*) f="$D/inline-$n.json" ;;
              *) exit 2 ;;
            esac
            [ -f "$f" ] || { echo "not found" >&2; exit 1; }
            body="$(cat "$f")"
            [ -f "$D/slow" ] && { rm -f "$D/slow"; touch "$D/slow-started"; sleep 1; }
            printf '%s\n' "$body"

            """)

    let directory: URL
    let executable: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fakegh-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = try Self.shared.link(in: directory, as: "gh")
        try write("status.json", #"{"hosts":{"github.com":[{"login":"Me-Dev","state":"success","active":true},{"login":"other","state":"success","active":false}]}}"#)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }

    var calls: [String] { log("calls.log") }
    var authCalls: [String] { log("auth.log") }

    private func log(_ name: String) -> [String] {
        ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// `gh pr view --json` の形の PR
    func pullRequest(
        _ number: Int, state: String = "OPEN", head: String = "a1", checks: String = "[]", mergeable: String = "MERGEABLE", reviews: String = "[]",
        comments: String = "[]", mergedBy: String = "null", mergeCommit: String? = nil
    ) throws {
        let commit = mergeCommit.map { #"{"oid":"\#($0)"}"# } ?? "null"
        try write(
            "pr-\(number).json",
            #"{"state":"\#(state)","isDraft":false,"reviewDecision":"","statusCheckRollup":\#(checks),"headRefOid":"\#(head)","mergeable":"\#(mergeable)","mergedBy":\#(mergedBy),"mergeCommit":\#(commit),"reviews":\#(reviews),"comments":\#(comments)}"#
        )
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Suite("リンクの知らせ（偽物の gh）", .serialized)
struct LinkNoticeSyncTests {
    private struct World {
        let gh: FakeGitHub
        let store: Store
        let state: DaemonState
        let sync: GitHubSync
        let clock: Clock
        let board: Board
    }

    private func world() async throws -> World {
        let gh = try FakeGitHub()
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let clock = Clock()
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable, now: { clock.now })
        let sync = GitHubSync(store: store, state: state, cli: cli, now: { clock.now })
        return World(gh: gh, store: store, state: state, sync: sync, clock: clock, board: try store.createBoard(name: "a", columns: nil))
    }

    @Test("PR の動きを知らせにする。自分のレビューとコメントは除き、行のコメントは REST で前に取った時刻から取る")
    func recordsPullRequestNotices() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1, checks: #"[{"__typename":"CheckRun","name":"test","workflowName":"CI","status":"IN_PROGRESS","conclusion":"","startedAt":"2026-10-19T00:00:00Z"}]"#)
        try world.gh.write("inline-1.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        let box = NoticeBox()
        await world.sync.onNotices { numbers in await box.add(numbers) }

        try await world.sync.sweep()
        #expect(try world.store.undeliveredLinkNotices(task: task.number).isEmpty, "初めて取った回は元にするだけ")

        try world.gh.pullRequest(
            1, head: "b2",
            checks: #"[{"__typename":"CheckRun","name":"test","workflowName":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-10-19T00:05:00Z"}]"#,
            reviews: #"[{"id":"R1","author":{"login":"alice"},"state":"CHANGES_REQUESTED","body":"直して"},{"id":"R2","author":{"login":"me-dev"},"state":"COMMENTED","body":"自分"}]"#,
            comments: #"[{"id":"IC1","author":{"login":"ME-DEV"},"url":"\#(pr)#issuecomment-1"},{"id":"IC2","author":null,"url":"\#(pr)#issuecomment-2"}]"#)
        try world.gh.write(
            "inline-1.json",
            #"[{"id":12,"user":{"login":"carol"},"html_url":"\#(pr)#discussion_r12","in_reply_to_id":11},{"id":11,"user":{"login":"bob"},"html_url":"\#(pr)#discussion_r11"}]"#)
        world.clock.advance(180)
        try await world.sync.sweep()
        let kinds = try world.store.undeliveredLinkNotices(task: task.number).map(\.notice.kind)
        #expect(kinds == [.commits, .checksFailed, .changesRequested, .comment, .inlineComment, .inlineReply])
        let failed = try world.store.undeliveredLinkNotices(task: task.number).first { $0.notice.kind == .checksFailed }
        #expect(failed?.notice.detail == "test")
        #expect(try world.store.undeliveredLinkNotices(task: task.number).first { $0.notice.kind == .comment }?.notice.actor == "ghost")
        #expect(await box.numbers == [[task.number]])

        let inlineCalls = world.gh.calls.filter { $0.contains("/comments") }
        try #require(inlineCalls.count == 2)
        #expect(!inlineCalls[0].contains("since="), "前の様子が無ければ範囲を絞らない")
        #expect(inlineCalls[1].contains("since=2026-09-21T14:03:20Z"), "\(inlineCalls[1])")
        #expect(world.gh.authCalls == ["auth status --json hosts"], "自分の login は gh の既定のアカウントで、覚えておく")
    }

    @Test("セッションを結んだタスクは 60 秒、ほかは 180 秒、マージしたものは 30 分ごとに取る。同じ URL は 1 回だけ取る")
    func intervals() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1)
        try world.gh.pullRequest(2, state: "MERGED")
        try world.gh.write("inline-1.json", "[]")
        try world.gh.write("issue-3.json", #"{"state":"OPEN","stateReason":"","comments":[]}"#)
        let issue = "https://github.com/o/r/issues/3"
        let linked = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        _ = try world.store.linkSession(task: linked.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        _ = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "y", links: [pr, issue]))
        _ = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "deploying", title: "z", links: ["https://github.com/o/r/pull/2"]))
        func views() -> [String] { world.gh.calls.filter { $0.contains(" view ") } }

        try await world.sync.sweep()
        #expect(views().count == 3, "\(views())")
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(views().count == 4 && views().last?.contains("pull/1") == true, "結んだタスクの PR だけ")
        world.clock.advance(120)
        try await world.sync.sweep()
        #expect(views().count == 6 && views().suffix(2).contains { $0.contains("issues/3") }, "180 秒で issue も")
        world.clock.advance(1800)
        try await world.sync.sweep()
        #expect(views().suffix(3).contains { $0.contains("pull/2") }, "マージしたものは 30 分")
    }

    @Test("rate limit に当たったら、そのアカウントは待ちを倍にしていき、通ったら元に戻す")
    func rateLimitBackoff() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        await world.state.upsert(try world.store.linkSession(task: task.number, agent: "claude", sessionID: "s1", cwd: "/w", label: ""))
        try world.gh.write("ratelimit", "")
        try await world.sync.sweep()
        #expect(world.gh.calls.count == 1)
        world.clock.advance(119)
        try await world.sync.sweep()
        #expect(world.gh.calls.count == 1, "2 分は待つ")
        world.clock.advance(1)
        try await world.sync.sweep()
        #expect(world.gh.calls.count == 2)
        world.clock.advance(239)
        try await world.sync.sweep()
        #expect(world.gh.calls.count == 2, "次は 4 分")
        world.clock.advance(1)
        world.gh.remove("ratelimit")
        try await world.sync.sweep()
        #expect(world.gh.calls.count >= 3)
        let before = world.gh.calls.count
        world.clock.advance(60)
        try await world.sync.sweep()
        #expect(world.gh.calls.count > before, "通ったら 60 秒の間隔に戻る")
        #expect(await world.state.linkStatuses().map(\.error) == [nil])
    }

    @Test("gh が名乗るアカウント: 対応表のアカウントは token が取れればそれ、取れないか対応表に無ければ host の既定のアカウント")
    func identity() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: world.gh.executable, now: { world.clock.now })
        let me = GitHubCLI.Account(host: "github.com", login: "Me-Dev")
        #expect(await cli.identity(nil, host: "github.com") == me)
        #expect(await cli.identity(GitHubCLI.Account(host: "github.com", login: "carol"), host: "github.com") == me, "token が取れない")
        try world.gh.write("token-other", "")
        let other = GitHubCLI.Account(host: "github.com", login: "other")
        #expect(await cli.identity(other, host: "github.com") == other)
        #expect(await cli.identity(nil, host: "ghe.example") == nil, "ログインしていない host")
    }

    @Test("PR の一覧（PullRequestSync）で同じアカウントが rate limit に当たっていたら、リンクも明けるまで取らない")
    func sharesRateLimitWithPullRequestList() async throws {
        let gh = try FakeGitHub()
        defer { gh.cleanUp() }
        try gh.pullRequest(1)
        try gh.write("inline-1.json", "[]")
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let clock = Clock()
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable, now: { clock.now })
        let sync = GitHubSync(store: store, state: state, cli: cli, now: { clock.now })
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x", links: [pr]))
        await cli.noteRateLimit(GitHubCLI.Account(host: "github.com", login: "Me-Dev"))
        #expect(try await sync.syncNow(task: task) == nil)
        #expect(gh.calls.isEmpty, "間隔を待たない syncNow でも取らない")
        clock.advance(GitHubCLI.firstRateLimitWait)
        #expect(try await sync.syncNow(task: task)?.columnID == "review")
    }

    @Test("取っている間に同じ URL を後から取り始めて先に終わったら、遅れて返った古い結果は捨てる（開き直しと取り違えない）")
    func dropsStaleFetch() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        try await world.sync.sweep()

        try world.gh.write("slow", "")
        world.clock.advance(180)
        let sweep = Task { try await world.sync.sweep() }
        while !FileManager.default.fileExists(atPath: world.gh.directory.appendingPathComponent("slow-started").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try world.gh.pullRequest(1, state: "MERGED", mergedBy: #"{"login":"bob"}"#)
        world.clock.advance(1)
        _ = try await world.sync.syncNow(task: task)
        try await sweep.value
        #expect(try world.store.undeliveredLinkNotices(task: task.number).map(\.notice.kind) == [.merged])
        guard case .pullRequest(let stored) = try world.store.linkSnapshot(taskLinkID: try #require(task.links.first).id) else {
            Issue.record("様子が無い")
            return
        }
        #expect(stored.state == .merged)
    }

    @Test("遅れて返った古いクローズの応答は、開き直した後の取得の間隔を 30 分に戻さない")
    func staleFetchKeepsInterval() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1, state: "CLOSED")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        try await world.sync.sweep()
        try world.gh.write("slow", "")
        world.clock.advance(1800)
        let sweep = Task { try await world.sync.sweep() }
        while !FileManager.default.fileExists(atPath: world.gh.directory.appendingPathComponent("slow-started").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        world.clock.advance(1)
        // 今すぐの同期はクローズ済みのリンクを取り直さないので、間隔を待たずに取る見張りの取得で新しい応答を先に返す
        await world.sync.syncWatch(url: pr)
        try await sweep.value
        #expect(try world.store.undeliveredLinkNotices(task: task.number).map(\.notice.kind) == [.reopened])
        let views = world.gh.calls.filter { $0.contains(" view ") }.count
        world.clock.advance(180)
        try await world.sync.sweep()
        #expect(world.gh.calls.filter { $0.contains(" view ") }.count == views + 1, "open の間隔（180 秒）で取る")
    }

    @Test("自分の login を引き直せなかった回は、前の login を使わずに比べない")
    func expiredViewerNotReused() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        try await world.sync.sweep()
        world.gh.remove("status.json")
        try world.gh.pullRequest(1, comments: #"[{"id":"IC1","author":{"login":"me-dev"},"url":"\#(pr)#issuecomment-1"}]"#)
        world.clock.advance(GitHubCLI.identityLifetime + 1)
        try await world.sync.sweep()
        guard case .pullRequest(let stored) = try world.store.linkSnapshot(taskLinkID: try #require(task.links.first).id) else {
            Issue.record("様子が無い")
            return
        }
        #expect(stored.comments.isEmpty, "様子を書き換えていない")
    }

    @Test("様子の時刻は、全部を取り終えた時刻でなく、その URL を取り始めた時刻（次の行のコメントの since の元）")
    func snapshotTimeIsFetchStart() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        _ = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "review", title: "x", links: [pr]))
        try world.gh.write("slow", "")
        let sweep = Task { try await world.sync.sweep() }
        while !FileManager.default.fileExists(atPath: world.gh.directory.appendingPathComponent("slow-started").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        world.clock.advance(900)
        try await sweep.value
        #expect(try world.store.oldestLinkSnapshot(url: pr, tasks: [1]) == t0)
    }

    @Test("自分の login を引けない回は、PR の状態だけを入れて比べない（自分のコメントを知らせない）")
    func noViewerNoNotices() async throws {
        let world = try await world()
        defer { world.gh.cleanUp() }
        world.gh.remove("status.json")
        try world.gh.pullRequest(1)
        try world.gh.write("inline-1.json", "[]")
        let task = try world.store.createTask(TaskCreateRequest(boardID: world.board.id, columnID: "working", title: "x", links: [pr]))
        let moved = try await world.sync.syncNow(task: task)
        #expect(moved?.columnID == "review", "列は今までどおり進める")
        #expect(try world.store.linkSnapshot(taskLinkID: try #require(task.links.first).id) == nil)
    }
}

private actor NoticeBox {
    private(set) var numbers: [[Int]] = []
    func add(_ value: [Int]) { numbers.append(value) }
}

@Suite("リンクの知らせの届け（偽物の host）", .serialized)
struct LinkNoticeDeliveryTests {
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func userTexts(_ world: ServiceWorld) async -> [(uuid: String, text: String)] {
        await world.host.written().filter { $0["type"] as? String == "user" }.compactMap { line in
            guard let uuid = line["uuid"] as? String, let text = (line["message"] as? [String: Any])?["content"] as? String else { return nil }
            return (uuid, text)
        }
    }

    /// world のタスクに PR を結び、他人のコメントの知らせを `count` 件作る
    private func record(_ world: ServiceWorld, comments count: Int) async throws {
        let task = try world.store.updateTask(number: world.task, TaskUpdateRequest(addLinks: [pr]))
        await world.state.upsert(task)
        try world.store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [world.task], at: t0)
        try world.store.recordLinkSnapshot(url: pr, snapshot: open(comments: (1...count).map { comment($0) }), viewerLogin: "me", tasks: [world.task], at: t0 + 60)
    }

    /// world のタスクに PR を結び、対応の要らない知らせ（新しいコミットと CI が通った）を作る
    private func recordCommit(_ world: ServiceWorld) async throws {
        let task = try world.store.updateTask(number: world.task, TaskUpdateRequest(addLinks: [pr]))
        await world.state.upsert(task)
        try world.store.recordLinkSnapshot(url: pr, snapshot: open(), viewerLogin: "me", tasks: [world.task], at: t0)
        guard case .pullRequest(var moved) = open() else { return }
        moved.headSHA = "b2"
        moved.checks = .success
        try world.store.recordLinkSnapshot(url: pr, snapshot: .pullRequest(moved), viewerLogin: "me", tasks: [world.task], at: t0 + 60)
    }

    @Test("空いた会話に 1 通で届け、20 件を超えた分は件数だけ書いて全部を届けた扱いにする。本文は載せない")
    func deliversOneMessage() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        try await record(world, comments: 23)
        let notices = LinkNotices(store: world.store, state: world.state, conversations: world.service)

        async let delivered: Void = notices.deliver(task: world.task)
        #expect(await eventually { await userTexts(world).contains { $0.text.contains("のリンク先の PR・issue に動きがあった") } })
        let message = try #require(await userTexts(world).first { $0.text.contains("のリンク先の PR・issue に動きがあった") })
        let lines = message.text.split(separator: "\n")
        #expect(lines.filter { $0.hasPrefix("- r#1: コメント（bob） \(pr)#issuecomment-") }.count == 20)
        #expect(message.text.contains("- r#1: コメント（bob） \(pr)#issuecomment-23"), "新しい 20 件を載せる")
        #expect(message.text.contains("- 省いた動き: 3 件（URL を開いて確認する）"))
        #expect(Array(lines.prefix(2)) == ["<!-- taskboard: link task=\(world.task) -->", "[taskboard 通知] タスク #\(world.task) のリンク先の PR・issue に動きがあった"])
        #expect(Array(lines.dropFirst(2).prefix(2)) == ["- 送り主: taskboard の自動の通知。人の発言でも承認でもない", "- 本文: 載せていない（外部の人が書いた文のため）。URL を開いて読む"])
        #expect(lines.firstIndex(of: "動き:") ?? 0 > lines.firstIndex { $0.hasPrefix("- 送り主") } ?? 0, "送り主は動きの一覧より前")
        #expect(TaskboardNotice(text: message.text) == .link)
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"started"}"#, key: conversation.id)
        await delivered
        #expect(try world.store.undeliveredLinkNotices(task: world.task).isEmpty)
        #expect(try world.store.linkNotices(task: world.task).undelivered == 0)

        await notices.deliver(task: world.task)
        #expect(await userTexts(world).filter { $0.text.contains("に動きがあった") }.count == 1)
    }

    @Test("使われていないので停止した会話は、対応が必要知らせのときだけ起こす。不要知らせは次に動いたときに渡す")
    func wakesOnlyForAction() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let conversation = try await world.service.start(world.request())
        // 人が止めた会話は起こさない（`ConversationServiceTests.deliveryWakePolicy`）ので、使われていないので止める
        #expect(await world.service.stopIdle(before: Date().addingTimeInterval(60)).contains(conversation.id))
        try await recordCommit(world)
        let notices = LinkNotices(store: world.store, state: world.state, conversations: world.service)
        let spawns = await world.host.requests.filter { $0.op == .spawn }.count

        await notices.deliver(task: world.task)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == spawns, "新しいコミットと CI が通ったでは起こさない")
        #expect(try world.store.undeliveredLinkNotices(task: world.task).count == 2)

        try world.store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [world.task], at: t0 + 120)
        async let delivered: Void = notices.deliver(task: world.task)
        #expect(await eventually { await world.host.requests.filter { $0.op == .spawn }.count == spawns + 1 }, "コメントで起こす")
        #expect(await eventually { await userTexts(world).contains { $0.text.contains("コメント（bob）") } })
        let message = try #require(await userTexts(world).first { $0.text.contains("コメント（bob）") })
        #expect(message.text.contains("CI が通った（b2）"), "溜まっていた分も一緒に渡す")
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"started"}"#, key: conversation.id)
        await delivered
        #expect(try world.store.undeliveredLinkNotices(task: world.task).isEmpty)
    }

    @Test("lead が止まっていて委譲先だけが動いているときも、委譲先でなく lead に届ける")
    func deliversToStoppedLead() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let lead = try await world.service.start(world.request())
        #expect(await world.service.stopIdle(before: Date().addingTimeInterval(60)).contains(lead.id))
        var request = world.request()
        request.parent = ConversationParent(conversationID: lead.id)
        let child = try await world.service.start(request)
        #expect(await eventually { await world.state.task(number: world.task)?.sessions.count == 2 })
        try await record(world, comments: 1)
        let notices = LinkNotices(store: world.store, state: world.state, conversations: world.service)

        async let delivered: Void = notices.deliver(task: world.task)
        #expect(await eventually { await userTexts(world).contains { $0.text.contains("コメント（bob）") } })
        let spawn = try #require(await world.host.requests.last { $0.op == .spawn })
        #expect(spawn.key == lead.id, "止まった lead を起こす")
        let message = try #require(await userTexts(world).first { $0.text.contains("コメント（bob）") })
        await world.host.emit(#"{"type":"command_lifecycle","command_uuid":"\#(message.uuid)","state":"started"}"#, key: lead.id)
        await delivered
        #expect(try world.store.undeliveredLinkNotices(task: world.task).isEmpty)
        let toChild = await world.host.requests.filter { $0.op == .write && $0.key == child.id && ($0.data ?? "").contains("に動きがあった") }
        #expect(toChild.isEmpty)
    }

    @Test("lead が止まった TUI なら、対応が必要知らせのときだけ会話で戻す。戻している間は起こし直さない")
    func resumesStoppedTerminal() async throws {
        let world = try await ServiceWorld.make()
        defer { world.cleanUp() }
        let tui = "7a1d2b8e-2c4a-4a8f-9c11-5d7e0a3b9f02"
        try world.append(tui, [("u1", "user", "作って"), ("a1", "assistant", "作った")])
        await world.state.upsert(try world.store.linkSession(task: world.task, agent: "claude", sessionID: tui, cwd: world.directory.path, label: ""))
        try await recordCommit(world)
        let notices = LinkNotices(store: world.store, state: world.state, conversations: world.service)
        await notices.deliver(task: world.task)
        #expect(await world.host.requests.filter { $0.op == .spawn }.isEmpty, "対応の不要知らせでは戻さない")

        try world.store.recordLinkSnapshot(url: pr, snapshot: open(comments: [comment(1)]), viewerLogin: "me", tasks: [world.task], at: t0 + 120)
        await notices.deliver(task: world.task)
        let spawn = try #require(await world.host.requests.first { $0.op == .spawn })
        #expect((spawn.argv ?? []).contains(tui), "同じ Claude の会話を戻す")
        await notices.deliver(task: world.task)
        #expect(await world.host.requests.filter { $0.op == .spawn }.count == 1, "戻している間は起こし直さない")
    }
}

