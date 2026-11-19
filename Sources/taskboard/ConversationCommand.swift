import ArgumentParser
import Foundation
import Logging
import TaskboardDaemon
import TaskboardKit

/// `taskboard conversation`：daemon が agent host で動かす会話（stream-json）を CLI から扱う。E1 の確かめと、確かめた版の記録（`check`）に使う
struct ConversationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conversation",
        abstract: "host の会話（stream-json の Claude Code）を起こす・送る・見る・答える",
        subcommands: [
            List.self, Start.self, Send.self, Watch.self, Answer.self, Control.self, Commands.self, Fork.self, Rewind.self, Diff.self,
            Shell.self, RunCode.self, RunCancel.self, Prewarm.self, Stop.self, Close.self, Resume.self, Delete.self, Check.self, RebuildSearch.self,
        ])

    /// 今の Claude の会話 ID（巻き戻し・端末で開くの `expectedAgentSessionID`）
    static func agentSessionID(_ client: DaemonClient, _ id: String, expected: String?) async throws -> String {
        if let expected { return expected }
        return try await client.conversation(id).agentSessionID
    }

    static func client(_ common: CommonOptions) throws -> DaemonClient {
        DaemonClient(endpoint: try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL))
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話の一覧")
        @OptionGroup var common: CommonOptions

        func run() async throws {
            let conversations = try await ConversationCommand.client(common).conversations()
            if conversations.isEmpty { print("会話は無い") }
            for conversation in conversations { print(conversation.line(taskTitle: nil)) }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話を起こす（--resume で前の会話を戻す）")
        @OptionGroup var common: CommonOptions
        @Option(help: "engine（claude・codex。既定は claude）") var engine: String?
        @Option(help: "作業ディレクトリ（既定は今のディレクトリ）") var cwd: String?
        @Option(help: "結ぶタスクの番号") var task: Int?
        @Option(help: "モデル（Claude はマシンの一覧の名前（opus・sonnet・fable・haiku・版つきの名前）、codex は model/list の id）") var model: String?
        @Option(help: "effort") var effort: String?
        @Option(help: "権限のモード（\(ConversationInput.acceptedPermissionModes.joined(separator: "・"))。既定は \(ConversationInput.defaultPermissionMode)）")
        var permissionMode: String?
        @Option(help: "戻す会話 ID（Claude の会話 ID か codex の thread の ID）") var resume: String?
        @Option(help: "題") var title: String?
        @Option(help: "使わせない tool（カンマ区切りか、繰り返して渡す）") var disallowedTools: [String] = []
        @Option(help: "cwd の repo から worktree を切るブランチ") var worktreeBranch: String?
        @Option(help: "worktree の元にするブランチ") var worktreeBase: String?
        @Flag(help: "このシェルの host の会話を起こした側にする") var parentFromEnv = false
        @Flag(help: "ターンの終わりと問いを起こした側に知らせる（--parent-from-env と使う）") var notify = false
        @Argument(help: "最初に送る文") var prompt: [String] = []

        func validate() throws {
            if notify, !parentFromEnv { throw ValidationError("--notify は --parent-from-env と一緒に使う") }
            if worktreeBase != nil, worktreeBranch == nil { throw ValidationError("--worktree-base は --worktree-branch と一緒に使う") }
            if let engine, AgentKind(rawValue: engine) == nil { throw ValidationError("--engine は claude か codex") }
            if engine == AgentKind.codex.rawValue, !ConversationInput.disallowedToolsArguments(disallowedTools).isEmpty { throw ValidationError("--disallowed-tools は Claude の会話だけ") }
        }

        func run() async throws {
            let directory = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
            let text = prompt.joined(separator: " ")
            let disallowed = ConversationInput.disallowedToolsArguments(disallowedTools)
            let parent = try parentFromEnv ? Self.parent(environment: ProcessInfo.processInfo.environment) : nil
            let conversation = try await ConversationCommand.client(common).startConversation(
                ConversationStartRequest(
                    cwd: directory, taskNumber: task, model: model, effort: effort, permissionMode: permissionMode, prompt: text.isEmpty ? nil : text,
                    resumeAgentSessionID: resume, extraArgs: disallowed.isEmpty ? nil : disallowed,
                    worktree: worktreeBranch.map { LaunchRequest.WorktreeSpec(branch: $0, base: worktreeBase) }, parent: parent,
                    notifyParent: notify ? true : nil, title: title, engine: engine.flatMap(AgentKind.init(rawValue:))))
            print(conversation.line(taskTitle: nil))
        }

        static func parent(environment: [String: String]) throws -> ConversationParent {
            guard let parent = SessionEnvironment(environment: environment).parent else {
                // 委譲のスクリプトがこの文の頭で host の会話の外を見分ける
                throw ValidationError("--parent-from-env: このシェルは host の会話でない")
            }
            return parent
        }
    }

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "発言を送る（生成中なら次に回る）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "送る文") var text: [String]
        @Option(name: .customLong("image"), help: "添える画像のパス（複数可）") var images: [String] = []

        func run() async throws {
            let client = try ConversationCommand.client(common)
            var attachments: [String] = []
            for path in images {
                let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                attachments.append(try await client.uploadConversationAttachment(id, data: data).id)
            }
            let response = try await client.sendConversation(id, ConversationSendRequest(text: text.joined(separator: " "), attachments: attachments))
            print(response.outcome)
        }
    }

    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話の出来事を流して出す（Ctrl-C で終わる）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Option(help: "この番号より後から") var after: Int = 0
        @Flag(help: "ターンが 1 つ終わったら終わる") var untilTurn = false

        func run() async throws {
            var midLine = false
            for try await event in try ConversationCommand.client(common).conversationEvents(id, after: after) {
                let (text, inline) = ConversationCommand.render(event)
                if inline {
                    print(text, terminator: "")
                    fflush(stdout)
                    if !text.isEmpty { midLine = !text.hasSuffix("\n") }
                    continue
                }
                if text.isEmpty { continue }
                if midLine { print("") }
                midLine = false
                print(text)
                fflush(stdout)
                if untilTurn, case .turn = event.kind { return }
            }
        }
    }

    /// 出来事の 1 件を 1 行にする。差分は改行せずに続ける（`inline`）
    static func render(_ event: ConversationEvent) -> (String, inline: Bool) {
        switch event.kind {
        case .delta(_, _, let block, let text):
            return block == .text ? (text, true) : ("", true)
        case .blockStart, .blockStop, .unsupported:
            return ("", true)
        case .messages(let messages, _):
            let lines = messages.compactMap { message -> String? in
                switch message.kind {
                case .text:
                    guard message.role == .user else { return nil }
                    return message.isInjected ? "[差し込み] \(message.text.split(separator: "\n").first.map(String.init)?.prefix(200) ?? "")" : "[発言] \(message.text)"
                case .toolUse: return "[ツール] \(message.toolName ?? "?") \(message.text.prefix(200))"
                case .toolResult: return "[結果]\(message.isError ? "（失敗）" : "") \(message.text.split(separator: "\n").first.map(String.init)?.prefix(200) ?? "")"
                case .notice: return "[印] \(message.text)"
                }
            }
            return (lines.joined(separator: "\n"), false)
        case .conversation(let conversation):
            let lines = ["[状態 \(event.seq)] " + conversation.line(taskTitle: nil)] + conversation.requests.flatMap(\.lines)
            return (lines.joined(separator: "\n"), false)
        case .accepted(let id, let state):
            return ("[受付] \(id) \(state)", false)
        case .turn(let turn):
            var parts = ["[ターン] \(turn.isError ? "失敗" : "終わり")", turn.stopReason ?? ""]
            if let ms = turn.durationMs { parts.append("\(ms) ms") }
            if let ttft = turn.ttftMs { parts.append("最初の差分まで \(ttft) ms") }
            if let cost = turn.costUSD { parts.append(String(format: "$%.4f", cost)) }
            return (parts.filter { !$0.isEmpty }.joined(separator: "  "), false)
        case .gap:
            return ("[欠け] 控えから落ちた分がある", false)
        case .notice(let text):
            return ("[知らせ] \(text)", false)
        case .commands(let commands):
            return ("[コマンド] \(commands.count) 件", false)
        case .run(let run):
            let status = run.status == .running ? "" : "[Run \(run.id) \(run.status.rawValue)\(run.exitCode.map { " \($0)" } ?? "")]"
            return (run.chunk + status, run.status == .running)
        case .reset:
            return ("[巻き戻し] 履歴を取り直す", false)
        }
    }

    struct Answer: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "問いに答える。質問は --select、権限と計画は --allow か --deny（権限の許可には --suggestion で［常に許可］の候補も）、MCP の server の問いは --action（form を受けるときは --content も）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "問いの id（watch の [問い …]）") var requestID: String
        @Option(help: "選ぶ選択肢。質問 id=選択肢 の形で質問ごとに（1 問なら選択肢だけでよい）") var select: [String] = []
        @Option(help: "補足の文") var free: String?
        @Flag(help: "許す") var allow = false
        @Flag(help: "断る") var deny = false
        @Option(help: "断る理由") var message: String?
        @Option(help: "権限の確認で、許可に添える［常に許可］の候補の id（watch の「今後は聞かない候補 <id>」）") var suggestion: String?
        @Option(help: "MCP の server の問い：accept・decline・cancel") var action: String?
        @Option(help: "MCP の server の問い（form）の入力の JSON（欄の名前 → 文字・数・真偽）") var content: String?

        func run() async throws {
            let client = try ConversationCommand.client(common)
            if let action {
                guard let given = ElicitationAction(rawValue: action) else { throw ValidationError("--action は " + ElicitationAction.allCases.map(\.rawValue).joined(separator: "・") + " のどれか") }
                let values = try content.map { text in
                    guard let values = try? WireJSON.decoder().decode([String: ElicitationValue].self, from: Data(text.utf8)) else {
                        throw ValidationError("--content は欄の名前 → 文字・数・真偽の JSON の object")
                    }
                    return values
                }
                try await client.answerConversation(id, ConversationAnswerRequest(requestID: requestID, action: given, content: values))
                print("答えた")
                return
            }
            if allow || deny {
                if suggestion != nil, !allow { throw ValidationError("--suggestion は --allow と一緒に渡す") }
                try await client.answerConversation(id, ConversationAnswerRequest(requestID: requestID, allow: allow, message: message, suggestionID: suggestion))
                print("答えた")
                return
            }
            let conversation = try await client.conversation(id)
            guard let request = (conversation.pending + [conversation.deferred].compactMap { $0 }).first(where: { $0.id == requestID }),
                let questions = request.waiting.questions
            else { throw ValidationError("問い \(requestID) は答えを待っていない") }
            var chosen: [String: [String]] = [:]
            for entry in select {
                if let equals = entry.firstIndex(of: "="), questions.contains(where: { $0.id == String(entry[..<equals]) }) {
                    chosen[String(entry[..<equals]), default: []].append(String(entry[entry.index(after: equals)...]))
                } else if let only = questions.first, questions.count == 1 {
                    chosen[only.id, default: []].append(entry)
                } else {
                    throw ValidationError("質問が \(questions.count) 問ある。--select 質問id=選択肢 で指す")
                }
            }
            let answers = questions.map { AskAnswer(questionID: $0.id, selected: chosen[$0.id] ?? [], freeText: free) }
            try await client.answerConversation(id, ConversationAnswerRequest(requestID: requestID, answers: answers))
            print("答えた")
        }
    }

    struct Control: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "制御要求を送る",
            discussion:
                "kind: interrupt・set_model <model>・set_effort <effort>・set_permission_mode <mode>・mcp_status・mcp_reconnect <server>・mcp_toggle <server> on|off・mcp_authenticate <server>・mcp_oauth_callback <server>（認証の後に開いたページのアドレスを標準入力から読む）・mcp_clear_auth <server>・context_usage・usage・rename <題>・defer on|off|auto・export_conversation・list_background_tasks・task_output <id>・stop_task <id>・permission_rules・hooks・memory・skills・side_question <質問>・add_directory <パス>・set_cwd <パス>・login・login_code（ログインのページに出たコードを標準入力から読む）・elicitation_url <問いの id>（MCP の問いの開く先の全文）・compact（codex の会話を圧縮する）・new_thread（codex の会話で新しい thread を始める）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "kind") var kind: String
        @Argument(help: "値") var value: [String] = []

        func run() async throws {
            let name = kind == "defer" ? ConversationControlRequest.Kind.deferQuestions.rawValue : kind
            guard let parsed = ConversationControlRequest.Kind(rawValue: name) else { throw ValidationError("kind が違う: \(kind)") }
            var request = ConversationControlRequest(kind: parsed)
            if parsed == .mcpToggle {
                guard value.count == 2, let enabled = ["on": true, "off": false][value[1]] else { throw ValidationError("mcp_toggle <server> on|off") }
                request.value = value[0]
                request.enabled = enabled
            } else if parsed == .mcpOAuthCallback {
                // アドレスは認証のコードを含むので、引数で受けない
                guard value.count == 1 else { throw ValidationError("mcp_oauth_callback <server>（アドレスは標準入力から）") }
                guard let url = readLine(), !url.isEmpty else { throw ValidationError("認証の後に開いたページのアドレスを標準入力に渡す") }
                request.value = value[0]
                request.callbackURL = url
            } else if parsed == .loginCode {
                // コードはログインに使うので、引数で受けない
                guard value.isEmpty else { throw ValidationError("login_code（コードは標準入力から）") }
                guard let code = readLine(), !code.isEmpty else { throw ValidationError("ログインのページに出たコードを標準入力に渡す") }
                request.code = code
            } else {
                let joined = value.joined(separator: " ")
                request.value = joined.isEmpty ? nil : joined
            }
            let response = try await ConversationCommand.client(common).controlConversation(id, request)
            print(response.payloadJSON ?? "送った")
        }
    }

    struct Commands: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話の / で使えるコマンド（起こしたプロセスから受けた一覧。無ければ .claude の skill と command）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String

        func run() async throws {
            let response = try await ConversationCommand.client(common).conversationCommands(id)
            print("出所: \(response.source.rawValue)  \(response.commands.count) 件")
            for command in response.commands {
                var line = "/\(command.name)"
                if let hint = command.argumentHint, !hint.isEmpty { line += " \(hint)" }
                if let aliases = command.aliases, !aliases.isEmpty { line += "（" + aliases.map { "/\($0)" }.joined(separator: " ") + "）" }
                if command.builtin == true { line += "  [組み込み]" }
                if !command.description.isEmpty { line += "  \(command.description)" }
                print(line)
            }
        }
    }

    struct Fork: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話を発言の所で分けて、新しい会話を起こす（--message を省くと末尾から）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Option(help: "この発言までを写す（transcript の行の uuid）") var message: String?
        @Option(help: "新しい会話に最初に送る文") var prompt: String?

        func run() async throws {
            let fork = try await ConversationCommand.client(common).forkConversation(id, ConversationForkRequest(messageID: message, prompt: prompt))
            print(fork.line(taskTitle: nil))
        }
    }

    struct Rewind: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "会話を人の発言の前まで戻す（--files でファイルも。--dry-run で変わるファイルだけ見る。--undo で直前の巻き戻しを元に戻す。--redo で元に戻した巻き戻しをやり直す）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "この発言の前まで戻す（transcript の行の uuid）。--undo・--redo では要らない") var message: String?
        @Flag(help: "ファイルも戻す") var files = false
        @Flag(help: "戻さずに、戻せるかと変わるファイルだけ見る") var dryRun = false
        @Flag(help: "直前の巻き戻しを元に戻す（会話だけ。ファイルは戻らない）") var undo = false
        @Flag(help: "元に戻した巻き戻しをやり直す（会話だけ。元に戻した後に送るとやり直せない）") var redo = false
        @Option(help: "今の Claude の会話 ID（省くと daemon から引く）") var expect: String?

        func run() async throws {
            let client = try ConversationCommand.client(common)
            let session = try await ConversationCommand.agentSessionID(client, id, expected: expect)
            if undo {
                print(try await client.undoRewindConversation(id, ConversationSessionGuard(expectedAgentSessionID: session)).line(taskTitle: nil))
                return
            }
            if redo {
                print(try await client.redoRewindConversation(id, ConversationSessionGuard(expectedAgentSessionID: session)).line(taskTitle: nil))
                return
            }
            guard let message else { throw ValidationError("戻す発言の uuid を渡す（--undo・--redo のときだけ省ける）") }
            let response = try await client.rewindConversation(
                id, ConversationRewindRequest(messageID: message, expectedAgentSessionID: session, files: files, dryRun: dryRun))
            if let canRewind = response.canRewind { print("ファイルを戻せる: \(canRewind ? "はい" : "いいえ")" + (response.error.map { "（\($0)）" } ?? "")) }
            if let changed = response.filesChanged {
                print("変わるファイル \(changed.count) 件  +\(response.insertions ?? 0) -\(response.deletions ?? 0)")
                for path in changed { print("  \(path)") }
            }
            if let skipped = response.skippedLinks, skipped > 0 { print("戻せなかったリンク \(skipped) 件") }
            if let draft = response.draft { print("戻した発言: \(draft)") }
            if let conversation = response.conversation { print(conversation.line(taskTitle: nil)) }
        }
    }

    struct RunCode: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run", abstract: "コードを会話のシェルで動かし（変数と作業フォルダは次の run に残る）、終わるまで出力を出す（Ctrl-C では止まらない。止めるのは run-cancel）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "動かすコード（- で標準入力から）") var code: String
        @Option(help: "言語（bash・sh・shell・console・zsh・fish）") var language: String = "bash"
        @Option(help: "コードブロックのある発言") var message: String?
        @Flag(help: "起こしたら Run の id だけ出して終わる") var detach = false

        func run() async throws {
            let client = try ConversationCommand.client(common)
            let source = code == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : code
            var run = try await client.startConversationRun(id, ConversationRunRequest(code: source, language: language, messageID: message))
            if detach { return print(run.id) }
            while run.status == .running {
                try await Task.sleep(for: .milliseconds(200))
                run = try await client.conversationRun(id, run: run.id)
            }
            print(run.output, terminator: run.output.isEmpty || run.output.hasSuffix("\n") ? "" : "\n")
            if run.truncated { print("（1MB で切った）") }
            print("[Run \(run.id) \(run.status.rawValue)\(run.exitCode.map { " \($0)" } ?? "")]")
            if run.status != .succeeded { throw ExitCode(1) }
        }
    }

    struct RunCancel: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run-cancel", abstract: "動いている Run を止める（Ctrl-C を送り、止まらなければシェルを閉じる）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Argument(help: "Run の id") var run: String

        func run() async throws {
            try await ConversationCommand.client(common).cancelConversationRun(id, run: run)
            print("止めた")
        }
    }

    struct Prewarm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "この条件の会話のプロセスを先に起こしておく（同じ条件の start が引き取る。120 秒で捨てる）")
        @OptionGroup var common: CommonOptions
        @Option(help: "作業ディレクトリ（既定は今のディレクトリ）") var cwd: String?
        @Option(help: "モデル") var model: String?
        @Option(help: "effort") var effort: String?
        @Option(help: "権限のモード") var permissionMode: String?

        func run() async throws {
            let directory = URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
            try await ConversationCommand.client(common).prewarmConversation(
                ConversationPrewarmRequest(cwd: directory, model: model, effort: effort, permissionMode: permissionMode))
            print("受け付けた（会話の枠に空きが無ければ起こさない）")
        }
    }

    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話の作業フォルダの git の差分（--file で 1 ファイルの diff）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Option(help: "diff を出すファイル（git の根からの相対）") var file: String?
        @Option(help: "比べる相手（all・unstaged・staged・branch）") var scope: ConversationDiffScope = .all

        func run() async throws {
            let client = try ConversationCommand.client(common)
            if let file {
                let response = try await client.conversationFileDiff(id, path: file, scope: scope)
                print(response.diff, terminator: response.diff.hasSuffix("\n") ? "" : "\n")
                if response.truncated { print("（1MB で切った）") }
                return
            }
            let response = try await client.conversationDiff(id, scope: scope)
            let summary = response.summary
            guard summary.isRepo else { return print("git の外") }
            if scope == .branch, response.base == nil { return print("比べるブランチが無い") }
            print("\(summary.branch ?? "（ブランチなし）")  \(summary.files) ファイル  +\(summary.insertions) -\(summary.deletions)")
            for file in response.files {
                let counts = file.insertions.map { "+\($0) -\(file.deletions ?? 0)" } ?? "バイナリ"
                print("\(file.change.rawValue)  \(file.oldPath.map { "\($0) → " } ?? "")\(file.path)  \(counts)")
            }
        }
    }

    struct Shell: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話の作業フォルダのシェルの pane を開く（生きていれば前と同じ pane）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String

        func run() async throws {
            print(try await ConversationCommand.client(common).conversationShell(id).pane.rawValue)
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "会話を止める（積んだ発言は走らせない）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String

        func run() async throws {
            try await ConversationCommand.client(common).stopConversation(id)
            print("止めた")
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "会話を終了する（動いていれば止め、一覧から外す。記録は残り、resume で再開できる。空いている委譲先の会話は止める）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String
        @Flag(help: "作業の途中でも確かめずに終了する（端末から読めないときは要る）") var yes = false

        func run() async throws {
            let client = try ConversationCommand.client(common)
            let conversation = try await client.conversation(id)
            if !yes, conversation.interruptedByStop {
                print(conversation.line(taskTitle: nil))
                print("作業の途中で止まる")
                guard isatty(STDIN_FILENO) != 0 else { throw ValidationError("端末から読めないので、終了するなら --yes を付ける") }
                print("終了する？ [y/N] ", terminator: "")
                guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
                    print("終了しなかった")
                    return
                }
            }
            try await client.closeConversation(id)
            print("終了した")
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "止まっている会話の記録を消す（動いていれば断る。タスクとの結びと transcript は残る）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var ids: [String]

        func run() async throws {
            let client = try ConversationCommand.client(common)
            for id in ids {
                try await client.deleteConversation(id)
                print("消した: \(id)")
            }
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "止まった会話を --resume で起こし直す")
        @OptionGroup var common: CommonOptions
        @Argument(help: "会話の id") var id: String

        func run() async throws {
            print(try await ConversationCommand.client(common).resumeConversation(id).line(taskTitle: nil))
        }
    }

    struct RebuildSearch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rebuild-search", abstract: "会話の検索の索引を捨てて、daemon に裏で初めから作り直させる（会話の記録は消さない）")
        @OptionGroup var common: CommonOptions

        func run() async throws {
            try await ConversationCommand.client(common).rebuildConversationSearch()
            print("作り直しを受け付けた。読み終えるまで、検索に出ない会話がある")
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Claude Code か codex を短い会話で通し、通った版を host の会話に使う版として記録する（daemon と host は要らない）")
        @OptionGroup var common: CommonOptions
        @Option(help: "確かめる CLI（claude・codex）") var engine: AgentKind = .claude
        @Option(help: "確かめる実行ファイル（既定は ~/.local/bin/claude・~/.local/bin/codex の先）") var executable: String?
        @Option(help: "モデル（既定は claude が haiku、codex は codex の既定）") var model: String?
        @Flag(help: "通っても記録しない") var noRecord = false

        func run() async throws {
            let path = try EngineCheck.resolveExecutable(executable, engine: engine)
            print("確かめる: \(path)")
            let progress: @Sendable (EngineCheck.Step) -> Void = { step in
                print("[\(step.passed ? "通った" : "通らない")] \(step.name)" + (step.detail.isEmpty ? "" : "  \(step.detail)"))
            }
            let report =
                switch engine {
                case .claude: try await ClaudeCheck.run(executable: path, model: model ?? "haiku", progress: progress)
                case .codex: try await CodexCheck.run(executable: path, model: model, progress: progress)
                }
            guard report.passed else {
                print("通らなかったので記録しない（\(engine.label) \(report.version)）")
                throw ExitCode(1)
            }
            if noRecord {
                print("通った（\(engine.label) \(report.version)）。--no-record なので記録しない")
                return
            }
            let paths = try Paths(directory: common.supportDirectoryURL)
            try EngineCheck.record(report, supportDirectory: paths.directory)
            print("記録した: \(engine.label) \(report.version)" + (report.capabilities.isEmpty ? "" : "  capabilities \(report.capabilities.joined(separator: ","))"))
        }
    }
}

extension AgentKind: ExpressibleByArgument {}
extension ConversationDiffScope: ExpressibleByArgument {}
