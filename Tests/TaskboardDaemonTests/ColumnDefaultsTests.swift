import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

private let machine = MachineID(rawValue: "m-test")

private func edits(_ board: Board) -> [BoardColumnEdit] {
    board.columns.map { BoardColumnEdit(id: $0.id, label: $0.label, kind: $0.kind, collapsed: $0.collapsed) }
}

@Suite("列の既定: 常設・説明・消せる既定の列")
struct ColumnDefaultsTests {
    @Test("新しい案件は常設を先頭にした 9 列で、既定の列は既定の説明を持つ")
    func newBoardColumns() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        #expect(board.columns.map(\.id) == ["standing", "review_req", "todo", "planning", "working", "review", "deploying", "done", "wontfix"])
        #expect(board.columns.map(\.label) == ["常設", "レビュー依頼", "未着手", "計画", "作業中", "レビュー中", "デプロイ中", "完了", "見送り"])
        #expect(board.columns[0].kind == .open && !board.columns[0].collapsed)
        #expect(board.columns[0].description == "期限なく続く仕事（定常の運用・問い合わせ対応など）。完了にしない")
        #expect(board.columns.allSatisfy { !$0.description.isEmpty })
    }

    @Test("v13 の DB に v14 を当てると、全部の案件の先頭に常設が入り、ほかの列は 1 つ後ろへずれ、説明が空の既定の列だけ埋まる")
    func migrationAddsStanding() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v14-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        let old = ["review_req", "todo", "planning", "working", "review", "deploying", "done", "wontfix"]
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v13 device push")
            try queue.write { db in
                for (board, ids) in [("b1", old + ["c-hold"]), ("b2", ["todo", "done"])] {
                    try db.execute(sql: "INSERT INTO board (id, name, position, createdAt) VALUES (?, ?, 0, ?)", arguments: [board, board, Date()])
                    for (index, id) in ids.enumerated() {
                        try db.execute(
                            sql: "INSERT INTO boardColumn (boardId, id, label, kind, position) VALUES (?, ?, ?, ?, ?)",
                            arguments: [board, id, id, id == "done" || id == "wontfix" ? "terminal" : "open", index])
                    }
                }
                try db.execute(
                    sql: "INSERT INTO task (boardId, columnId, title, createdAt, updatedAt) VALUES ('b1', 'working', 't', ?, ?)", arguments: [Date(), Date()])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")

        let boards = try store.boards()
        let b1 = try #require(boards.first { $0.id == "b1" })
        #expect(b1.columns.map(\.id) == ["standing"] + old + ["c-hold"])
        #expect(b1.columns.map(\.position) == Array(0..<10))
        #expect(b1.columns.first { $0.id == "working" }?.description == "実装・調査を進めている")
        #expect(b1.columns.first { $0.id == "working" }?.label == "working", "名前は変えない")
        #expect(b1.columns.last?.description == "", "足した列の説明は空のまま")
        let b2 = try #require(boards.first { $0.id == "b2" })
        #expect(b2.columns.map(\.id) == ["standing", "todo", "done"])
        #expect(try store.tasks().first?.columnID == "working")
    }

    @Test("常設を足すのは 1 回だけで、人が書いた説明は上書きしない")
    func addStandingIsIdempotent() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        var columns = edits(board)
        columns[1].description = "自分の説明"
        _ = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns))
        try store.database.write { db in
            try Store.addStandingColumns(db)
            try Store.addStandingColumns(db)
        }
        let after = try #require(try store.boards().first)
        #expect(after.columns.map(\.id) == BoardColumn.standard.map(\.id))
        #expect(after.columns[1].description == "自分の説明")
    }

    @Test("完了以外の既定の列は消せ、タスクがあれば移す先を選ぶ。消した列は id で戻せ、既定の説明とテンプレートで戻る")
    func removeAndRestoreStandard() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "review_req", title: "x"))
        let without = edits(board).filter { $0.id != "review_req" && $0.id != "standing" }
        #expect(throws: StoreError.refused(.columnHasTasks, ["label": "レビュー依頼", "count": "1"], "列「レビュー依頼」にタスクが 1 件ある: 移す先の列を選ぶ")) {
            try store.updateBoard(id: board.id, BoardUpdateRequest(columns: without))
        }
        let removed = try store.editBoard(id: board.id, BoardUpdateRequest(columns: without, reassign: ["review_req": "todo"]))
        #expect(removed.board.columns.map(\.id) == ["todo", "planning", "working", "review", "deploying", "done", "wontfix"])
        #expect(removed.movedTasks.map(\.number) == [task.number])

        var restore = edits(removed.board)
        restore.insert(BoardColumnEdit(id: "review_req", label: "レビュー依頼", kind: .open, collapsed: false), at: 0)
        let restored = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: restore))
        let column = try #require(restored.columns.first)
        #expect(column.id == "review_req" && column.position == 0)
        #expect(column.description == ColumnGuide.defaultDescriptions["review_req"])
        #expect(column.promptTemplate == PromptTemplate.defaultReviewRequestTemplate)

        var wrongKind = edits(restored)
        wrongKind.insert(BoardColumnEdit(id: "standing", label: "常設", kind: .terminal, collapsed: true), at: 0)
        #expect(throws: StoreError.refused(.defaultColumnLocked, ["label": "常設", "change": "kind"], "既定の列「常設」の完了扱いは変えられない")) {
            try store.updateBoard(id: board.id, BoardUpdateRequest(columns: wrongKind))
        }
    }

    @Test("列の説明は置き換えで書け、前後の空白を落とす。nil は今の説明を残す")
    func editDescriptions() throws {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        var columns = edits(board)
        columns[2].description = "  今週やる\n2 行目  "
        columns.append(BoardColumnEdit(id: nil, label: "保留", kind: .open, collapsed: false, description: "人の返事を待つ"))
        let updated = try store.updateBoard(id: board.id, BoardUpdateRequest(columns: columns))
        #expect(updated.columns[2].description == "今週やる\n2 行目")
        #expect(updated.columns.last?.description == "人の返事を待つ")
        #expect(updated.columns[3].description == ColumnGuide.defaultDescriptions["planning"], "nil の編集は今の説明を残す")
    }

    @Test("別の案件へ移すとき、同じ列が無ければ常設とレビュー依頼を除く最初の進行中の列に入る")
    func moveToBoardSkipsStanding() throws {
        let store = try Store(inMemory: machine)
        let a = try store.createBoard(name: "a", columns: nil)
        let b = try store.createBoard(name: "b", columns: nil)
        _ = try store.updateBoard(id: b.id, BoardUpdateRequest(columns: edits(b).filter { $0.id != "planning" }))
        let task = try store.createTask(TaskCreateRequest(boardID: a.id, columnID: "planning", title: "x"))
        let moved = try store.updateTask(number: task.number, TaskUpdateRequest(boardID: b.id))
        #expect(moved.columnID == "todo")
    }
}
