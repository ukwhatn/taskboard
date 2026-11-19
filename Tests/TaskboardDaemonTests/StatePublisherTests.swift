import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Store に書いた分は `StatePublisher` が state に入れ、route は入れ終えてから応答する（応答を受けた時点で state が Store と揃っている）
@Suite("Store から state への反映")
struct StatePublisherTests {
    private let machine = MachineID(rawValue: "m-publish")
    private let token = "daemon-token"

    private struct Fixture {
        let state: DaemonState
        let store: Store
        let task: BoardTask
        let app: APIServer.App
    }

    private func fixture() async throws -> Fixture {
        let state = DaemonState(machine: MachineInfo(id: machine, name: "test-mac", daemonVersion: "test"))
        let store = try Store(inMemory: machine)
        let board = try store.createBoard(name: "default", columns: nil)
        let task = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "x"))
        await state.upsert(board)
        await state.upsert(task)
        var dependencies = testDependencies
        dependencies.store = store
        dependencies.feedback = FeedbackService(store: store, state: state)
        return Fixture(state: state, store: store, task: task, app: APIServer.application(state: state, token: token, port: 0, dependencies: dependencies))
    }

    private func send(_ client: some TestClientProtocol, _ method: HTTPRequest.Method, _ uri: String, _ body: some Encodable) async throws -> TestResponse {
        let data = try WireJSON.encoder().encode(body)
        return try await client.execute(
            uri: uri, method: method, headers: [.authorization: "Bearer \(token)", .contentType: "application/json"], body: ByteBuffer(bytes: data))
    }

    private func send(_ client: some TestClientProtocol, _ method: HTTPRequest.Method, _ uri: String) async throws -> TestResponse {
        try await client.execute(uri: uri, method: method, headers: [.authorization: "Bearer \(token)"])
    }

    private func stateWorkItems(_ state: DaemonState, task number: Int) async -> [WorkItem] {
        await state.snapshot().workItems.filter { $0.taskNumber == number }.sorted { $0.position < $1.position }
    }

    @Test("作業項目を足す・並べ替える・消すと、応答の時点で state の作業項目がそのタスクの Store の行と同じになる")
    func workItemsSettleBeforeResponse() async throws {
        let world = try await fixture()
        let number = world.task.number
        try await world.app.test(.router) { client in
            var ids: [Int64] = []
            for title in ["一", "二", "三"] {
                let response = try await send(client, .post, "/v1/tasks/\(number)/work", WorkItemCreateRequest(title: title))
                #expect(response.status == .ok)
                ids.append(try WireJSON.decoder().decode(WorkItem.self, from: response.body).itemID)
            }
            #expect(await stateWorkItems(world.state, task: number).map(\.title) == ["一", "二", "三"])

            // 末尾を先頭へ。ほかの項目の position も動く
            #expect(try await send(client, .patch, "/v1/work/\(ids[2])", WorkItemUpdateRequest(position: 0)).status == .ok)
            #expect(await stateWorkItems(world.state, task: number).map(\.title) == ["三", "一", "二"])
            let stored = try world.store.workItems(task: number)
            #expect(await stateWorkItems(world.state, task: number) == stored)

            #expect(try await send(client, .delete, "/v1/work/\(ids[0])").status == .noContent)
            #expect(await stateWorkItems(world.state, task: number).map(\.title) == ["三", "二"])
        }
    }

    @Test("文書を載せ直すと前の質問は state から落ち、新しい質問が載る。回答は state の質問に入り、文書を消すと文書と質問が state から消える")
    func documentsAndAsksSettleBeforeResponse() async throws {
        let world = try await fixture()
        let number = world.task.number
        let question: @Sendable (String) -> [AskQuestion] = { id in [AskQuestion(id: id, question: "どっち", options: [AskOption(label: "A"), AskOption(label: "B")])] }
        try await world.app.test(.router) { client in
            let first = try WireJSON.decoder().decode(
                DocPublishResponse.self,
                from: try await send(
                    client, .post, "/v1/tasks/\(number)/docs", DocPublishRequest(name: "p.md", format: .markdown, content: "1", questions: question("q1"))
                ).body)
            let firstAsk = try #require(first.askID)
            #expect(await world.state.document(id: first.document.docID) != nil)
            #expect(await world.state.snapshot().asks.map(\.askID) == [firstAsk])

            let second = try WireJSON.decoder().decode(
                DocPublishResponse.self,
                from: try await send(
                    client, .post, "/v1/tasks/\(number)/docs", DocPublishRequest(name: "p.md", format: .markdown, content: "2", questions: question("q2"))
                ).body)
            let secondAsk = try #require(second.askID)
            #expect(secondAsk != firstAsk)
            #expect(await world.state.snapshot().asks.map(\.askID) == [secondAsk])

            let answered = try await send(
                client, .post, "/v1/asks/\(secondAsk)/answer", AskAnswerRequest(answers: [AskAnswer(questionID: "q2", selected: ["B"])]))
            #expect(answered.status == .ok)
            #expect(await world.state.snapshot().asks.first { $0.askID == secondAsk }?.status == .answered)

            #expect(try await send(client, .delete, "/v1/docs/\(second.document.docID)").status == .noContent)
            #expect(await world.state.document(id: second.document.docID) == nil)
            #expect(await world.state.snapshot().asks.isEmpty)
        }
    }

    @Test("レビュー依頼は state に載り、レビューを送ると state から外れる")
    func reviewRequestSettlesBeforeResponse() async throws {
        let world = try await fixture()
        let number = world.task.number
        try await world.app.test(.router) { client in
            let requested = try await send(client, .post, "/v1/tasks/\(number)/review-request", ReviewRequestCreate(note: "見て"))
            #expect(requested.status == .ok)
            #expect(await world.state.snapshot().reviewRequests.map(\.note) == ["見て"])

            let submitted = try await send(client, .post, "/v1/tasks/\(number)/review/submit")
            #expect(submitted.status == .ok)
            #expect(await world.state.snapshot().reviewRequests.isEmpty)
        }
    }

    @Test("案件とタスクを作る・直す・消すと応答の時点で state に入る。完了の列へ移すと未回答の質問が state から落ち、タスクを消すと作業項目も消える")
    func boardsAndTasksSettleBeforeResponse() async throws {
        let world = try await fixture()
        try await world.app.test(.router) { client in
            let board = try WireJSON.decoder().decode(Board.self, from: try await send(client, .post, "/v1/boards", BoardCreateRequest(name: "別")).body)
            #expect(await world.state.allBoards().map(\.name).contains("別"))
            let renamed = try await send(client, .patch, "/v1/boards/\(board.id)", BoardUpdateRequest(name: "別の案件"))
            #expect(renamed.status == .ok)
            #expect(await world.state.allBoards().first { $0.id == board.id }?.name == "別の案件")

            let created = try WireJSON.decoder().decode(
                BoardTask.self, from: try await send(client, .post, "/v1/tasks", TaskCreateRequest(boardID: board.id, columnID: "working", title: "新")).body)
            #expect(await world.state.task(number: created.number)?.title == "新")
            let work = try await send(client, .post, "/v1/tasks/\(created.number)/work", WorkItemCreateRequest(title: "項目"))
            #expect(work.status == .ok)
            let published = try await send(
                client, .post, "/v1/tasks/\(created.number)/docs",
                DocPublishRequest(name: "q.md", format: .markdown, content: "?", questions: [AskQuestion(id: "q", question: "?", options: [AskOption(label: "A")])]))
            #expect(published.status == .ok)
            #expect(await world.state.snapshot().asks.count == 1)

            let finished = try await send(client, .patch, "/v1/tasks/\(created.number)", TaskUpdateRequest(title: "新しい題", columnID: "done"))
            #expect(finished.status == .ok)
            #expect(await world.state.task(number: created.number).map { [$0.title, $0.columnID] } == ["新しい題", "done"])
            #expect(await world.state.snapshot().asks.isEmpty)

            #expect(try await send(client, .delete, "/v1/tasks/\(created.number)").status == .noContent)
            #expect(await world.state.task(number: created.number) == nil)
            #expect(await stateWorkItems(world.state, task: created.number).isEmpty)

            #expect(try await send(client, .delete, "/v1/boards/\(board.id)").status == .noContent)
            #expect(await world.state.allBoards().contains { $0.id == board.id } == false)
        }
    }

    @Test("定期起動を作る（常設タスクも）・直す・消す、設定を変えると、応答の時点で state に入る")
    func schedulesAndSettingsSettleBeforeResponse() async throws {
        let world = try await fixture()
        try await world.app.test(.router) { client in
            let request = ScheduleCreateRequest(
                name: "毎時", rule: .interval(minutes: 60), cwd: "/tmp", kind: .claude, prompt: "p",
                newTask: .init(boardID: world.task.boardID, columnID: "standing"))
            let schedule = try WireJSON.decoder().decode(Schedule.self, from: try await send(client, .post, "/v1/schedules", request).body)
            let number = try #require(schedule.taskNumber)
            #expect(await world.state.task(number: number)?.title == "毎時")
            #expect(await world.state.snapshot().schedules.map(\.name) == ["毎時"])

            let renamed = try await send(client, .patch, "/v1/schedules/\(schedule.scheduleID)", ScheduleUpdateRequest(name: "毎時の点検"))
            #expect(renamed.status == .ok)
            #expect(await world.state.snapshot().schedules.map(\.name) == ["毎時の点検"])

            #expect(try await send(client, .delete, "/v1/schedules/\(schedule.scheduleID)").status == .noContent)
            #expect(await world.state.snapshot().schedules.isEmpty)

            let minutes = try #require(MachineSettings.idleStopChoices.last)
            let settings = try await send(client, .patch, "/v1/settings", MachineSettingsUpdate(idleStopMinutes: minutes))
            #expect(settings.status == .ok)
            #expect(await world.state.snapshot().settings?.idleStopMinutes == minutes)
        }
    }

    @Test("同じものが続けて流れたら 1 つにまとめ、通し番号は流した回数だけ進む")
    func changeLogCoalesces() {
        let log = StoreChangeLog()
        log.record([.task(1), .workItems(task: 1)])
        log.record([.task(1)])
        log.record([.document(7), .task(1)])
        log.record([])
        let taken = log.take()
        #expect(taken.changes == [.task(1), .workItems(task: 1), .document(7)])
        #expect(taken.through == 3)
        #expect(log.take().changes.isEmpty)
    }

    @Test("settled は呼んだ時点までに流れた分を入れ終えてから返る。Store から消えたタスクは state から外す")
    func settledWaitsAndRemovesMissing() async throws {
        let world = try await fixture()
        let publisher = world.store.statePublisher(state: world.state)
        // Store の行を変えずに state だけを古くしておき、流れが Store から読み直すことを見る
        var stale = world.task
        stale.title = "古い"
        await world.state.upsert(stale)
        var missing = world.task
        missing.number = 999
        await world.state.upsert(missing)
        world.store.changed(.task(world.task.number), .task(999))
        await publisher.settled()
        #expect(await world.state.task(number: world.task.number)?.title == "x")
        #expect(await world.state.task(number: 999) == nil)
    }
}
