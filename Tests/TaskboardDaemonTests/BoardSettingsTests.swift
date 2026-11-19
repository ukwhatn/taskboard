import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing
import TestSupport

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-test")

/// 今の列をそのまま並べた編集（ここから足す・消す・並べ替える）
private func edits(_ board: Board) -> [BoardColumnEdit] {
    board.columns.map { BoardColumnEdit(id: $0.id, label: $0.label, kind: $0.kind, collapsed: $0.collapsed) }
}

@Suite("案件の設定: 列の置き換え・アーカイブ・削除・起動の既定")
struct BoardSettingsTests {
    @Test("v6 までの DB に v7 を当てると、終端の列だけが畳む列になり、案件はアーカイブしていない")
    func migrationCollapsesTerminalColumns() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v7-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v6 schedules")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO board (id, name, position, createdAt) VALUES ('b1', 'default', 0, ?)", arguments: [Date()])
                for (index, column) in BoardColumn.standard.filter({ $0.id != BoardColumn.standingID }).enumerated() {
                    try db.execute(
                        sql: "INSERT INTO boardColumn (boardId, id, label, kind, position) VALUES ('b1', ?, ?, ?, ?)",
                        arguments: [column.id, column.label, column.kind.rawValue, index])
                }
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        let board = try #require(try store.boards().first)
        #expect(board.columns.filter(\.collapsed).map(\.id) == ["done", "wontfix"])
        #expect(board.archived == false)
        #expect(board.launchDefaults == nil)
        #expect(board.mergeTarget == .deploying, "v12 の既定はデプロイ中")
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")
        try store.close()
    }

    @Test("新しい案件の終端の列は畳む列で作られる")
    func newBoardCollapsesTerminal() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        #expect(board.columns.filter(\.collapsed).map(\.id) == ["done", "wontfix"])
    }

    @Test("列の追加・改名・並べ替え・畳む・テンプレートは 1 回の置き換えで入り、位置は配列の順に振り直す")
    func replaceColumns() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        _ = try store.updateBoard(id: board.id, BoardUpdateRequest(columnTemplates: ["todo": "todo の起動"]))
        var columns = edits(board)
        columns.swapAt(0, 2)  // todo を先頭へ（常設は 3 番目へ）
        columns[0].label = "  これから  "
        columns[1].collapsed = true  // review_req を畳む
        columns.insert(BoardColumnEdit(id: nil, label: "保留", kind: .open, collapsed: false, promptTemplate: "保留の起動"), at: 2)
        let updated = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns))

        #expect(updated.columns.map(\.position) == Array(0..<10))
        #expect(updated.columns[0].id == "todo" && updated.columns[0].label == "これから")
        #expect(updated.columns[0].promptTemplate == "todo の起動", "promptTemplate が nil の編集は今の値を残す")
        #expect(updated.columns[1].id == "review_req" && updated.columns[1].collapsed)
        let added = updated.columns[2]
        #expect(added.id.hasPrefix("c-") && added.id.count == 10)
        #expect(added.label == "保留" && added.kind == .open && added.promptTemplate == "保留の起動")

        // 空文字のテンプレートは消す
        var again = edits(updated)
        again[0].promptTemplate = ""
        let cleared = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: again))
        #expect(cleared.columns[0].promptTemplate == nil)
        #expect(cleared.columns[2].id == added.id, "足した列の id は次の置き換えでも保つ")
    }

    @Test("タスクがある列を消すには移す先が要り、移したタスクは移す先の列に入る")
    func removeColumnWithTasks() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        var columns = edits(board)
        columns.append(BoardColumnEdit(id: nil, label: "保留", kind: .open, collapsed: false))
        let withHold = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns))
        let hold = withHold.columns.last!.id
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: hold, title: "保留中"))
        let other = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "別の列"))

        let without = edits(withHold).filter { $0.id != hold }
        #expect(throws: StoreError.refused(.columnHasTasks, ["label": "保留", "count": "1"], "列「保留」にタスクが 1 件ある: 移す先の列を選ぶ")) {
            try store.updateBoard(id: board.id, BoardUpdateRequest(columns: without))
        }
        #expect(throws: StoreError.invalid("移す先の列 \(hold) が新しい列に無い")) {
            try store.updateBoard(id: board.id, BoardUpdateRequest(columns: without, reassign: [hold: hold]))
        }
        #expect(try store.boards().first!.columns.count == 10, "失敗した置き換えは何も書かない")

        let edit = try store.editBoard(id: board.id, BoardUpdateRequest(columns: without, reassign: [hold: "planning"]))
        #expect(edit.board.columns.map(\.id) == BoardColumn.standard.map(\.id))
        #expect(edit.movedTasks.map(\.number) == [task.number])
        #expect(edit.movedTasks.first?.columnID == "planning")
        #expect(try store.task(number: other.number)?.columnID == "todo")
    }

    @Test("タスクの無い足した列は移す先なしで消せる")
    func removeEmptyColumn() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let added = try store.updateBoard(
            id: board.id, BoardUpdateRequest(columns: edits(board) + [BoardColumnEdit(id: nil, label: "x", kind: .terminal, collapsed: true)]))
        let edit = try store.editBoard(id: board.id, BoardUpdateRequest(columns: edits(added).dropLast()))
        #expect(edit.board.columns.count == 9 && edit.movedTasks.isEmpty)
    }

    @Test("完了の列を消す・既定の列の完了扱いを変える・名前の空や重複・id の重複や不明・進行中の列が 0 は 400")
    func invalidColumns() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let base = edits(board)
        func reject(_ columns: [BoardColumnEdit], _ error: StoreError) {
            #expect(throws: error) { try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns)) }
        }
        reject(
            base.filter { $0.id != "done" },
            .refused(.defaultColumnLocked, ["label": "完了", "change": "remove"], "列「完了」は消せない: マージとレビュー依頼の終わりで進める先"))
        var kind = base
        kind[2].kind = .terminal
        reject(kind, .refused(.defaultColumnLocked, ["label": "未着手", "change": "kind"], "既定の列「未着手」の完了扱いは変えられない"))
        var empty = base
        empty[0].label = "  "
        reject(empty, .refused(.columnLabelEmpty, [:], "列の名前が空"))
        reject(base + [BoardColumnEdit(id: nil, label: "完了", kind: .terminal, collapsed: true)], .refused(.columnLabelDuplicate, ["label": "完了"], "列「完了」が重複している"))
        var dupID = base
        dupID.append(BoardColumnEdit(id: "todo", label: "別名", kind: .open, collapsed: false))
        reject(dupID, .invalid("列 todo が重複している"))
        reject(base + [BoardColumnEdit(id: "nope", label: "y", kind: .open, collapsed: false)], .invalid("列 nope はこの案件に無い"))

        let custom = try store.createBoard(name: "b", columns: [BoardColumn(id: "x", label: "x", kind: .open, position: 0)])
        #expect(throws: StoreError.refused(.noOpenColumn, [:], "進行中の列が 1 つも無い: タスクを作る先が無くなる")) {
            try store.updateBoard(id: custom.id, BoardUpdateRequest(columns: [BoardColumnEdit(id: "x", label: "x", kind: .terminal, collapsed: true)]))
        }
        #expect(try store.boards().first { $0.id == board.id }?.columns.map(\.id) == BoardColumn.standard.map(\.id))
    }

    @Test("案件の名前は前後の空白を落とし、空と同じマシン内での重複は 400")
    func boardNames() throws {
        let store = try Store(inMemory: machine)
        let a = try store.createBoard(name: " 案件A ", columns: nil)
        #expect(a.name == "案件A")
        let b = try store.createBoard(name: "B", columns: nil)
        #expect(throws: StoreError.refused(.boardNameTaken, ["name": "案件A"], "案件「案件A」は既にある")) { try store.updateBoard(id: b.id, BoardUpdateRequest(name: "案件A ")) }
        #expect(throws: StoreError.refused(.boardNameTaken, ["name": "B"], "案件「B」は既にある")) { try store.createBoard(name: "B", columns: nil) }
        #expect(throws: StoreError.refused(.boardNameEmpty, [:], "案件の名前が空")) { try store.updateBoard(id: b.id, BoardUpdateRequest(name: " ")) }
        #expect(try store.updateBoard(id: a.id, BoardUpdateRequest(name: "案件A")).name == "案件A", "自分と同じ名前は重複にしない")
    }

    @Test("アーカイブと戻す。最後の 1 つはアーカイブできず、アーカイブした案件へのタスクの作成・移動は 409")
    func archive() throws {
        let store = try Store(inMemory: machine)
        let a = try store.createBoard(name: "a", columns: nil)
        let b = try store.createBoard(name: "b", columns: nil)
        let archived = try store.updateBoard(id: a.id, BoardUpdateRequest(archived: true))
        #expect(archived.archived)
        #expect(throws: StoreError.refused(.boardLast, [:], "最後の案件はアーカイブできない: 先にほかの案件を作る")) {
            try store.updateBoard(id: b.id, BoardUpdateRequest(archived: true))
        }
        #expect(try store.defaultBoard()?.id == b.id)
        #expect(throws: StoreError.boardArchived("a")) {
            try store.createTask(TaskCreateRequest(boardID: a.id, columnID: "todo", title: "x"))
        }
        let task = try store.createTask(TaskCreateRequest(boardID: b.id, columnID: "todo", title: "x"))
        #expect(throws: StoreError.boardArchived("a")) { try store.updateTask(number: task.number, TaskUpdateRequest(boardID: a.id)) }
        #expect(try store.task(number: task.number)?.boardID == b.id)

        let restored = try store.updateBoard(id: a.id, BoardUpdateRequest(archived: false))
        #expect(!restored.archived)
        #expect(try store.defaultBoard()?.id == a.id, "戻すと position の先頭が既定に戻る")
    }

    @Test("削除はタスクが 0 件で、ほかに使える案件が残るときだけ")
    func deleteBoard() throws {
        let store = try Store(inMemory: machine)
        let a = try store.createBoard(name: "a", columns: nil)
        let b = try store.createBoard(name: "b", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: b.id, columnID: "todo", title: "x"))
        #expect(throws: StoreError.refused(.boardHasTasks, ["name": "b", "count": "1"], "案件「b」にタスクが 1 件ある: ほかの案件へ移してから削除する")) { try store.deleteBoard(id: b.id) }
        _ = try store.updateBoard(id: a.id, BoardUpdateRequest(archived: true))
        try store.deleteTask(number: task.number)
        #expect(throws: StoreError.refused(.boardLast, [:], "最後の案件は削除できない: 先にほかの案件を作る")) { try store.deleteBoard(id: b.id) }
        try store.deleteBoard(id: a.id)
        #expect(try store.boards().map(\.id) == [b.id])
        #expect(throws: StoreError.boardNotFound(a.id)) { try store.deleteBoard(id: a.id) }
    }

    @Test("起動の既定は往復し、clearLaunchDefaults で消える。省略は変えない")
    func launchDefaults() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let defaults = LaunchDefaults(kind: .codex, agentArgs: ["--model", "gpt-5"], worktree: true, cwd: "~/dev/作業")
        #expect(try store.updateBoard(id: board.id, BoardUpdateRequest(launchDefaults: defaults)).launchDefaults == defaults)
        #expect(try store.updateBoard(id: board.id, BoardUpdateRequest(name: "b")).launchDefaults == defaults)
        #expect(throws: StoreError.invalid("launchDefaults と clearLaunchDefaults は同時に送らない")) {
            try store.updateBoard(id: board.id, BoardUpdateRequest(launchDefaults: defaults, clearLaunchDefaults: true))
        }
        #expect(try store.updateBoard(id: board.id, BoardUpdateRequest(clearLaunchDefaults: true)).launchDefaults == nil)
    }

    @Test("PATCH tasks: boardID だけなら同じ id の列か先頭の進行中の列、組なら移す先の列を確かめ、満たせなければ書き換えない")
    func moveTaskBetweenBoards() throws {
        let store = try Store(inMemory: machine)
        let a = try store.createBoard(name: "a", columns: nil)
        let b = try store.createBoard(
            name: "b",
            columns: [
                BoardColumn(id: "done", label: "完了", kind: .terminal, position: 0),
                BoardColumn(id: "next", label: "次", kind: .open, position: 1),
                BoardColumn(id: "working", label: "作業中", kind: .open, position: 2),
            ])
        let task = try store.createTask(TaskCreateRequest(boardID: a.id, columnID: "working", title: "x"))
        let same = try store.updateTask(number: task.number, TaskUpdateRequest(boardID: b.id))
        #expect(same.boardID == b.id && same.columnID == "working")

        let planning = try store.createTask(TaskCreateRequest(boardID: a.id, columnID: "planning", title: "y"))
        let fallback = try store.updateTask(number: planning.number, TaskUpdateRequest(boardID: b.id))
        #expect(fallback.columnID == "next", "先頭の列は終端なので、先頭の進行中の列に入る")

        let pair = try store.updateTask(number: planning.number, TaskUpdateRequest(columnID: "review", boardID: a.id))
        #expect(pair.boardID == a.id && pair.columnID == "review")
        #expect(throws: StoreError.refused(.notFound, ["kind": "column"], "列 review は案件「b」に無い")) {
            try store.updateTask(number: planning.number, TaskUpdateRequest(columnID: "review", boardID: b.id))
        }
        let unchanged = try #require(try store.task(number: planning.number))
        #expect(unchanged.boardID == a.id && unchanged.columnID == "review")
        #expect(throws: StoreError.boardNotFound("nope")) { try store.updateTask(number: planning.number, TaskUpdateRequest(boardID: "nope")) }
    }
}

