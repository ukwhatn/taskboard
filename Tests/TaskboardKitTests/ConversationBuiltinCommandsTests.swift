import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話で動かない組み込みのコマンドの振り分け")
struct ConversationBuiltinCommandsTests {
    private func opened(_ text: String, _ engine: Conversation.Engine, commands: [ConversationCommand] = []) -> ConversationSlashItem.Action? {
        ConversationSlashItem.intercepted(text, engine: engine, commands: commands)?.action
    }

    private func unsupported(_ text: String, _ engine: Conversation.Engine, commands: [ConversationCommand] = []) -> ConversationUnsupportedCommand? {
        ConversationSlashItem.unsupported(text, engine: engine, commands: commands)
    }

    @Test("Claude: 代わりがあるものは taskboard の操作を開き、ほかは会話では使えないと案内する。送らない")
    func claude() {
        #expect(opened("/bashes", .claude) == .taskboard(.tasks))
        #expect(opened("/allowed-tools", .claude) == .taskboard(.permissions))
        #expect(unsupported("/bashes", .claude) == nil)

        #expect(opened("/logout", .claude) == nil)
        #expect(unsupported("/logout", .claude) == ConversationUnsupportedCommand(name: "logout"))
        #expect(unsupported("/ultraplan", .claude)?.name == "ultraplan")

        #expect(opened("/theme", .claude) == nil)
        #expect(unsupported("/theme", .claude) == ConversationUnsupportedCommand(name: "theme"))
        #expect(unsupported("/help", .claude)?.name == "help")
    }

