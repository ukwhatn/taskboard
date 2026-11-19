import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("タスクの題が変わったら会話の題を付け直す（UserPromptSubmit で返す）")
struct SessionRetitleTests {
    private let machine = MachineID(rawValue: "m-retitle")

    private struct World {
        let hooks: HookService
        let store: Store
        let state: DaemonState
        let markers: FeedbackMarkers
        let directory: URL
        let task: BoardTask

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func world() async throws -> World {
        let store = try Store(inMemory: machine)
        let state = DaemonState(machine: MachineInfo(id: machine, name: "t", daemonVersion: "t"))
        let board = try store.createBoard(name: "default", columns: nil)
        let created = try store.createTask(TaskCreateRequest(boardID: board.id, columnID: "working", title: "タスクタイトルからつけて"))
        let linked = try store.linkSession(task: created.number, agent: "claude", sessionID: "sess-1", cwd: "/repo", label: "")
        let task = try store.updateTask(number: linked.number, TaskUpdateRequest(title: "attr-meta の公開APIを作る"))
        await state.upsert(task)
        let directory = FileManager.default.temporaryDirectory.appending(path: "taskboard-retitle-\(UUID().uuidString)", directoryHint: .isDirectory)
        let markers = FeedbackMarkers(directory: directory)
        let feedback = FeedbackService(store: store, state: state, markers: markers)
        let github = GitHubSync(store: store, state: state, cli: GitHubCLI(environment: ["PATH": "/usr/bin:/bin"], executable: URL(fileURLWithPath: "/usr/bin/false")))
        return World(
            hooks: HookService(store: store, state: state, github: github, feedback: feedback), store: store, state: state, markers: markers,
            directory: directory, task: task)
    }

    @Test("会話の題が hook の付けた古い題なら新しい題を返し、印を消す")
    func staleTitle() async throws {
        let world = try await world()
        defer { world.cleanUp() }
        world.markers.mark(sessions: ["sess-1"])
        let response = try await world.hooks.prompt(HookPromptRequest(agentSessionID: "sess-1", sessionTitle: "#\(world.task.number) タスクタイトルからつけて"))
        #expect(response.sessionTitle == "#\(world.task.number) attr-meta の公開APIを作る")
        #expect(!world.markers.isMarked("sess-1"), "残すと PostToolUse の hook がツールのたびに起きる")
    }

    @Test("題が合っているか、人が付けた題なら題を返さない。結ばれていない会話には題を返さない")
    func currentOrHumanTitle() async throws {
        let world = try await world()
        defer { world.cleanUp() }
        for title in ["#\(world.task.number) attr-meta の公開APIを作る", "作者検索の調査"] {
            #expect(try await world.hooks.prompt(HookPromptRequest(agentSessionID: "sess-1", sessionTitle: title)).sessionTitle == nil, "\(title)")
        }
        #expect(try await world.hooks.prompt(HookPromptRequest(agentSessionID: "sess-9", sessionTitle: nil)).sessionTitle == nil)
    }

    @Test("未受領の回答があるときは UserPromptSubmit で印を消さない（続く claim が取る）")
    func keepsMarkerForFeedback() async throws {
        let world = try await world()
        defer { world.cleanUp() }
        let published = try world.store.publish(
            task: world.task.number,
            DocPublishRequest(
                name: "q.md", format: .markdown, content: "?",
                questions: [AskQuestion(id: "q1", question: "どっち", options: [AskOption(label: "A"), AskOption(label: "B")])]))
        _ = try world.store.answerAsk(id: try #require(published.askID), answers: [AskAnswer(questionID: "q1", selected: ["A"])])
        world.markers.mark(sessions: ["sess-1"])
        _ = try await world.hooks.prompt(HookPromptRequest(agentSessionID: "sess-1", sessionTitle: "#\(world.task.number) 古い題"))
        #expect(world.markers.isMarked("sess-1"))
    }
}
