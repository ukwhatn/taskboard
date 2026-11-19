import Foundation
import Testing

@testable import TaskboardKit

@Suite("engine ごとに使える会話の操作")
struct ConversationCapabilitiesTests {
    @Test("読む画面とその場の操作は Claude と codex で使える。codex に脇の質問・作業フォルダの追加・ログインのコードを貼り返すことは無い。知らない engine では使えない")
    func readouts() {
        let both: [ConversationControlRequest.Kind] = [
            .exportConversation, .listBackgroundTasks, .taskOutput, .stopTask, .permissionRules, .hooks, .memory, .skills, .setCwd, .login,
        ]
        let claudeOnly: [ConversationControlRequest.Kind] = [.sideQuestion, .addDirectory, .loginCode]
        for kind in both + claudeOnly {
            #expect(Conversation.Engine.claude.supports(kind), "\(kind)")
            #expect(Conversation.Engine.codex.supports(kind) == both.contains(kind), "\(kind)")
            #expect(!Conversation.Engine.unknown.supports(kind), "\(kind)")
        }
    }

    @Test("圧縮の制御は codex だけ（Claude は CLI の /compact を文で送る）")
    func compact() {
        #expect(Conversation.Engine.codex.supports(ConversationControlRequest.Kind.compact))
        #expect(!Conversation.Engine.claude.supports(ConversationControlRequest.Kind.compact))
        #expect(!Conversation.Engine.unknown.supports(ConversationControlRequest.Kind.compact))
        #expect(ConversationControlRequest.Kind(rawValue: "compact") == .compact)
    }

    @Test("新しい thread の制御は codex だけ（Claude は CLI の /clear を文で送る）")
    func newThread() {
        #expect(Conversation.Engine.codex.supports(ConversationControlRequest.Kind.newThread))
        #expect(!Conversation.Engine.claude.supports(ConversationControlRequest.Kind.newThread))
        #expect(!Conversation.Engine.unknown.supports(ConversationControlRequest.Kind.newThread))
        #expect(ConversationControlRequest.Kind(rawValue: "new_thread") == .newThread)
        #expect(Conversation.Engine.codex.supports(action: .new) && !Conversation.Engine.claude.supports(action: .new))
    }

    @Test("コネクタの欄（一覧・切り替え・再接続・認証・解除）は Claude と codex で使え、codex の /mcp も欄を開く")
    func connectors() {
        let kinds: [ConversationControlRequest.Kind] = [.mcpStatus, .mcpToggle, .mcpReconnect, .mcpAuthenticate, .mcpOAuthCallback, .mcpClearAuth]
        for engine in [Conversation.Engine.claude, .codex] {
            for kind in kinds { #expect(engine.supports(kind), "\(engine) \(kind)") }
            #expect(engine.supports(field: .mcp))
        }
        #expect(!Conversation.Engine.unknown.supports(field: .mcp))
        #expect(Conversation.Engine.codex.slashAction(.control(.mcp)) == .control(.mcp))
    }

    @Test("/ の候補は、engine が使えない taskboard の操作を出さない。CLI のコマンドはそのまま")
    func slashByEngine() {
        let commands = [ConversationCommand(name: "export", description: "Export", builtin: true), ConversationCommand(name: "pr-comments", description: "PR comments")]
        let claude = ConversationSlashItem.matching("", commands: commands, engine: .claude, limit: 100).map(\.name)
        let codex = ConversationSlashItem.matching("", commands: commands, engine: .codex, limit: 100).map(\.name)
        // codex の /login はページで打ち込むコードをアプリの画面に出す
        for name in ["export", "tasks", "permissions", "hooks", "memory", "skills", "cd", "login"] {
            #expect(claude.contains(name) && codex.contains(name), "\(name)")
        }
        for name in ["btw", "add-dir"] {
            #expect(claude.contains(name), "\(name)")
            #expect(!codex.contains(name), "\(name)")
        }
        #expect(codex.contains("pr-comments") && codex.contains("review") && codex.contains("fork") && !codex.contains("rewind"))
        #expect(ConversationSlashItem.matching("", commands: commands, engine: .unknown, limit: 100).map(\.name) == ["pr-comments"])
    }

    @Test("送る文が文の頭から taskboard の操作なら、操作と引数を返す。名前の途中まで・別の名前・文の途中の / は拾わない")
    func intercepted() {
        func claude(_ text: String) -> (ConversationSlashItem.Action, String)? {
            ConversationSlashItem.intercepted(text, engine: .claude).map { ($0.action, $0.argument) }
        }
        #expect(claude("/btw  今どこまで？ \n")! == (.taskboard(.btw), "今どこまで？"))
        #expect(claude("  /cd ~/dev/app")! == (.taskboard(.cd), "~/dev/app"))
        #expect(claude("/add-dir /w/sub")! == (.taskboard(.addDir), "/w/sub"))
        #expect(claude("/export")! == (.taskboard(.export), ""))
        #expect(claude("/exports") == nil)
        #expect(claude("/review") == nil)
        #expect(claude("この差分を /btw") == nil)
        #expect(ConversationTaskboardAction.btw.takesArgument && ConversationTaskboardAction.cd.takesArgument && !ConversationTaskboardAction.export.takesArgument)
    }

    @Test("Claude Code は欄の名前（/model・/mcp）を CLI に送る。Codex は CLI に送らず、開けない欄は開かずに「会話では使えない」と案内し、無い操作は送る文のまま")
    func interceptedByEngine() {
        func codex(_ text: String, unavailable: Set<ConversationControlField> = []) -> ConversationSlashItem.Action? {
            ConversationSlashItem.intercepted(text, engine: .codex, unavailableFields: unavailable)?.action
        }
        #expect(ConversationSlashItem.intercepted("/model", engine: .claude) == nil)
        #expect(ConversationSlashItem.intercepted("/mcp", engine: .claude) == nil)
        #expect(codex("/model") == .control(.model))
        #expect(codex("/model", unavailable: [.model, .effort]) == nil)
        #expect(ConversationSlashItem.unsupported("/model", engine: .codex, commands: [], unavailableFields: [.model, .effort])?.name == "model")
        #expect(ConversationSlashItem.unsupported("/model", engine: .codex, commands: []) == nil)
        #expect(codex("/mcp") == .control(.mcp))
        #expect(codex("/rewind") == nil)
        #expect(codex("/export") == .taskboard(.export))
        #expect(codex("/btw 今どこ") == nil)
        #expect(codex("/login") == .taskboard(.login))
        #expect(codex("/fork") == .taskboard(.fork))
        #expect(codex("/review") == .taskboard(.review))
        #expect(ConversationSlashItem.intercepted("/review 認証の所だけ", engine: .codex)?.argument == "認証の所だけ")
        #expect(ConversationSlashItem.intercepted("/fork", engine: .unknown) == nil)
    }

    @Test("後で送るのは Claude だけ（codex は生成中の発言をもともとターンの後に回す）")
    func sendLater() {
        #expect(Conversation.Engine.claude.supports(ConversationOperation.sendLater))
        #expect(!Conversation.Engine.codex.supports(ConversationOperation.sendLater))
        #expect(!Conversation.Engine.unknown.supports(ConversationOperation.sendLater))
    }
}