    @Test("Claude: alias は同じ操作を開く（/checkpoint・/undo は巻き戻し、/branch・/subtask はフォーク）")
    func claudeAliases() {
        for name in ["checkpoint", "undo"] { #expect(opened("/\(name)", .claude) == .taskboard(.rewind), "\(name)") }
        for name in ["branch", "subtask"] { #expect(opened("/\(name)", .claude) == .taskboard(.fork), "\(name)") }
    }

    @Test("codex: /approvals・/memories・/ps・/review は操作を開き、/init・/ide・/pwd などは会話では使えないと案内する")
    func codex() {
        #expect(opened("/approvals", .codex) == .taskboard(.permissions))
        #expect(opened("/memories", .codex) == .taskboard(.memory))
        #expect(opened("/ps", .codex) == .taskboard(.tasks))
        #expect(opened("/review", .codex) == .taskboard(.review) && unsupported("/review", .codex) == nil)
        for name in ["init", "plan", "worktree", "logout", "ide", "keymap", "pwd", "theme", "resume"] {
            #expect(unsupported("/\(name)", .codex) == ConversationUnsupportedCommand(name: name), "\(name)")
            #expect(opened("/\(name)", .codex) == nil, "\(name)")
        }
    }

    @Test("/plugin は両 engine で［プラグイン］を開く。Claude は /plugins・/marketplace、codex は /plugins も同じ。送らない")
    func plugins() {
        for engine in [Conversation.Engine.claude, .codex] {
            #expect(opened("/plugin", engine) == .taskboard(.plugin), "\(engine)")
            #expect(opened("/plugins", engine) == .taskboard(.plugin), "\(engine)")
            #expect(unsupported("/plugins", engine) == nil, "\(engine)")
        }
        #expect(opened("/marketplace", .claude) == .taskboard(.plugin))
        #expect(unsupported("/marketplace", .claude) == nil)
        #expect(opened("/marketplace", .codex) == nil, "codex の表に /marketplace は無い")
    }

    @Test("codex の /compact は圧縮の操作。Claude の /compact は CLI に送り、/ の候補にも CLI のコマンドのまま残る")
    func compact() {
        #expect(opened("/compact", .codex) == .taskboard(.compact))
        #expect(unsupported("/compact", .codex) == nil)

        let commands = [ConversationCommand(name: "compact", description: "Compact", builtin: true)]
        #expect(opened("/compact", .claude, commands: commands) == nil)
        #expect(unsupported("/compact", .claude, commands: commands) == nil)
        let claude = ConversationSlashItem.matching("comp", commands: commands, engine: .claude)
        #expect(claude.map(\.action) == [.send("compact")])
        let codex = ConversationSlashItem.matching("comp", commands: [], engine: .codex)
        #expect(codex.map(\.action) == [.taskboard(.compact)])
    }

    @Test("codex の /rename は名前を引数に取る taskboard の操作。Claude の /rename は CLI に送る")
    func rename() {
        let codex = ConversationSlashItem.intercepted("/rename  新しい 名前 ", engine: .codex)
        #expect(codex?.action == .taskboard(.rename) && codex?.argument == "新しい 名前")
        #expect(ConversationSlashItem.intercepted("/rename", engine: .codex)?.argument == "")
        #expect(unsupported("/rename x", .codex) == nil)

        let commands = [ConversationCommand(name: "rename", description: "Rename", builtin: true)]
        #expect(opened("/rename x", .claude, commands: commands) == nil)
        #expect(ConversationSlashItem.matching("ren", commands: commands, engine: .claude).map(\.action) == [.send("rename")])
    }

    @Test("/exit と /quit は両 engine で会話の終了。Claude の CLI の一覧に exit（別名 quit）があっても送らない。/stop は振らない")
    func exit() {
        let commands = [ConversationCommand(name: "exit", description: "Exit", builtin: true, aliases: ["quit"])]
        for engine in [Conversation.Engine.claude, .codex] {
            for text in ["/exit", "/quit", "  /exit  "] {
                #expect(opened(text, engine, commands: commands) == .taskboard(.exit), "\(engine) \(text)")
                #expect(unsupported(text, engine, commands: commands) == nil, "\(engine) \(text)")
            }
            #expect(opened("/stop", engine, commands: commands) == nil, "\(engine)")
        }
        #expect(ConversationSlashItem.matching("exi", commands: commands, engine: .claude).map(\.action) == [.taskboard(.exit)])
        #expect(opened("/exit", .unknown) == nil)
    }

    @Test("codex の /new・/clear は新しい thread を始める操作。Claude の /new・/clear は CLI の clear（別名 new）に送る")
    func newThread() {
        for text in ["/new", "/clear"] {
            #expect(opened(text, .codex) == .taskboard(.new), "\(text)")
            #expect(unsupported(text, .codex) == nil, "\(text)")
        }
        let commands = [ConversationCommand(name: "clear", description: "Clear", builtin: true, aliases: ["reset", "new"])]
        for text in ["/new", "/clear"] {
            #expect(opened(text, .claude, commands: commands) == nil, "\(text)")
            #expect(unsupported(text, .claude, commands: commands) == nil, "\(text)")
        }
        #expect(ConversationSlashItem.matching("cle", commands: commands, engine: .claude).map(\.action) == [.send("clear")])
        #expect(ConversationSlashItem.matching("ne", commands: [], engine: .codex).map(\.action) == [.taskboard(.new)])
    }

    @Test("同じ名前でも engine の表に従う（/review は Claude では表に無く送り、codex では taskboard の操作）")
    func perEngine() {
        #expect(unsupported("/review", .claude) == nil && opened("/review", .claude) == nil)
        #expect(opened("/review", .codex) == .taskboard(.review))
        #expect(unsupported("/bashes", .codex) == nil && opened("/bashes", .codex) == nil)
        #expect(unsupported("/approvals", .claude) == nil && opened("/approvals", .claude) == nil)
    }

    @Test("Claude で CLI の一覧にある名前（alias を含む）は、表にあっても送る。codex は一覧を返さないので常に表に従う")
    func commandListWins() {
        let commands = [
            ConversationCommand(name: "theme", description: "Theme", builtin: true),
            ConversationCommand(name: "background", description: "Background", builtin: true, aliases: ["bg"]),
            ConversationCommand(name: "tasks", description: "Tasks", builtin: true, aliases: ["bashes"]),
        ]
        #expect(unsupported("/theme", .claude, commands: commands) == nil)
        #expect(unsupported("/THEME", .claude, commands: commands) == nil)
        #expect(unsupported("/bg", .claude, commands: commands) == nil)
        #expect(opened("/bashes", .claude, commands: commands) == nil, "一覧にあるので代わりの画面を開かず CLI に送る")
        #expect(unsupported("/vim", .claude, commands: commands) != nil)
        #expect(unsupported("/theme", .codex, commands: commands) != nil)
    }

    @Test("表に無い /… と、パスで始まる文と、文の途中の /… は塞がない。名前は完全一致で、大文字と小文字は区別しない")
    func unknownIsSent() {
        for text in ["/mytool", "/themes", "/Users/me/app/main.swift を見て", "/usr/bin", "この /theme を", "theme", "/", "", "  "] {
            #expect(unsupported(text, .claude) == nil && opened(text, .claude) == nil, "\(text)")
            #expect(unsupported(text, .codex) == nil && opened(text, .codex) == nil, "\(text)")
        }
        #expect(unsupported("/Theme", .claude)?.name == "theme")
        #expect(unsupported("  /LOGOUT now \n", .claude) == ConversationUnsupportedCommand(name: "logout"))
        #expect(opened("/Bashes", .claude) == .taskboard(.tasks))
    }

    @Test("/exit・/quit・/stop は表に入れない。知らない engine は何も振り分けない")
    func excluded() {
        for name in ["exit", "quit", "stop"] {
            #expect(unsupported("/\(name)", .claude) == nil, "\(name)")
            #expect(unsupported("/\(name)", .codex) == nil, "\(name)")
        }
        #expect(unsupported("/theme", .unknown) == nil && opened("/bashes", .unknown) == nil)
    }

    @Test("/ の候補に、端末で使えるものと会話では要らないものを出さない")
    func notSuggested() {
        let commands = [ConversationCommand(name: "clear", description: "Clear", builtin: true)]
        for engine in [Conversation.Engine.claude, .codex] {
            let names = ConversationSlashItem.matching("", commands: commands, engine: engine, limit: 1000).map(\.name)
            for hidden in ["theme", "logout", "ide", "bashes", "approvals"] {
                #expect(!names.contains(hidden), "\(engine) \(hidden)")
            }
            #expect(names.contains("review") == (engine == .codex), "\(engine) review は codex だけ taskboard の操作")
        }
    }
}