@Suite("案件の設定の API")
struct BoardSettingsAPITests {
    private func makeApp() throws -> (APIServer.App, Store, DaemonState) {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        var dependencies = testDependencies
        dependencies.store = store
        return (APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies), store, state)
    }

    private func body<T: Encodable>(_ value: T) throws -> ByteBuffer {
        ByteBuffer(bytes: try WireJSON.encoder().encode(value))
    }

    @Test("列を消してタスクを移すと board.updated に続いて task.updated が流れる。移す先が無ければ 409、不正は 400")
    func patchColumnsBroadcastsMovedTasks() async throws {
        let (app, store, state) = try makeApp()
        let board = try store.createBoard(name: "a", columns: nil)
        let withHold = try store.updateBoard(
            id: board.id, BoardUpdateRequest(columns: edits(board) + [BoardColumnEdit(id: nil, label: "保留", kind: .open, collapsed: false)]))
        let hold = withHold.columns.last!.id
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: hold, title: "x"))
        let without = edits(withHold).filter { $0.id != hold }
        let headers: HTTPFields = [.authorization: "Bearer t", .contentType: "application/json"]
        // 準備で書いた分を配り終えてから、知らせを数え始める
        await store.statePublisher(state: state).settled()
        let (id, stream) = await state.subscribe()

        try await app.test(.router) { client in
            let conflict = try await client.execute(
                uri: "/v1/boards/\(board.id)", method: .patch, headers: headers, body: try body(BoardUpdateRequest(columns: without)))
            #expect(conflict.status == .conflict)
            #expect(String(buffer: conflict.body).contains("移す先の列を選ぶ"))

            let bad = try await client.execute(
                uri: "/v1/boards/\(board.id)", method: .patch, headers: headers,
                body: try body(BoardUpdateRequest(columns: without.filter { $0.id != "done" }, reassign: [hold: "planning"])))
            #expect(bad.status == .badRequest)

            let ok = try await client.execute(
                uri: "/v1/boards/\(board.id)", method: .patch, headers: headers,
                body: try body(BoardUpdateRequest(columns: without, reassign: [hold: "planning"])))
            #expect(ok.status == .ok)
            let returned = try WireJSON.decoder().decode(Board.self, from: ok.body)
            #expect(!returned.columns.contains { $0.id == hold })
        }
        await state.unsubscribe(id)
        var received: [DaemonEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.count == 2)
        if case .boardUpdated(let b) = received.first { #expect(b.columns.count == 9) } else { Issue.record("board.updated が先に来ない: \(received)") }
        if case .taskUpdated(let t) = received.last {
            #expect(t.number == task.number && t.columnID == "planning")
        } else {
            Issue.record("task.updated が来ない: \(received)")
        }
    }

    @Test("DELETE /v1/boards: 空なら 204 で board.removed、タスクありと最後の 1 つは 409、無ければ 404。アーカイブした案件への POST tasks は 409")
    func deleteAndArchive() async throws {
        let (app, store, state) = try makeApp()
        let a = try store.createBoard(name: "a", columns: nil)
        let b = try store.createBoard(name: "b", columns: nil)
        _ = try store.createTask(TaskCreateRequest(boardID: b.id, columnID: "todo", title: "x"))
        let headers: HTTPFields = [.authorization: "Bearer t", .contentType: "application/json"]
        let (id, stream) = await state.subscribe()

        try await app.test(.router) { client in
            let hasTasks = try await client.execute(uri: "/v1/boards/\(b.id)", method: .delete, headers: headers)
            #expect(hasTasks.status == .conflict)
            // アプリは code と params から画面の文を組む
            let rejection = SessionSourceError.from(status: Int(hasTasks.status.code), body: Data(buffer: hasTasks.body))
            #expect(rejection == .rejected(DaemonRejection(
                status: 409, message: "案件「b」にタスクが 1 件ある: ほかの案件へ移してから削除する", code: .boardHasTasks, params: ["name": "b", "count": "1"])))
            let archive = try await client.execute(
                uri: "/v1/boards/\(a.id)", method: .patch, headers: headers, body: try body(BoardUpdateRequest(archived: true)))
            #expect(archive.status == .ok)
            let lastArchive = try await client.execute(
                uri: "/v1/boards/\(b.id)", method: .patch, headers: headers, body: try body(BoardUpdateRequest(archived: true)))
            #expect(lastArchive.status == .conflict)
            let create = try await client.execute(
                uri: "/v1/tasks", method: .post, headers: headers, body: try body(TaskCreateRequest(boardID: a.id, columnID: "todo", title: "y")))
            #expect(create.status == .conflict)

            #expect(try await client.execute(uri: "/v1/boards/\(a.id)", method: .delete, headers: headers).status == .noContent)
            #expect(try await client.execute(uri: "/v1/boards/\(a.id)", method: .delete, headers: headers).status == .notFound)
        }
        await state.unsubscribe(id)
        var received: [DaemonEvent] = []
        for await event in stream { received.append(event) }
        #expect(received.last == .boardRemoved(a.id))
    }
}

