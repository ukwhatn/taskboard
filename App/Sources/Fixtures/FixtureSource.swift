import Foundation
import TaskboardKit

/// バンドルの `Fixtures/<name>.json`（`StateSnapshot`）を供給元にする。
struct FixtureSource: SnapshotSource {
    let initial: StateSnapshot
    /// state に無い、画面確認用の中身（会話の発言・ファイルの札・作業ディレクトリの候補）
    var extras = FixtureExtras()

    static func named(_ name: String) throws -> FixtureSource {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.main.url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        let snapshot = try WireJSON.decoder().decode(StateSnapshot.self, from: data)
        let extras = try WireJSON.decoder().decode(FixtureExtras.self, from: data)
        return FixtureSource(initial: snapshot, extras: extras)
    }

    func snapshot() async throws -> StateSnapshot { initial }

    func events() -> AsyncThrowingStream<DaemonEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<DaemonEvent, any Error>.makeStream()
        #if DEBUG
        FixtureInjection.shared.add(continuation, machine: initial.machine.id)
        #endif
        return stream
    }
}

/// fixtures の JSON の、state に無い中身
struct FixtureExtras: Decodable, Sendable {
    /// 作業ディレクトリの候補（起動の欄）
    var workdirs: WorkingDirectories?
    /// チャットのファイルの札の中身。鍵は `ChatFileStore.fixture` の形、値は `{"text": …}`・`{"diff": unified diff}`・`{"image": base64}` のどれか
    var chatFiles: [String: ChatFileContent] = [:]
    /// host の会話の手元（会話の id → 発言・出来事・先に出した発言）。生成中・待機中・送れなかった発言を出す
    var conversations: [String: FixtureConversation] = [:]
    /// マシンの codex の値（`GET /v1/codex` の代わり）。モデルの一覧を Codex の欄に出す
    var codex: CodexMachineInfo?
    /// マシンの Claude Code のモデルの一覧（`GET /v1/claude` の代わり）。無ければ Kit の控えの一覧
    var claude: ClaudeMachineInfo?

    init() {}

    /// fixtures の会話の手元。発言を履歴の 1 ページとして重ね、出来事を当て、先に出した発言を足す
    func conversationTimeline(_ id: String) -> ConversationTimeline {
        var timeline = ConversationTimeline()
        guard let fixture = conversations[id] else { return timeline }
        timeline.mergeHistory(ConversationHistoryResponse(messages: fixture.messages, nextCursor: nil, agentSessionID: "fixture"), older: false)
        timeline.subscribed(epoch: "fixture")
        for (index, kind) in fixture.events.enumerated() {
            _ = timeline.apply(ConversationEvent(seq: index + 1, conversationID: id, at: Date(timeIntervalSince1970: 0), kind: kind))
        }
        for (index, outgoing) in fixture.outgoing.enumerated() {
            let clientID = "fixture-\(index)"
            timeline.addOutgoing(clientMessageID: clientID, text: outgoing.text, at: Date(timeIntervalSince1970: 0))
            if outgoing.failed == true { timeline.markFailed(clientID) }
            if outgoing.queued == true {
                timeline.markSent(clientID)
                _ = timeline.apply(
                    ConversationEvent(
                        seq: timeline.seq + 1, conversationID: id, at: Date(timeIntervalSince1970: 0), kind: .accepted(clientMessageID: clientID, state: "queued")))
            }
        }
        return timeline
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workdirs = try c.decodeIfPresent(WorkingDirectories.self, forKey: .workdirs)
        chatFiles = try (c.decodeIfPresent([String: FixtureChatFile].self, forKey: .chatFiles) ?? [:]).compactMapValues(\.content)
        conversations = try c.decodeIfPresent([String: FixtureConversation].self, forKey: .conversationChats) ?? [:]
        codex = try c.decodeIfPresent(CodexMachineInfo.self, forKey: .codex)
        claude = try c.decodeIfPresent(ClaudeMachineInfo.self, forKey: .claude)
    }

    private enum CodingKeys: String, CodingKey { case workdirs, chatFiles, conversationChats, codex, claude }
}

/// fixtures の JSON の `conversationChats` の 1 つ
struct FixtureConversation: Decodable, Sendable {
    struct Outgoing: Decodable, Sendable {
        var text: String
        var failed: Bool?
        /// 生成中に送って待ち行列に入った
        var queued: Bool?
    }

