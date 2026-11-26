import ArgumentParser
import Foundation
import TaskboardDaemon
import TaskboardKit

/// Claude Code の hook から呼ばれる。stdin の JSON を daemon に渡す。
/// hook でターンを壊さないため、daemon が居なくても何も出さず exit 0。
struct Hook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: Copy.text("cli.hook.hook.configuration"),
        subcommands: [Session.self, Stop.self, Tool.self, Prompt.self, Statusline.self])

    /// host の会話（daemon が stream-json で動かす Claude Code）の中か。その会話の hook は daemon が stdio の hook_callback で受けるので、
    /// settings.json の hook は何もしない。Bash から起こした別の claude にも env は継がれ、その hook も止まる（どの会話かは env で区別しない）
    static func insideHostConversation(_ environment: [String: String]) -> Bool {
        environment["TASKBOARD_CONVERSATION_ID"].map { !$0.isEmpty } ?? false
    }

    /// hook の入力のうち使うもの。
    struct Payload: Decodable {
        var sessionID: String?
        var cwd: String?
        var hookEventName: String?
        var agentID: String?
        /// SessionStart の起点（startup / resume / clear / compact / fork）
        var source: String?
        /// 付いている会話の題（/rename か前の hook）
        var sessionTitle: String?
        var transcriptPath: String?
        /// Stop だけ：ターンの最後の応答の文
        var lastAssistantMessage: String?

        enum CodingKeys: String, CodingKey {
            case cwd, source
            case sessionID = "session_id"
            case hookEventName = "hook_event_name"
            case agentID = "agent_id"
            case sessionTitle = "session_title"
            case transcriptPath = "transcript_path"
            case lastAssistantMessage = "last_assistant_message"
        }

        static func read() -> Payload? {
            guard !Hook.insideHostConversation(ProcessInfo.processInfo.environment) else { return nil }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }
    }

    /// SessionStart: タスクに結び、結べたら taskboard の使い方の案内（additionalContext）と会話の題（sessionTitle）を返す。
    /// hook は起動・再開・/clear・圧縮のたびに呼ばれるので、圧縮で案内が消えない。題は startup / resume / fork のときだけ効く（docs）
    struct Session: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: Copy.text("cli.hook.hook.configuration.2"))
        @OptionGroup var common: CommonOptions

        func run() async throws {
            guard let payload = Payload.read(), let sessionID = payload.sessionID, payload.agentID == nil else { return }
            guard let client = Hook.client(common) else { return }
            guard let resolution = try? await client.linkSession(
                SessionLinkRequest(agent: "claude", agentSessionID: sessionID, cwd: payload.cwd ?? FileManager.default.currentDirectoryPath)),
                let task = resolution.task
            else { return }
            let output = Hook.sessionStartOutput(task: task, board: resolution.board, source: payload.source, currentTitle: payload.sessionTitle)
            print(output)
        }
    }

    /// SessionStart の出力（`hookSpecificOutput`）。題は、無いときと hook が付けた題が古いときだけ付ける（人が /rename で付けた題を上書きしない。`SessionGuidance.retitle`）
    static func sessionStartOutput(task: BoardTask, board: Board?, source: String?, currentTitle: String?) -> String {
        var specific: [String: Any] = [
            "hookEventName": "SessionStart",
            "additionalContext": SessionGuidance.text(task: task, board: board, machineName: Copy.text("agent.mcp.core.snapshot.2")),
        ]
        let titleApplies = ["startup", "resume", "fork", nil].contains(source)
        if titleApplies, let title = SessionGuidance.retitle(current: currentTitle, task: task) {
            specific["sessionTitle"] = title
        }
        return JSONPretty.render(["hookSpecificOutput": specific])
    }

    /// Stop: (1) 紐づくタスクの列を PR の状態へ進める（無ければ PR から起票）。(2) 待ちにした後のターンで作業したのに待ちのままの作業項目があれば、
    /// 見直しの依頼を stderr に載せて exit 2（`asyncRewake` でモデルが起きる。回答は次の Stop で待つ）。
    /// (3) そのタスクに人の回答・レビューが届くのを待ち、届いたら stderr に載せて exit 2。届けきれた分だけ ack する。
    /// 紐づくタスクが無い・daemon が居ない・何も届かないときは exit 0。
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: Copy.text("cli.hook.hook.configuration.3"))
        @OptionGroup var common: CommonOptions

        @Option(name: .long, help: "回答・レビューを待つ秒数（settings.json の timeout より短くする）")
        var wait: Int = FeedbackService.defaultWaitMs / 1000

        /// Claude Code の hook 出力は 10,000 文字で退避されプレビューに置き換わる。stderr もその上限に揃える
        static let stderrLimitChars = 10_000

        func run() async throws {
            guard let payload = Payload.read(), let sessionID = payload.sessionID, payload.agentID == nil else { return }
            guard let client = Hook.client(common) else { return }
            let turn = payload.transcriptPath.flatMap { TranscriptTurn.read(URL(fileURLWithPath: $0)) }
            if let response = try? await client.hookStop(
                HookStopRequest(
                    agent: "claude", agentSessionID: sessionID, cwd: payload.cwd ?? FileManager.default.currentDirectoryPath,
                    turnStartedAt: turn?.startedAt, turnUsedTools: turn?.usedTools, turnLastReply: payload.lastAssistantMessage, turnPresented: turn?.presented))
            {
                for message in response.messages { print(message) }
                fflush(stdout)
                if let reminder = response.reminder {
                    FileHandle.standardError.write(Data(reminder.utf8))
                    throw ExitCode(2)
                }
            }
            guard let waiting = Hook.client(common, requestTimeout: TimeInterval(wait) + 60),
                let claimed = try? await waiting.claimFeedback(FeedbackClaimRequest(agentSessionID: sessionID, timeoutMs: wait * 1000)),
                claimed.status == .feedback, let bundle = claimed.bundle, let claimID = claimed.claimID
            else { return }
            let (text, clipped) = FeedbackText.forHook(bundle, limitChars: Self.stderrLimitChars)
            FileHandle.standardError.write(Data(text.utf8))
            // 受領確定は「モデルへ届けきれた」ことの記録。切ったときは未受領のまま残し、feedback_list で回収させる
            if !clipped {
                try? await client.ackFeedback(FeedbackAckRequest(claimID: claimID))
            }
            throw ExitCode(2)
        }
    }

    /// PostToolUse: 届いている人の回答・レビューを待たずに取り、ツールの結果の隣に入れる（`additionalContext`）。
    /// command は印のファイル（`FeedbackMarkers`）があるときだけこれを呼ぶ（`HooksEdit.pendingCommand`）
    struct Tool: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: Copy.text("cli.hook.hook.configuration.4"))
        @OptionGroup var common: CommonOptions

        func run() async throws { await Hook.deliverPending(event: "PostToolUse", common: common) }
    }

    /// UserPromptSubmit: 結ばれたタスクの題が変わっていれば会話の題を付け直し（`sessionTitle`）、届いている人の回答・レビューを待たずに取って、
    /// 送ったメッセージと一緒に入れる。daemon は題が古いと Stop hook で印を置く
    struct Prompt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: Copy.text("cli.hook.hook.configuration.5"))
        @OptionGroup var common: CommonOptions

        func run() async throws {
            guard let payload = Payload.read(), let sessionID = payload.sessionID, payload.agentID == nil, let client = Hook.client(common, requestTimeout: 5)
            else { return }
            let title = (try? await client.hookPrompt(HookPromptRequest(agentSessionID: sessionID, sessionTitle: payload.sessionTitle)))?.sessionTitle
            let pending = await Hook.claimPending(sessionID: sessionID, client: client)
            guard let output = Hook.pendingOutput(event: "UserPromptSubmit", text: pending?.text, sessionTitle: title) else { return }
            print(output)
            fflush(stdout)
            await pending?.ack()
        }
    }

    /// 待たずに claim し、あれば `hookSpecificOutput.additionalContext` で出す。切ったときは ack せず、残りを Stop hook か `feedback_list` に任せる
    static func deliverPending(event: String, common: CommonOptions) async {
        guard let payload = Payload.read(), let sessionID = payload.sessionID, payload.agentID == nil, let client = Hook.client(common, requestTimeout: 5),
            let pending = await claimPending(sessionID: sessionID, client: client),
            let output = pendingOutput(event: event, text: pending.text, sessionTitle: nil)
        else { return }
        print(output)
        fflush(stdout)
        await pending.ack()
    }

    /// 待たない claim の結果。`ack` は出力を書いた後に呼ぶ
    struct PendingFeedback {
        var text: String
        var ack: () async -> Void
    }

    static func claimPending(sessionID: String, client: DaemonClient) async -> PendingFeedback? {
        guard let claimed = try? await client.claimFeedback(FeedbackClaimRequest(agentSessionID: sessionID, timeoutMs: 0)),
            claimed.status == .feedback, let bundle = claimed.bundle, let claimID = claimed.claimID
        else { return nil }
        let (text, clipped) = FeedbackText.forHook(bundle, limitChars: Stop.stderrLimitChars)
        return PendingFeedback(text: text) {
            if !clipped { try? await client.ackFeedback(FeedbackAckRequest(claimID: claimID)) }
        }
    }

    /// 出すものが無ければ nil
    static func pendingOutput(event: String, text: String?, sessionTitle: String?) -> String? {
        var specific: [String: Any] = ["hookEventName": event]
        if let text { specific["additionalContext"] = text }
        if let sessionTitle { specific["sessionTitle"] = sessionTitle }
        guard specific.count > 1 else { return nil }
        return JSONPretty.render(["hookSpecificOutput": specific])
    }

    /// statusline: 枠と context を daemon に渡す。statusline-command.sh が描画を待たないように裏で呼ぶ
    struct Statusline: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: Copy.text("cli.hook.hook.configuration.6"))
        @OptionGroup var common: CommonOptions

        func run() async throws {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let account = ProcessInfo.processInfo.environment[ClaudeAccount.environmentName].flatMap { $0.isEmpty ? nil : $0 }
            guard let report = ClaudeUsageReport.parse(statusline: data, account: account, now: Date()), let client = Hook.client(common, requestTimeout: 3) else { return }
            try? await client.reportClaudeUsage(report)
        }
    }

    static func client(_ common: CommonOptions, requestTimeout: TimeInterval = 20) -> DaemonClient? {
        let common = common.inheritingDaemon(from: ProcessInfo.processInfo.environment)
        guard let endpoint = try? Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout + 60
        return DaemonClient(endpoint: endpoint, session: URLSession(configuration: config))
    }
}
