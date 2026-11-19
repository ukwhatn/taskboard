import Foundation
import GRDB
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の記録")
struct ConversationStoreTests {
    private let machine = MachineID(rawValue: "m-test")
    private let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func storeWithTasks() throws -> (Store, BoardTask, BoardTask) {
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let first = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "会話のタスク"))
        let second = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "別のタスク"))
        return (store, first, second)
    }

    @Test("作るときに Claude の会話 ID をタスクに結ぶ（SessionStart を待たない）")
    func createLinks() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        #expect(try store.task(linkedToSession: "s1")?.number == task.number)
        #expect(try store.conversation(agentSessionID: "s1")?.id == record.id)
        #expect(try store.conversation(id: record.id)?.runnerValue == .host)
    }

    @Test("人が付けた名前は自動の題と別の欄に残り、会話の題には名前を出す。engine が知らせた題は、自動の題と同じか人の名前と同じ（送り返し）なら取らない")
    func customTitle() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(
            ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", title: "#1 会話のタスク", runner: .none, createdAt: t0))
        var named = try store.updateConversation(id: record.id) { $0.customTitle = "依存の版" }
        #expect(try store.conversation(id: record.id)?.customTitle == "依存の版")
        #expect(Conversation(record: named, machine: machine).title == "依存の版")
        #expect(Conversation(record: named, machine: machine).customTitle == "依存の版")
        let echoed = named.takeReportedTitle("依存の版")
        let same = named.takeReportedTitle("#1 会話のタスク")
        let reported = named.takeReportedTitle("CLI の題")
        #expect(!echoed && !same && reported)
        #expect(named.title == "CLI の題" && named.customTitle == "依存の版")
        named.customTitle = nil
        #expect(Conversation(record: named, machine: machine).title == "CLI の題")
        #expect(Conversation(record: named, machine: machine).customTitle == nil)
    }

    @Test("タスクの無い会話も作れる。無いタスクは断る")
    func taskless() throws {
        let (store, _, _) = try storeWithTasks()
        _ = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: "s0", cwd: "/w", runner: .host, createdAt: t0))
        #expect(try store.task(linkedToSession: "s0") == nil)
        #expect(throws: StoreError.self) {
            try store.createConversation(ConversationRecord(taskNumber: 999, agentSessionId: "s9", cwd: "/w", runner: .host, createdAt: t0))
        }
        #expect(try store.conversation(agentSessionID: "s9") == nil, "断ったら記録も残らない")
    }

    @Test("同じ Claude の会話 ID の記録は 2 つ作れない")
    func uniqueSession() throws {
        let (store, task, _) = try storeWithTasks()
        _ = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        #expect(throws: (any Error).self) {
            try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        }
    }

    @Test("/clear で会話 ID が変わったら、新しい ID も同じタスクに結び、前の ID も会話のものとして扱う")
    func sessionChange() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        let changed = try store.updateConversationSession(id: record.id, agentSessionID: "s2", at: t0.addingTimeInterval(60))
        #expect(changed.agentSessionId == "s2")
        #expect(try store.task(number: task.number)?.sessions.map(\.sessionID) == ["s1", "s2"])
        #expect(try store.task(linkedToSession: "s2")?.number == task.number)
        #expect(try store.conversation(record.id, owns: "s1") && store.conversation(record.id, owns: "s2"))
        #expect(try store.conversation(agentSessionID: "s1")?.id == record.id, "前の ID からも会話を引ける")
        #expect(try !store.conversation(record.id, owns: "nested"), "Bash から起こした別の claude の会話 ID は会話のものでない")
        #expect(try !store.conversation("unknown", owns: "s1"))
        _ = try store.updateConversationSession(id: record.id, agentSessionID: "s2")
        #expect(try store.task(number: task.number)?.sessions.map(\.sessionID) == ["s1", "s2"], "同じ ID を入れ直しても増えない")
        _ = try store.updateConversationSession(id: record.id, agentSessionID: "s1", at: t0.addingTimeInterval(120))
        #expect(try store.conversation(id: record.id)?.agentSessionId == "s1", "前の ID に戻せる（resume）")
    }

    @Test("ほかの会話の前の ID も、新しい会話や /clear の先にできない")
    func pastSessionTaken() throws {
        let (store, task, _) = try storeWithTasks()
        let first = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        _ = try store.updateConversationSession(id: first.id, agentSessionID: "s2")
        #expect(throws: StoreError.self) {
            try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        }
        let second = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s3", cwd: "/w", runner: .host, createdAt: t0))
        #expect(throws: StoreError.self) { try store.updateConversationSession(id: second.id, agentSessionID: "s1") }
        #expect(try store.conversation(agentSessionID: "s1")?.id == first.id)
    }

    @Test("会話の ID を別のタスクに結ぶと、会話の ID を全部移した先に結び、前のタスクから外す")
    func move() throws {
        let (store, first, second) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        _ = try store.updateConversationSession(id: record.id, agentSessionID: "s2")
        // /clear の前の ID で結んでも、会話ごと移る
        let moved = try store.linkSession(task: second.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        #expect(moved.sessions.map(\.sessionID) == ["s1", "s2"])
        #expect(try store.conversation(id: record.id)?.taskNumber == second.number)
        #expect(try store.task(linkedToSession: "s1")?.number == second.number && store.task(linkedToSession: "s2")?.number == second.number)
        #expect(try store.task(number: first.number)?.sessions.isEmpty == true, "前のタスクには残さない")
        #expect(throws: StoreError.taskNotFound(999)) { try store.linkSession(task: 999, agent: "claude", sessionID: "s1", cwd: "/w", label: "") }
    }

    @Test("移した先のタスクを消しても、前のタスクに戻らない")
    func moveThenDelete() throws {
        let (store, first, second) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        _ = try store.linkSession(task: second.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        try store.deleteTask(number: second.number)
        #expect(try store.task(linkedToSession: "s1") == nil)
        #expect(try store.conversation(id: record.id)?.taskNumber == nil)
    }

    @Test("TUI で 2 つのタスクに結んであった会話を取り込んで移しても、移した先を消したときにもっと前のタスクへ戻らない")
    func adoptTwiceLinked() throws {
        let (store, first, second) = try storeWithTasks()
        let board = try #require(store.boards().first)
        let third = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "3 つ目"))
        _ = try store.linkSession(task: first.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        _ = try store.linkSession(task: second.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        let record = try store.createConversation(ConversationRecord(taskNumber: second.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        #expect(try store.task(number: first.number)?.sessions.isEmpty == true, "取り込んだときに、ほかのタスクの行を消す")
        _ = try store.linkSession(task: third.number, agent: "claude", sessionID: "s1", cwd: "/w", label: "")
        try store.deleteTask(number: third.number)
        #expect(try store.task(linkedToSession: "s1") == nil)
    }

    @Test("会話の ID の紐づけを外すと、/clear の前の ID でも会話ごと外れる（会話のタスクも、ほかの ID の行も）。外した後にもう一度外すと 404")
    func unlinkConversation() throws {
        let (store, first, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        _ = try store.updateConversationSession(id: record.id, agentSessionID: "s2")
        let task = try store.unlinkSession(task: first.number, sessionID: "s1")
        #expect(task.sessions.isEmpty)
        #expect(try store.conversation(id: record.id)?.taskNumber == nil)
        #expect(try store.task(linkedToSession: "s1") == nil && store.task(linkedToSession: "s2") == nil)
        #expect(throws: StoreError.self) { try store.unlinkSession(task: first.number, sessionID: "s2") }
    }

    @Test("updateConversation の closure が紐づけの列（タスクと Claude の会話 ID）を書いても戻す。ほかの列は書く")
    func updateKeepsBinding() throws {
        let (store, first, second) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        let updated = try store.updateConversation(id: record.id) {
            $0.title = "題"
            $0.taskNumber = second.number
            $0.agentSessionId = "s9"
        }
        #expect(updated.title == "題" && updated.taskNumber == first.number && updated.agentSessionId == "s1")
        let stored = try #require(try store.conversation(id: record.id))
        #expect(stored.title == "題" && stored.taskNumber == first.number && stored.agentSessionId == "s1")
        #expect(try store.task(linkedToSession: "s1")?.number == first.number)
    }

    @Test("会話の ID を linkSession で結ぶと、会話ごと移る")
    func linkSessionMovesConversation() throws {
        let (store, first, second) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: first.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        _ = try store.updateConversationSession(id: record.id, agentSessionID: "s2")
        let linked = try store.linkSession(task: second.number, agent: "claude", sessionID: "s2", cwd: "/w", label: "")
        #expect(Set(linked.sessions.map(\.sessionID)) == ["s1", "s2"])
        #expect(try store.task(number: first.number)?.sessions.isEmpty == true)
        #expect(try store.conversation(id: record.id)?.taskNumber == second.number)
    }

    @Test("受けた発言の uuid は新しい順に 256 件まで持つ。同じものは足さない")
    func recentMessages() throws {
        var record = ConversationRecord(taskNumber: nil, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0)
        #expect(record.recentMessages.isEmpty)
        for index in 0..<300 { record.remember(message: "u\(index)") }
        record.remember(message: "u299")
        #expect(record.recentMessages.count == ConversationRecord.recentMessageLimit)
        #expect(record.recentMessages.first == "u299" && record.recentMessages.last == "u44")
    }

    @Test("タスクを消しても会話の記録は残り、タスクが外れる")
    func taskDeleted() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        try store.deleteTask(number: task.number)
        let left = try #require(try store.conversation(id: record.id))
        #expect(left.taskNumber == nil)
    }

    @Test("何が動かしているか・defer の問い・終わった理由を書き換える")
    func update() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        let stopped = try store.updateConversation(id: record.id, at: t0.addingTimeInterval(5)) {
            $0.runner = Conversation.Runner.none.rawValue
            $0.deferred = #"{"toolUseID":"toolu_q"}"#
            $0.lastExit = "質問を defer で終えた"
        }
        #expect(stopped.runnerValue == .none && stopped.deferred == #"{"toolUseID":"toolu_q"}"# && stopped.updatedAt == t0.addingTimeInterval(5))
        #expect(throws: StoreError.self) { try store.updateConversation(id: "missing") { $0.title = "x" } }
    }

    @Test("backup の検証は、会話の migration を通った DB に会話の表が無ければ断る")
    func verifyBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-conv-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(databaseURL: dir.appending(path: "taskboard.db"), backupDirectory: dir.appending(path: "backups"), machineID: machine)
        let board = try store.createBoard(name: "a", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "todo", title: "t"))
        _ = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        let url = try store.backup(label: "conv")
        try store.close()
        #expect(try Store.verify(backupAt: url).tasks == 1)
        let broken = try DatabaseQueue(path: url.path)
        try broken.write { db in try db.execute(sql: "DROP TABLE conversationSession") }
        try broken.close()
        #expect(throws: StoreError.missingTable("conversationSession")) { try Store.verify(backupAt: url) }
    }


    @Test("v18 の DB に v19 を当てると、前の会話は引数なし・役目なし・知らせなしで読め、定期起動の回は会話を持たない")
    func migrationV19() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v19-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v18 conversation forks and terminals")
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO conversation (id, engine, agentSessionId, cwd, runner, createdAt, updatedAt) VALUES ('c1', 'claude', 's1', '/w', 'none', ?, ?)",
                    arguments: [t0, t0])
                try db.execute(
                    sql: "INSERT INTO schedule (name, rule, cwd, kind, agentArgs, prompt, overlap, enabled, anchorAt, createdAt, updatedAt) VALUES ('a', ?, '/w', 'claude', '[]', '', 'skip', 1, ?, ?, ?)",
                    arguments: [String(decoding: try JSONEncoder().encode(ScheduleRule.interval(minutes: 60)), as: UTF8.self), t0, t0, t0])
                try db.execute(sql: "INSERT INTO scheduleRun (scheduleId, scheduledAt, trigger, requestId, createdAt) VALUES (1, ?, 'schedule', 'r1', ?)", arguments: [t0, t0])
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")
        let record = try #require(try store.conversation(id: "c1"))
        #expect(record.extraArguments.isEmpty && record.purposeValue == nil && !record.notifyParent)
        #expect(record.parentConversationId == nil && record.parentNoticeTurns == 0 && record.parentNoticeAt == nil && record.limitResumeAt == nil)
        let run = try #require(try store.scheduleRuns(id: 1).first)
        #expect(run.conversationID == nil && run.requestID == "r1")
        #expect(try store.conversationScheduleRuns().isEmpty)
    }

    @Test("v33 の DB に v34・v35 を当てると、pane で起こした定期起動の回は結果が残り、会話のシェルは新しい列で読める")
    func migrationV35() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "taskboard-v35-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "taskboard.db")
        do {
            let queue = try DatabaseQueue(path: url.path)
            try Store.migrator().migrate(queue, upTo: "v33 conversation search")
            try queue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO conversation (id, engine, agentSessionId, cwd, runner, createdAt, updatedAt, shellPaneId, terminalPaneId, parentPane)
                        VALUES ('c1', 'claude', 's1', '/w', 'host', ?, ?, 'shell-c1', 'w1:p2', 'w1:p3')
                        """,
                    arguments: [t0, t0])
                try db.execute(
                    sql: "INSERT INTO schedule (name, rule, cwd, kind, agentArgs, prompt, overlap, enabled, anchorAt, createdAt, updatedAt) VALUES ('a', ?, '/w', 'claude', '[]', '', 'skip', 1, ?, ?, ?)",
                    arguments: [String(decoding: try JSONEncoder().encode(ScheduleRule.interval(minutes: 60)), as: UTF8.self), t0, t0, t0])
                let launches: [(String, String, String?)] = [("r-done", "done", nil), ("r-failed", "failed", "作業ディレクトリが無い"), ("r-mid", "prompted", nil)]
                for (offset, (request, stage, error)) in launches.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO launch (id, stage, kind, agentName, cwd, error, createdAt, updatedAt) VALUES (?, ?, 'claude', 'claude', '/w', ?, ?, ?)",
                        arguments: [request, stage, error, t0, t0])
                    try db.execute(
                        sql: "INSERT INTO scheduleRun (scheduleId, scheduledAt, trigger, requestId, createdAt) VALUES (1, ?, 'schedule', ?, ?)",
                        arguments: [t0.addingTimeInterval(Double(offset) * 60), request, t0])
                }
            }
            try queue.close()
        }
        let store = try Store(databaseURL: url, backupDirectory: dir.appending(path: "backups"), machineID: machine)
        defer { try? store.close() }
        #expect(try Store.listBackups(in: dir.appending(path: "backups")).count == 1, "migration の前に backup を取る")
        #expect(try store.conversation(id: "c1")?.shellId == "shell-c1")
        let outcomes = Dictionary(uniqueKeysWithValues: try store.scheduleRuns(id: 1).map { ($0.requestID ?? "", $0) })
        #expect(outcomes["r-done"]?.outcome == .launched)
        #expect(outcomes["r-failed"]?.outcome == .failed && outcomes["r-failed"]?.error == "作業ディレクトリが無い")
        #expect(outcomes["r-mid"]?.outcome == .notStarted)
        #expect(try DatabaseQueue(path: url.path).read { try $0.tableExists("launch") } == false)
    }

    @Test("引数・役目・起こした側・知らせ・上限の待ちを書いて読み戻せる")
    func newColumnsRoundTrip() throws {
        let (store, task, _) = try storeWithTasks()
        let record = try store.createConversation(ConversationRecord(taskNumber: task.number, agentSessionId: "s1", cwd: "/w", runner: .host, createdAt: t0))
        let at = Store.storedDate(t0.addingTimeInterval(0.1234))
        _ = try store.updateConversation(id: record.id) {
            $0.extraArguments = ["--disallowedTools", "WebFetch"]
            $0.purpose = Conversation.Purpose.schedule.rawValue
            $0.parentConversationId = "p1"
            $0.notifyParent = true
            $0.parentNoticeTurns = 2
            $0.parentNoticeSeq = 41
            $0.parentNoticeAt = at
            $0.limitResumeAt = t0.addingTimeInterval(3660)
        }
        let read = try #require(try store.conversation(id: record.id))
        #expect(read.extraArguments == ["--disallowedTools", "WebFetch"] && read.purposeValue == .schedule)
        #expect(read.parentConversationId == "p1" && read.notifyParent && read.parentNoticeTurns == 2 && read.parentNoticeSeq == 41)
        #expect(read.parentNoticeAt == at, "書く前に DB の形に揃えた時刻は、読み直しても == で一致する")
        #expect(read.limitResumeAt == t0.addingTimeInterval(3660))
    }

    @Test("起こした側の付け替え：会話の子と、pane の Claude の会話から起こした子を移す。移す先自身は移さない")
    func reparent() throws {
        let (store, _, _) = try storeWithTasks()
        func make(_ session: String, _ change: (inout ConversationRecord) -> Void) throws -> String {
            let id = try store.createConversation(ConversationRecord(taskNumber: nil, agentSessionId: session, cwd: "/w", runner: .none, createdAt: t0)).id
            _ = try store.updateConversation(id: id, change)
            return id
        }
        let old = try make("s-old") { _ in }
        let target = try make("s-new") { $0.parentConversationId = old }
        let child = try make("s-child") { $0.parentConversationId = old }
        _ = try make("s-other") { _ in }
        #expect(Set(try store.reparentConversations(fromConversation: old, to: target)) == [child])
        #expect(try store.conversation(id: target)?.parentConversationId == old)
        #expect(try store.conversation(id: child)?.parentConversationId == target)
    }

    @Test("会話の回の失敗は、まだ結果の無い回にだけ書く（先に書いた理由を残す）")
    func scheduleRunFailureOnce() throws {
        let (store, _, _) = try storeWithTasks()
        let (schedule, _) = try store.createSchedule(ScheduleCreateRequest(name: "a", rule: .interval(minutes: 60), cwd: "/w", kind: .claude, prompt: ""), now: t0)
        let run = try #require(
            try store.recordScheduleRun(id: schedule.scheduleID, at: t0, trigger: .manual, skipped: nil, conversationID: { "conv-\($0)" }, now: t0))
        #expect(run.conversationID == "conv-\(run.id)" && run.requestID == nil)
        #expect(try store.scheduleRun(conversationID: "conv-\(run.id)")?.id == run.id)
        #expect(try store.conversationScheduleRuns().map(\.id) == [run.id])
        try store.markScheduleRunFailed(conversationID: "conv-\(run.id)", reason: "実行がエラーで終わりました")
        try store.markScheduleRunFailed(conversationID: "conv-\(run.id)", reason: "起動の途中でTaskboardが停止しました")
        #expect(try store.scheduleRuns(id: schedule.scheduleID).first?.error == "実行がエラーで終わりました")
        #expect(try store.conversationScheduleRuns().isEmpty)
    }
}
