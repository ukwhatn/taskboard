import Foundation

/// CLI に送らずに案内する組み込みのコマンド（会話では動かないもの）
public struct ConversationUnsupportedCommand: Hashable, Sendable {
    /// `/` を除いた小文字の名前
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

/// engine ごとの組み込みのコマンドの表。送る前に、代わりの画面を開くか、会話では使えないと案内するかを決める。
/// 表に無い名前は今までどおり送る（`/Users/…` のようなパスで始まる文を塞がない）。`/exit`・`/quit` は taskboard の操作（`ConversationTaskboardAction.exit`）が、`/stop` は会話の停止の扱いで別に決めるので入れない
enum ConversationBuiltinCommands {
    enum Disposition: Hashable {
        /// taskboard の操作が代わりになる
        case alternative(ConversationTaskboardAction)
        /// 会話では使えない（TUI でだけ動くか、会話では要らない）
        case unsupported
    }

    private static func table(alternatives: [String: ConversationTaskboardAction], unsupported: [String]) -> [String: Disposition] {
        alternatives.mapValues(Disposition.alternative)
            .merging(unsupported.map { ($0, Disposition.unsupported) }, uniquingKeysWith: { _, _ in preconditionFailure("表に同じ名前が 2 回ある") })
    }

    private static let claude = table(
        alternatives: [
            "bashes": .tasks, "allowed-tools": .permissions, "checkpoint": .rewind, "undo": .rewind, "branch": .fork, "subtask": .fork, "plugins": .plugin,
            "marketplace": .plugin,
        ],
        unsupported: [
            "logout", "sandbox", "chrome", "plan", "bug", "share", "remote-control", "rc", "privacy-settings",
            "release-notes", "upgrade", "rate-limit-options", "extra-usage", "install-github-app", "design-login", "voice", "restart", "update",
            "install-slack-app", "keybindings", "statusline", "web-setup", "remote-env", "teleport", "tp", "ultraplan", "autofix-pr", "desktop", "app",
            "mobile", "ios", "android", "workflows", "background", "bg", "setup-bedrock", "setup-vertex",
            "ide", "terminal-setup", "vim", "theme", "tui", "scroll-speed", "copy", "powerup", "stickers", "radio", "help", "resume", "continue"])

    /// `/mcp` の欄は `ConversationControlField` が受ける
    private static let codex = table(
        alternatives: ["approvals": .permissions, "memories": .memory, "ps": .tasks, "plugins": .plugin],
        unsupported: [
            "daybreak", "experimental", "import", "archive", "delete", "worktree", "init", "recap", "plan",
            "goal", "agents", "subagents", "side", "mention", "debug-config", "apps", "logout", "feedback", "voice", "setup-default-sandbox",
            "ide", "keymap", "vim", "copy", "raw", "tui", "title", "statusline", "theme", "pets", "app", "daemon", "rollout", "pwd", "test-approval", "resume"])

    /// 文の頭の `/名前` の、その engine での扱い。Claude は、CLI の一覧（名前と alias）にある名前を表より先に CLI に任せる（CLI の版が上がって動くようになったものを塞がない）
    static func disposition(of text: String, engine: Conversation.Engine, commands: [ConversationCommand]) -> (name: String, disposition: Disposition)? {
        guard let name = ConversationSlashItem.typedName(text)?.lowercased() else { return nil }
        let table: [String: Disposition]
        switch engine {
        case .claude:
            guard !commands.contains(where: { $0.name.lowercased() == name || ($0.aliases ?? []).contains { $0.lowercased() == name } }) else { return nil }
            table = claude
        case .codex: table = codex
        case .unknown: return nil
        }
        return table[name].map { (name, $0) }
    }
}

extension ConversationSlashItem {
    /// 文の頭の `/名前` の名前。`/` で始まらない文と、名前が空の文は nil
    static func typedName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let name = String(trimmed.dropFirst().prefix { !$0.isWhitespace })
        return name.isEmpty ? nil : name
    }

    /// 送ろうとした文を、CLI に送らずに「会話では使えない」と案内するなら、その名前。代わりの画面があるものは `intercepted` が開く。
    /// CLI に送れない engine の欄で、`unavailableFields` で開けないもの（モデルの一覧が無いマシンの `/model`）も案内する
    public static func unsupported(
        _ text: String, engine: Conversation.Engine, commands: [ConversationCommand], unavailableFields: Set<ConversationControlField> = []
    ) -> ConversationUnsupportedCommand? {
        if !engine.hasCLICommands, let name = typedName(text)?.lowercased(), ConversationControlField(rawValue: name) != nil,
            intercepted(text, engine: engine, commands: commands, unavailableFields: unavailableFields) == nil
        {
            return ConversationUnsupportedCommand(name: name)
        }
        guard let (name, disposition) = ConversationBuiltinCommands.disposition(of: text, engine: engine, commands: commands) else { return nil }
        switch disposition {
        case .alternative: return nil
        case .unsupported: return ConversationUnsupportedCommand(name: name)
        }
    }
}