/// `gh pr view` の代わり。cwd から引く問い合わせ（`number,title,...`）には `pr.json`、URL の状態には `state.json` を返す
private struct FakePRView {
    static let shared = SharedExecutable(
        name: "tb-test-prview-gh-2.sh",
        script: """
            #!/bin/sh
            D="$(dirname "$0")"
            while [ -f "$D/gate" ] && [ ! -f "$D/release" ]; do sleep 0.05; done
            if [ "$1" = pr ] && [ "$2" = view ]; then
              case "$*" in
                *number,title*) cat "$D/pr.json"; exit 0 ;;
              esac
              for a in "$@"; do case "$a" in https://*) n="${a##*/}" ;; esac; done
              [ -f "$D/state-$n.json" ] || { echo "not found" >&2; exit 1; }
              cat "$D/state-$n.json"
              exit 0
            fi
            exit 2

            """)

    let directory: URL
    let executable: URL

    /// `gated` なら、`release()` を呼ぶまで gh が返らない
    init(state: String, isDraft: Bool = false, url: String = "https://github.com/o/r/pull/1", gated: Bool = false) throws {
        try self.init(states: [url: state], isDraft: isDraft, url: url)
        if gated { try Data().write(to: directory.appendingPathComponent("gate")) }
    }

    func release() throws { try Data().write(to: directory.appendingPathComponent("release")) }

