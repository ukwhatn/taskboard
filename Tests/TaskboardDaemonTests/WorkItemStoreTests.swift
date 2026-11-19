import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store: 作業項目とセッションの紐づけ")
struct WorkItemStoreTests {
    private let machine = MachineID(rawValue: "m-test")

    private func makeStore() throws -> (Store, Board, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "親タスク"))
        return (store, board, task)
    }

    @Test("追加は末尾に並び、位置指定で差し込むと後ろがずれ、削除で詰まる")
    func ordering() throws {
        let (store, _, task) = try makeStore()
        let a = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "A", source: "session"))
        let b = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "B"))
        let c = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "C"))
        #expect([a, b, c].map(\.position) == [0, 1, 2])
        #expect(a.source == "session" && b.source == "manual")

        let inserted = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "A2", position: 1))
        #expect(inserted.position == 1)
        #expect(try store.workItems(task: task.number).map(\.title) == ["A", "A2", "B", "C"])

        _ = try store.updateWorkItem(id: c.itemID, WorkItemUpdateRequest(position: 0))
        #expect(try store.workItems(task: task.number).map(\.title) == ["C", "A", "A2", "B"])

        #expect(try store.deleteWorkItem(id: a.itemID) == task.number)
        let remaining = try store.workItems(task: task.number)
        #expect(remaining.map(\.title) == ["C", "A2", "B"])
        #expect(remaining.map(\.position) == [0, 1, 2])

        #expect(throws: StoreError.workItemNotFound(999)) { try store.updateWorkItem(id: 999, WorkItemUpdateRequest(title: "x")) }
        #expect(throws: StoreError.taskNotFound(404)) { try store.createWorkItem(task: 404, WorkItemCreateRequest(title: "x")) }
    }

    @Test("待ち以外へ動かすと blocker が消え、待ちにするときの blocker と成果物は残る")
    func blockerLifecycle() throws {
        let (store, _, task) = try makeStore()
        let item = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "実装"))
        let waiting = try store.updateWorkItem(
            id: item.itemID, WorkItemUpdateRequest(state: .wait, blockerKind: .ci, blockerText: "CI 待ち", blockerTone: .attention))
        #expect(waiting.state == .wait && waiting.blockerKind == .ci && waiting.blockerText == "CI 待ち" && waiting.blockerTone == .attention)

        let withPR = try store.updateWorkItem(
            id: item.itemID, WorkItemUpdateRequest(deliverableKind: .pr, deliverableRef: "https://github.com/ukwhatn/taskboard/pull/9"))
        #expect(withPR.state == .wait && withPR.blockerKind == .ci, "成果物だけの更新で blocker は変わらない")

        let doing = try store.updateWorkItem(id: item.itemID, WorkItemUpdateRequest(state: .doing))
        #expect(doing.blockerKind == nil && doing.blockerText == "" && doing.blockerTone == nil)
        #expect(doing.deliverableKind == .pr, "成果物は状態遷移で消えない")

        let cleared = try store.updateWorkItem(id: item.itemID, WorkItemUpdateRequest(clearDeliverable: true))
        #expect(cleared.deliverableKind == nil && cleared.deliverableRef == "")

        let touched = try #require(try store.task(number: task.number))
        #expect(touched.updatedAt > task.updatedAt, "作業項目の更新でタスクの updatedAt が進む")
    }

    @Test("タスクを消すと作業項目も消える")
    func cascade() throws {
        let (store, _, task) = try makeStore()
        _ = try store.createWorkItem(task: task.number, WorkItemCreateRequest(title: "A"))
        try store.deleteTask(number: task.number)
        #expect(try store.workItems().isEmpty)
    }

    @Test("セッションの紐づけは session_id で冪等。cwd 一致は終端でない最新のタスクを選ぶ")
    func sessionLinking() throws {
        let (store, board, task) = try makeStore()
        let linked = try store.linkSession(task: task.number, agent: "claude", sessionID: "sess-1", cwd: "/Users/u/dev/x", label: "")
        #expect(linked.sessions.map(\.sessionID) == ["sess-1"])
        let again = try store.linkSession(task: task.number, agent: "claude", sessionID: "sess-1", cwd: "/Users/u/dev/x", label: "")
        #expect(again.sessions.count == 1)
        #expect(try store.task(linkedToSession: "sess-1")?.number == task.number)
        #expect(try store.task(linkedToSession: "sess-9") == nil)

        let older = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "done", title: "終わった", links: ["https://github.com/ukwhatn/taskboard/pull/1"]))
        _ = try store.linkSession(task: older.number, agent: "claude", sessionID: "sess-2", cwd: "/Users/u/dev/x", label: "")
        #expect(try store.task(matchingCwd: "/Users/u/dev/x")?.number == task.number, "完了列のタスクは cwd 一致の候補から外す")
        #expect(try store.task(matchingCwd: "") == nil)
        #expect(try store.task(matchingCwd: "/nowhere") == nil)
        #expect(try store.task(linkedToURL: "https://github.com/ukwhatn/taskboard/pull/1")?.number == older.number)
        #expect(throws: StoreError.taskNotFound(77)) { try store.linkSession(task: 77, agent: "claude", sessionID: "s", cwd: "", label: "") }
    }
}

@Suite("GitHubAccounts")
struct GitHubAccountsTests {
    let accounts = GitHubAccounts(mapping: [
        "github.com/Acme-org": "me_work",
        "github.com/me": "me",
        "ghe.example.com": "me_ghe",
    ])

    @Test("URL は host/owner を host より優先し、対応が無ければ nil")
    func matchURL() {
        #expect(accounts.match(url: "https://github.com/Acme-org/server/pull/42") == .init(host: "github.com", account: "me_work"))
        #expect(accounts.match(url: "https://github.com/me/taskboard/pull/3") == .init(host: "github.com", account: "me"))
        #expect(accounts.match(url: "https://ghe.example.com/team/repo/pull/1") == .init(host: "ghe.example.com", account: "me_ghe"))
        #expect(accounts.match(url: "https://github.com/someone/else/pull/1") == nil, "host だけの対応は無い")
        #expect(accounts.match(url: "not a url") == nil)
    }

    @Test("git の remote は https / scp / ssh の 3 形を読む")
    func matchRemote() {
        #expect(accounts.match(remote: "https://github.com/Acme-org/server.git\n")?.account == "me_work")
        #expect(accounts.match(remote: "git@github.com:me/taskboard.git")?.account == "me")
        #expect(accounts.match(remote: "ssh://git@ghe.example.com/team/repo")?.account == "me_ghe")
        #expect(accounts.match(remote: "/Users/me/local-repo") == nil)
    }

    @Test("taskherd の config から [github.accounts] だけを読む")
    func parseConfig() {
        let toml = """
            [github]
            ghes_hosts = ["ghe.example.com"]

            [github.accounts]
            # コメント
            "github.com/Acme-org" = "me_work"
            "github.com/me" = "me"   # 末尾コメント
            "ghe.example.com" = "me_ghe"

            [session_start]
            prompt_template = "x = y"
            """
        let parsed = GitHubAccounts.parseTaskherdConfig(toml)
        #expect(parsed.mapping == ["github.com/Acme-org": "me_work", "github.com/me": "me", "ghe.example.com": "me_ghe"])
        #expect(GitHubAccounts.parseTaskherdConfig("").mapping.isEmpty)
    }

    @Test("ファイルの往復と、無いときは空")
    func fileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gh-accounts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(GitHubAccounts.load(from: url).mapping.isEmpty)
        try accounts.write(to: url)
        #expect(GitHubAccounts.load(from: url) == accounts)
    }
}
