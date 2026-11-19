import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("Store")
struct StoreTests {
    private let machine = MachineID(rawValue: "m-test")

    private func sampleImport(boardName: String = "default") -> TaskherdImportRequest {
        let t0 = Date(timeIntervalSince1970: 1_756_000_000)
        return TaskherdImportRequest(
            boardName: boardName, columns: BoardColumn.standard,
            tasks: [
                .init(
                    id: 1, title: "Review console#552", status: "done", due: "2026-08-25", note: "",
                    sessions: [.init(agent: "claude", sessionID: "a46c4b36-0000", cwd: "/Users/u/dev/das", label: "", linkedAt: t0)],
                    links: [.init(url: "https://github.com/Example-Org/console/pull/552", kind: "github_pr", note: "", addedAt: t0)],
                    createdAt: t0, updatedAt: t0),
                .init(
                    id: 7, title: "[PROJ-807] 確認画面", status: "todo", due: nil, note: "memo", sessions: [],
                    links: [.init(url: "https://example0.atlassian.net/browse/PROJ-807", kind: "jira", note: "", addedAt: t0)],
                    createdAt: t0, updatedAt: t0),
            ])
    }

    @Test("タスクのブラウザの保存先と消す予約が残った DB も開け、タスクを作る・移す・消すことができる")
    func opensDatabaseWithBrowserLeftovers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-browser-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        let backups = dir.appending(path: "backups")
        do {
            let store = try Store(databaseURL: url, backupDirectory: backups, machineID: machine)
            _ = try store.importTaskherd(sampleImport())
            try store.close()
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "UPDATE task SET browserProfileId = 'p-7', terminalSince = updatedAt WHERE number = 7")
                try db.execute(
                    sql: "INSERT INTO browserCleanup (browserProfileId, reason, taskNumber, state, reservedAt) VALUES ('p-1', 'deleted', 1, 'pending', ?)",
                    arguments: [Date()])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: backups, machineID: machine)
        defer { try? store.close() }
        let board = try #require(try store.boards().first)
        #expect(try store.updateTask(number: 7, TaskUpdateRequest(columnID: "done")).columnID == "done")
        try store.deleteTask(number: 1)
        let created = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "新しい"))
        #expect(try store.tasks().map(\.number).sorted() == [7, created.number])
    }

    @Test("taskherd の取り込みは番号を保ち、2 回目は何も変えない")
    func importIsIdempotent() throws {
        let store = try Store(inMemory: machine)
        let (first, tasks, board) = try store.importTaskherd(sampleImport())
        #expect(first.inserted == 2 && first.updated == 0 && first.unchanged == 0)
        #expect(board.name == "default")
        #expect(board.columns.map(\.id) == BoardColumn.standard.map(\.id))
        #expect(tasks.map(\.number) == [1, 7], "taskherd の id を番号として保つ")
        #expect(tasks[0].links.first?.kind == .githubPR)
        #expect(tasks[0].sessions.first?.sessionID == "a46c4b36-0000")
        #expect(tasks[1].links.first?.kind == .jira)
        #expect(tasks[0].importedID == 1)

        let (second, _, _) = try store.importTaskherd(sampleImport())
        #expect(second.inserted == 0 && second.updated == 0 && second.unchanged == 2)
        #expect(try store.tasks().count == 2)
        #expect(try store.boards().count == 1)
    }

    @Test("取り込み元で status が変わったら列が動き、未知の status は列として足される")
    func importUpdatesChangedTasks() throws {
        let store = try Store(inMemory: machine)
        _ = try store.importTaskherd(sampleImport())
        var request = sampleImport()
        request.tasks[1].status = "blocked_by_vendor"
        request.tasks[1].updatedAt = Date(timeIntervalSince1970: 1_756_100_000)
        let (result, tasks, board) = try store.importTaskherd(request)
        #expect(result.updated == 1 && result.unchanged == 1 && result.inserted == 0)
        #expect(tasks.first { $0.number == 7 }?.columnID == "blocked_by_vendor")
        #expect(board.columns.contains { $0.id == "blocked_by_vendor" && $0.kind == .open })
    }

    @Test("daemon 側で先に動いたタスクは、取り込み元の古い値で戻さない")
    func importKeepsNewerLocalRows() throws {
        let store = try Store(inMemory: machine)
        _ = try store.importTaskherd(sampleImport())
        // PR の状態による前進（updatedAt が取り込み元より新しくなる）
        let moved = try store.updateTask(number: 7, TaskUpdateRequest(columnID: "deploying"))
        #expect(moved.updatedAt > Date(timeIntervalSince1970: 1_756_000_000))
        let (result, tasks, _) = try store.importTaskherd(sampleImport())
        #expect(result.updated == 0 && result.keptLocal == 1 && result.unchanged == 1)
        #expect(tasks.first { $0.number == 7 }?.columnID == "deploying")
        // 取り込み元がさらに新しければ採る
        var request = sampleImport()
        request.tasks[1].status = "done"
        request.tasks[1].updatedAt = Date().addingTimeInterval(60)
        let (second, after, _) = try store.importTaskherd(request)
        #expect(second.updated == 1 && second.keptLocal == 0)
        #expect(after.first { $0.number == 7 }?.columnID == "done")
    }

    @Test("新しいタスクは次の番号を取り、更新で列・期日・リンクが変わる")
    func createAndUpdate() throws {
        let store = try Store(inMemory: machine)
        let (_, _, board) = try store.importTaskherd(sampleImport())
        let created = try store.createTask(
            TaskCreateRequest(boardID: board.id, columnID: "todo", title: "新しい", links: ["https://github.com/ukwhatn/taskboard/pull/3"]))
        #expect(created.number == 8)
        #expect(created.links.first?.kind == .githubPR)
        #expect(created.links.first?.shortLabel == "taskboard#3")

        let updated = try store.updateTask(
            number: created.number,
            TaskUpdateRequest(columnID: "working", due: "2026-10-10", addLinks: ["https://example.com/spec"], removeLinkIDs: [created.links[0].id]))
        #expect(updated.columnID == "working")
        #expect(updated.due == "2026-10-10")
        #expect(updated.links.map(\.kind) == [.other])

        let cleared = try store.updateTask(number: created.number, TaskUpdateRequest(clearDue: true))
        #expect(cleared.due == nil)

        #expect(throws: StoreError.columnNotFound("nope")) {
            try store.updateTask(number: created.number, TaskUpdateRequest(columnID: "nope"))
        }
        #expect(throws: StoreError.taskNotFound(999)) {
            try store.updateTask(number: 999, TaskUpdateRequest(title: "x"))
        }
        try store.deleteTask(number: created.number)
        #expect(try store.task(number: created.number) == nil)
    }

    @Test("backup は 3 世代に回り、verify で件数が読める")
    func backupRotation() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(databaseURL: dir.appending(path: "taskboard.db"), backupDirectory: dir.appending(path: "backups"), machineID: machine)
        _ = try store.importTaskherd(sampleImport())
        var urls: [URL] = []
        for i in 0..<5 {
            urls.append(try store.backup(label: "t\(i)"))
        }
        let remaining = try Store.listBackups(in: dir.appending(path: "backups"))
        #expect(remaining.count == 3)
        #expect(remaining.map(\.lastPathComponent) == urls.suffix(3).map(\.lastPathComponent))
        let counts = try Store.verify(backupAt: remaining.last!)
        #expect(counts.boards == 1 && counts.tasks == 2)
        try store.close()
    }

    @Test("2 回目に開いても migration は走らず、backup も増えない")
    func reopenWithoutMigration() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appending(path: "taskboard.db")
        let backups = dir.appending(path: "backups")
        do {
            let store = try Store(databaseURL: db, backupDirectory: backups, machineID: machine)
            _ = try store.importTaskherd(sampleImport())
            try store.close()
        }
        let reopened = try Store(databaseURL: db, backupDirectory: backups, machineID: machine)
        #expect(try reopened.tasks().count == 2)
        #expect(try Store.listBackups(in: backups).isEmpty)
        try reopened.close()
    }

    @Test("ファイルの DB では、書きのトランザクションの途中でも読みは待たずに終わり、commit 前の行は見えない")
    func readsDoNotWaitForWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(databaseURL: dir.appending(path: "taskboard.db"), backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        let board = try store.createBoard(name: "a", columns: nil)
        final class Box: @unchecked Sendable { var count: Int? }
        let box = Box()
        let inWrite = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0)
        let writeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.database.write { db in
                try db.execute(
                    sql: "INSERT INTO task (boardId, columnId, title, note, createdAt, updatedAt) VALUES (?, 'todo', 't', '', ?, ?)",
                    arguments: [board.id, Date(), Date()])
                inWrite.signal()
                release.wait()
            }
            writeDone.signal()
        }
        inWrite.wait()
        DispatchQueue.global().async {
            box.count = try? store.tasks().count
            readDone.signal()
        }
        let readFinished = readDone.wait(timeout: .now() + 5) == .success
        release.signal()
        writeDone.wait()
        if !readFinished { readDone.wait() }
        #expect(readFinished, "書きの commit を待たずに読み終わる")
        #expect(box.count == 0, "commit 前の行は読みに見えない")
        #expect(try store.tasks().count == 1)
    }

    @Test("v19 の DB に v20 を当てると、未受領の回答とセッションの結びを引く index ができ、前の回答は未受領のまま読める")
    func migrationV20() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v20-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v19 conversation purposes and parents")
            try queue.write { db in
                try db.execute(sql: "INSERT INTO board (id, name, position, createdAt) VALUES ('b1', 'default', 0, ?)", arguments: [t0])
                try db.execute(
                    sql: "INSERT INTO task (number, boardId, columnId, title, note, createdAt, updatedAt) VALUES (7, 'b1', 'todo', 't', '', ?, ?)",
                    arguments: [t0, t0])
                try db.execute(
                    sql: "INSERT INTO taskSession (taskNumber, agent, sessionId, cwd, label, linkedAt) VALUES (7, 'claude', 's1', '/w', '', ?)", arguments: [t0])
                try db.execute(sql: "INSERT INTO doc (id, taskNumber, name, format, createdAt, updatedAt) VALUES (1, 7, 'q.md', 'markdown', ?, ?)", arguments: [t0, t0])
                try db.execute(
                    sql: "INSERT INTO ask (taskNumber, docId, status, questions, answers, createdAt, answeredAt) VALUES (7, 1, 'answered', '[]', '[]', ?, ?)",
                    arguments: [t0, t0])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")
        let plans = try store.database.read { db in
            try [
                "SELECT * FROM ask WHERE taskNumber = 7 AND status = 'answered' AND deliveredAt IS NULL",
                "SELECT * FROM docComment WHERE reviewId = 1",
                "SELECT * FROM commentReply WHERE reviewId = 1",
                "SELECT * FROM taskSession WHERE sessionId = 's1' ORDER BY id DESC LIMIT 1",
            ].map { sql in try String.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, adapter: ColumnMapping(["detail": "detail"])).joined(separator: " / ") }
        }
        #expect(plans[0].contains("USING INDEX ask_task"), "\(plans[0])")
        #expect(plans[1].contains("USING INDEX docComment_review"), "\(plans[1])")
        #expect(plans[2].contains("USING INDEX commentReply_review"), "\(plans[2])")
        #expect(plans[3].contains("USING INDEX taskSession_session"), "\(plans[3])")
        #expect(try store.tasksWithUndeliveredFeedback() == [7])
        #expect(try store.peekUndeliveredFeedback(task: 7).askIDs == [1])
        #expect(try store.taskNumber(linkedToSession: "s1") == 7 && store.taskNumber(linkedToSession: "s2") == nil)
    }
}