    /// URL（PR の番号）ごとに違う状態を返す。表に無い URL は gh が失敗したことにする（exit 1）
    init(states: [String: String], isDraft: Bool = false, url: String = "https://github.com/o/r/pull/1") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fakeprview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (link, state) in states {
            let number = link.split(separator: "/").last.map(String.init) ?? "1"
            try #"{"state":"\#(state)","isDraft":\#(isDraft),"statusCheckRollup":[],"reviewDecision":""}"#
                .write(to: directory.appendingPathComponent("state-\(number).json"), atomically: true, encoding: .utf8)
        }
        let first = states[url] ?? "OPEN"
        try #"{"number":1,"title":"PR 1","url":"\#(url)","isDraft":\#(isDraft),"state":"\#(first)"}"#
            .write(to: directory.appendingPathComponent("pr.json"), atomically: true, encoding: .utf8)
        executable = try Self.shared.link(in: directory, as: "gh")
    }
}

@Suite("PR 同期の向きと既定の起票先")
struct BoardProgressTests {
    private func makeSync(_ gh: FakePRView) throws -> (GitHubSync, Store, DaemonState) {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let cli = GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: gh.executable)
        return (GitHubSync(store: store, state: state, cli: cli), store, state)
    }

    /// 表示の順を、deploying → review → working → 残り にした案件
    private func reorderedBoard(_ store: Store) throws -> Board {
        let board = try store.createBoard(name: "a", columns: nil)
        let order = ["deploying", "review", "working", "standing", "review_req", "todo", "planning", "done", "wontfix"]
        let columns = order.map { id in edits(board).first { $0.id == id }! }
        return try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns))
    }

    @Test("表示で後ろに並べた列へも、既定の進む順で前なら進める")
    func advancesByProgressOrder() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, _) = try makeSync(gh)
        let board = try reorderedBoard(store)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x", links: ["https://github.com/o/r/pull/1"]))
        let moved = try await sync.syncNow(task: task)
        #expect(moved?.columnID == "review")
    }

    @Test("表示で前に並べ替えても、既定の進む順で後ろへは戻さない")
    func doesNotMoveBackward() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, _) = try makeSync(gh)
        let board = try reorderedBoard(store)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "deploying", title: "x", links: ["https://github.com/o/r/pull/1"]))
        #expect(try await sync.syncNow(task: task) == nil)
        #expect(try store.task(number: task.number)?.columnID == "deploying")
    }

    @Test("マージしたら、案件の「マージしたら」の列へ進める（既定はデプロイ中、完了へも選べる）")
    func mergedFollowsBoardTarget() async throws {
        let gh = try FakePRView(state: "MERGED")
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        #expect(board.mergeTarget == .deploying)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review", title: "x", links: ["https://github.com/o/r/pull/1"]))
        await state.upsert(task)
        #expect(try await sync.syncNow(task: task)?.columnID == "deploying")

        _ = try store.updateBoard(id: board.id, BoardUpdateRequest(mergeTarget: .done))
        #expect(try store.boards().first?.mergeTarget == .done)
        let other = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "deploying", title: "y", links: ["https://github.com/o/r/pull/1"]))
        await state.upsert(other)
        #expect(try await sync.syncNow(task: other)?.columnID == "done")
    }

    @Test("レビュー依頼のタスクは、紐づく PR の全部がマージかクローズになったら完了へ。1 本でも open か取れていなければ動かさない")
    func reviewRequestCompletes() async throws {
        let one = "https://github.com/o/r/pull/1"
        let two = "https://github.com/o/r/pull/2"
        let three = "https://github.com/o/r/pull/3"
        let gh = try FakePRView(states: [one: "MERGED", two: "OPEN", three: "CLOSED"])
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)

        let partlyOpen = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review_req", title: "x", links: [one, two]))

        await state.upsert(partlyOpen)
        #expect(try await sync.syncNow(task: partlyOpen) == nil)
        let unfetched = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review_req", title: "y", links: [one, "https://github.com/o/r/pull/9"]))
        await state.upsert(unfetched)
        #expect(try await sync.syncNow(task: unfetched) == nil)
        let allClosed = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review_req", title: "z", links: [one, three]))
        await state.upsert(allClosed)
        #expect(try await sync.syncNow(task: allClosed)?.columnID == "done")
        let stillOpen = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review_req", title: "w", links: [two]))
        await state.upsert(stillOpen)
        #expect(try await sync.syncNow(task: stillOpen) == nil, "レビュー依頼は open の PR で review へは進めない")
    }

    @Test("常設のタスクは、PR が ready でもマージでも動かさない")
    func standingStays() async throws {
        for state in ["OPEN", "MERGED"] {
            let gh = try FakePRView(state: state)
            let (sync, store, _) = try makeSync(gh)
            let board = try store.createBoard(name: "a", columns: nil)
            let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "standing", title: "運用", links: ["https://github.com/o/r/pull/1"]))
            #expect(try await sync.syncNow(task: task) == nil, "\(state)")
            #expect(try store.task(number: task.number)?.columnID == "standing")
        }
    }

    @Test("「マージしたら」の列（デプロイ中）を消した案件では、マージしたタスクを完了へ進める")
    func mergedFallsBackToDone() async throws {
        let gh = try FakePRView(state: "MERGED")
        let (sync, store, _) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        let without = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: edits(board).filter { $0.id != "deploying" }))
        #expect(without.mergeTarget == .deploying, "設定の値は残る")
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review", title: "x", links: ["https://github.com/o/r/pull/1"]))
        #expect(try await sync.syncNow(task: task)?.columnID == "done")
    }

    @Test("今すぐの同期は、前にマージかクローズを見たリンクを取り直さず、open のリンクだけを取り直す")
    func syncNowSkipsFinished() async throws {
        let merged = "https://github.com/o/r/pull/1"
        let open = "https://github.com/o/r/pull/2"
        let gh = try FakePRView(states: [merged: "MERGED", open: "OPEN"])
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x", links: [merged, open]))
        await state.upsert(task)
        _ = try await sync.syncNow(task: task)
        #expect(await state.linkStatuses().count == 2)

        // 取り直せば、1 は gh の失敗になり、2 はマージになる
        try FileManager.default.removeItem(at: gh.directory.appendingPathComponent("state-1.json"))
        try #"{"state":"MERGED","isDraft":false,"statusCheckRollup":[],"reviewDecision":""}"#
            .write(to: gh.directory.appendingPathComponent("state-2.json"), atomically: true, encoding: .utf8)
        _ = try await sync.syncNow(task: try #require(try store.task(number: task.number)))

        let statuses = Dictionary(uniqueKeysWithValues: await state.linkStatuses().map { ($0.url, $0) })
        #expect(statuses[merged]?.error == nil)
        #expect(statuses[merged]?.pullRequest?.state == .merged)
        #expect(statuses[open]?.pullRequest?.state == .merged)
    }

    @Test("レビュー中を消した案件では、ready の PR でも動かさない")
    func missingReviewStays() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, _) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        _ = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: edits(board).filter { $0.id != "review" }))
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x", links: ["https://github.com/o/r/pull/1"]))
        #expect(try await sync.syncNow(task: task) == nil)
    }

    @Test("足した列にあるタスクは PR の状態で動かさない")
    func customColumnStays() async throws {
        let gh = try FakePRView(state: "MERGED")
        let (sync, store, _) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        let added = try store.updateBoard(
            id: board.id, BoardUpdateRequest(columns: [BoardColumnEdit(id: nil, label: "保留", kind: .open, collapsed: false)] + edits(board)))
        let task = try store.createTask(
            TaskCreateRequest(boardID: board.id, columnID: added.columns[0].id, title: "x", links: ["https://github.com/o/r/pull/1"]))
        #expect(try await sync.syncNow(task: task) == nil)
    }

    @Test("hook の起票はアーカイブした案件を飛ばし、position の先頭の使える案件に入れる")
    func hookSkipsArchived() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, state) = try makeSync(gh)
        let first = try store.createBoard(name: "first", columns: nil)
        let second = try store.createBoard(name: "second", columns: nil)
        _ = try store.updateBoard(id: first.id, BoardUpdateRequest(archived: true))
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("hookcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let hooks = HookService(store: store, state: state, github: sync)
        let response = try await hooks.stop(HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "s-1", cwd: cwd.path))
        let created = try #require(response.task)
        #expect(created.boardID == second.id)
        #expect(created.columnID == "review")
    }

    @Test("hook: 結ばれたセッションのブランチの PR がどのタスクにも無ければ、そのタスクにリンクする。ほかのタスクにあれば足さない")
    func hookLinksBranchPR() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        let mine = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "mine"))
        let other = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "other"))
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("hookcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        _ = try store.linkSession(task: mine.number, agent: "claude", sessionID: "s-mine", cwd: cwd.path, label: "")
        _ = try store.linkSession(task: other.number, agent: "claude", sessionID: "s-other", cwd: cwd.path, label: "")

        let hooks = HookService(store: store, state: state, github: sync)
        let response = try await hooks.stop(HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "s-mine", cwd: cwd.path))
        #expect(response.task?.number == mine.number)
        #expect(try store.task(number: mine.number)?.links.map(\.url) == ["https://github.com/o/r/pull/1"])
        #expect(response.messages.contains { $0.contains("PR #1 をタスク #\(mine.number) にリンクした") })

        let again = try await hooks.stop(HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "s-other", cwd: cwd.path))
        #expect(again.task?.number == other.number)
        #expect(try store.task(number: other.number)?.links.isEmpty == true)
        #expect(!again.messages.contains { $0.contains("リンクした") })
    }

    @Test("host の会話の Stop: 待ちの見直しは gh を待たずに返し、ブランチの PR のリンクは後で付ける")
    func conversationStopDoesNotWaitForGitHub() async throws {
        let gh = try FakePRView(state: "OPEN", gated: true)
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "mine"))
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("hookcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        _ = try store.linkSession(task: task.number, agent: "claude", sessionID: "s-1", cwd: cwd.path, label: "")
        let waiting = try store.createWorkItem(
            task: task.number, WorkItemCreateRequest(title: "設計の承認", state: .wait, blockerKind: .approval, blockerText: "計画の承認待ち"))

        let hooks = HookService(store: store, state: state, github: sync)
        let reminder = try await hooks.stopConversation(
            HookStopRequest(
                agent: "claude", agentSessionID: "s-1", cwd: cwd.path, turnStartedAt: waiting.updatedAt.addingTimeInterval(60), turnUsedTools: true))
        #expect(reminder?.contains("設計の承認") == true)
        #expect(try store.task(number: task.number)?.links.isEmpty == true)

        try gh.release()
        let deadline = Date().addingTimeInterval(10)
        while try store.task(number: task.number)?.links.isEmpty == true, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(try store.task(number: task.number)?.links.map(\.url) == ["https://github.com/o/r/pull/1"])
    }

    @Test("hook の起票: レビュー中を消した案件では、常設とレビュー依頼を除く最初の進行中の列に入れる")
    func hookSkipsStanding() async throws {
        let gh = try FakePRView(state: "OPEN")
        let (sync, store, state) = try makeSync(gh)
        let board = try store.createBoard(name: "a", columns: nil)
        _ = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: edits(board).filter { $0.id != "review" }))
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("hookcwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let hooks = HookService(store: store, state: state, github: sync)
        let response = try await hooks.stop(HookStopRequest(paneID: nil, agent: "claude", agentSessionID: "s-2", cwd: cwd.path))
        let created = try #require(response.task)
        #expect(created.columnID == "todo")
    }
}