    var messages: [ChatMessage] = []
    /// 発言の後に当てる出来事（`ConversationEvent.Kind` の JSON）
    var events: [ConversationEvent.Kind] = []
    var outgoing: [Outgoing] = []
    /// `/` の候補、コネクタの一覧、差分の画面、Run の出力、巻き戻しの確認（dry run）、コンテキストの内訳の中身
    var commands: [ConversationCommand] = []
    /// `@` の候補に出す作業ディレクトリのパス（フォルダは末尾に `/`）。打った文字を含むものを出す
    var workFiles: [String] = []
    var mcpServers: [ConversationMcpServer]?
    var diff: ConversationDiffResponse?
    /// path → unified diff
    var fileDiffs: [String: String] = [:]
    var runs: [ConversationRun] = []
    var rewind: ConversationRewindResponse?
    var contextBreakdown: ConversationContextBreakdown?
    /// 読む画面（`/export`・`/tasks`・`/permissions`・`/hooks`・`/memory`・`/skills`・`/btw`）の中身。タスクの出力はタスクの id ごと
    var export: ConversationExport?
    var backgroundTasks: ConversationBackgroundTasks?
    var taskOutputs: [String: ConversationTaskOutput] = [:]
    var permissionRules: ConversationPermissionRules?
    var hooks: ConversationHooks?
    var memory: ConversationMemory?
    var skills: ConversationSkills?
    var sideAnswer: ConversationSideAnswer?
    var sandbox: ConversationSandbox?
    /// ［プラグイン］のシートの中身。入れられる plugin は全部を持ち、開いたときに絞る文字で絞る
    var plugins: ConversationPlugins?

    private enum CodingKeys: String, CodingKey {
        case messages, events, outgoing, commands, workFiles, mcpServers, diff, fileDiffs, runs, rewind, contextBreakdown
        case export, backgroundTasks, taskOutputs, permissionRules, hooks, memory, skills, sideAnswer, sandbox, plugins
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        events = try c.decodeIfPresent([ConversationEvent.Kind].self, forKey: .events) ?? []
        outgoing = try c.decodeIfPresent([Outgoing].self, forKey: .outgoing) ?? []
        commands = try c.decodeIfPresent([ConversationCommand].self, forKey: .commands) ?? []
        workFiles = try c.decodeIfPresent([String].self, forKey: .workFiles) ?? []
        mcpServers = try c.decodeIfPresent([ConversationMcpServer].self, forKey: .mcpServers)
        diff = try c.decodeIfPresent(ConversationDiffResponse.self, forKey: .diff)
        fileDiffs = try c.decodeIfPresent([String: String].self, forKey: .fileDiffs) ?? [:]
        runs = try c.decodeIfPresent([ConversationRun].self, forKey: .runs) ?? []
        rewind = try c.decodeIfPresent(ConversationRewindResponse.self, forKey: .rewind)
        contextBreakdown = try c.decodeIfPresent(ConversationContextBreakdown.self, forKey: .contextBreakdown)
        export = try c.decodeIfPresent(ConversationExport.self, forKey: .export)
        backgroundTasks = try c.decodeIfPresent(ConversationBackgroundTasks.self, forKey: .backgroundTasks)
        taskOutputs = try c.decodeIfPresent([String: ConversationTaskOutput].self, forKey: .taskOutputs) ?? [:]
        permissionRules = try c.decodeIfPresent(ConversationPermissionRules.self, forKey: .permissionRules)
        hooks = try c.decodeIfPresent(ConversationHooks.self, forKey: .hooks)
        memory = try c.decodeIfPresent(ConversationMemory.self, forKey: .memory)
        skills = try c.decodeIfPresent(ConversationSkills.self, forKey: .skills)
        sideAnswer = try c.decodeIfPresent(ConversationSideAnswer.self, forKey: .sideAnswer)
        sandbox = try c.decodeIfPresent(ConversationSandbox.self, forKey: .sandbox)
        plugins = try c.decodeIfPresent(ConversationPlugins.self, forKey: .plugins)
    }

    init(messages: [ChatMessage], events: [ConversationEvent.Kind] = [], outgoing: [Outgoing] = []) {
        self.messages = messages
        self.events = events
        self.outgoing = outgoing
    }
}

private struct FixtureChatFile: Decodable {
    var text: String?
    var diff: String?
    var image: String?

    var content: ChatFileContent? {
        if let text { return .text(text) }
        if let diff { return .diff(ChatDiffHunk.parse(unified: diff)) }
        return image.flatMap { Data(base64Encoded: $0) }.map(ChatFileContent.image)
    }
}

enum FixtureError: Error, LocalizedError {
    case notFound(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let name): "Fixtures/\(name).json が無い"  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
        }
    }
}

#if DEBUG
/// fixtures の供給元に、debug の口から知らせを流し込む（`POST /fixture/work`・`/fixture/flow`）。fixtures は書き込めないので、書き込んだ後に daemon が送る知らせの代わりにする。
/// 知らせはそのマシンの供給元にだけ届ける（`+` でつないだ fixtures で、別のマシンの状態に入らないように）
final class FixtureInjection: @unchecked Sendable {
    static let shared = FixtureInjection()
    private let lock = NSLock()
    private var continuations: [(machine: MachineID, continuation: AsyncThrowingStream<DaemonEvent, any Error>.Continuation)] = []

    func add(_ continuation: AsyncThrowingStream<DaemonEvent, any Error>.Continuation, machine: MachineID) {
        lock.withLock { continuations.append((machine, continuation)) }
    }

    func yield(_ event: DaemonEvent, to machine: MachineID) {
        for entry in lock.withLock({ continuations }) where entry.machine == machine { entry.continuation.yield(event) }
    }
}
#endif