@Suite("WaitLine")
struct WaitLineTests {
    private let machine = MachineID(rawValue: "m-test")
    private let calendar = Calendar(identifier: .gregorian)
    private var today: Date { BoardTask.dateFormatter.date(from: "2026-10-03")! }

    private func task(due: String? = nil, updatedDaysAgo: Int = 0, sessionIDs: [String] = []) -> BoardTask {
        let updated = calendar.date(byAdding: .day, value: -updatedDaysAgo, to: today)!
        return BoardTask(
            machine: machine, number: 1, boardID: "b", columnID: "working", title: "t", due: due,
            sessions: sessionIDs.map { TaskSessionRef(id: 1, agent: "claude", sessionID: $0, cwd: "", linkedAt: updated) },
            createdAt: updated, updatedAt: updated)
    }

    @Test("リンクの種別と短い表記")
    func linkKinds() {
        #expect(TaskLink.kind(of: "https://github.com/Example-Org/console/pull/552") == .githubPR)
        #expect(TaskLink.kind(of: "https://github.com/ukwhatn/taskboard/issues/4") == .githubIssue)
        #expect(TaskLink.kind(of: "https://ghe.example.com/org/repo/pull/9", ghesHosts: ["ghe.example.com"]) == .githubPR)
        #expect(TaskLink.kind(of: "https://ghe.example.com/org/repo/pull/9") == .other)
        #expect(TaskLink.kind(of: "https://example0.atlassian.net/browse/PROJ-807") == .jira)
        #expect(TaskLink.kind(of: "not a url") == .other)
        #expect(TaskLink.kind(of: "") == .other)
        let pr = TaskLink(id: 1, url: "https://github.com/Example-Org/console/pull/552", kind: .githubPR, addedAt: Date())
        #expect(pr.shortLabel == "console#552")
        let jira = TaskLink(id: 2, url: "https://example0.atlassian.net/browse/PROJ-807", kind: .jira, addedAt: Date())
        #expect(jira.shortLabel == "PROJ-807")
        let other = TaskLink(id: 3, url: "https://example.com/a/b", kind: .other, addedAt: Date())
        #expect(other.shortLabel == "example.com")
    }
}
