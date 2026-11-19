import Foundation

// 会話の `control` の `edit_settings` で書く設定。engine に依らない形で受け、daemon が engine の口（Claude Code は CLI のサブコマンド）に読み替える

/// 書く設定の層。値は読む画面の出どころ（`source`）と同じ名前
public enum ConversationSettingsScope: String, Codable, Hashable, Sendable, CaseIterable {
    /// その Mac のユーザーの設定（すべての会話に効く）
    case user = "userSettings"
    /// 作業フォルダの共有する設定（`.claude/settings.json`）
    case project = "projectSettings"
    /// 作業フォルダの自分だけの設定（`.claude/settings.local.json`）
    case local = "localSettings"
}

public enum ConversationSettingsEdit: Hashable, Sendable {
    public enum Target: String, Codable, Hashable, Sendable, CaseIterable {
        case permissionRule = "permission_rule"
        case hook
        case memory
        case skill
        case sandbox
        case permissionSetting = "permission_setting"
        case hookState = "hook_state"
        case mcpServer = "mcp_server"
        case plugin
        case marketplace
    }

    public enum Op: String, Codable, Hashable, Sendable {
        case add, replace, remove
    }

    public enum PluginOp: String, Codable, Hashable, Sendable {
        /// 入れる。marketplace が決めたコマンドで入れる plugin（Claude）は、1 回目に結果の `shownCommand` を返して入れない。
        /// 人がそのコマンドを見て選んだら、`acceptCommand` に `shownCommand.sha256` を入れてもう一度送る
        case install
        /// 外す。plugin のデータの置き場は残す。保存した設定（plugin の userConfig）がある plugin は設定が消えるので、
        /// 結果の `confirmation` を返して外さない。人が確かめたら `confirm: true` と `confirmation.digest` を付けて送り直す
        case uninstall
        /// データの置き場ごと外す（Claude。元に戻せない）。いつも `confirmation` を返し、`uninstall` と同じく確かめてから外す
        case purge
        case enable, disable
        /// 新しい版にする（`shownCommand` は install と同じ）
        case update
    }

    public enum MarketplaceOp: String, Codable, Hashable, Sendable {
        /// 足す（`source` はパス・URL・GitHub の owner/repo）
        case add
        /// 外す（`name`）。その marketplace から入れた plugin（`scope` を付けたらその層のものだけ）を先に外す（データは残す。
        /// 保存した設定があれば `confirmation`）
        case remove
        /// 中身を取り直す（`name`）
        case update
    }

    /// hook の中身。`type` は command・prompt・http・agent で、command は `command`、prompt と agent は `prompt`、http は `url` を使う
    public struct HookBody: Codable, Hashable, Sendable {
        public var type: String
        public var command: String?
        public var prompt: String?
        public var url: String?
        public var timeout: Int?
        public var statusMessage: String?

        public init(type: String, command: String? = nil, prompt: String? = nil, url: String? = nil, timeout: Int? = nil, statusMessage: String? = nil) {
            self.type = type
            self.command = command
            self.prompt = prompt
            self.url = url
            self.timeout = timeout
            self.statusMessage = statusMessage
        }
    }

    /// 権限の規則を足す（add。1〜100 個）か外す（remove。1 個。読む画面の `rule` の文字のまま）。`behavior` は allow・deny・ask（Claude）
    case permissionRule(op: Op, behavior: String, rules: [String], scope: ConversationSettingsScope)
    /// hook を足す（add）・置き換える（replace）・外す（remove）。replace と remove は読む画面の `editKey` で指す。
    /// codex はユーザーの設定（`config.toml`）にだけ書き、種類は command だけ
    case hook(op: Op, scope: ConversationSettingsScope, event: String, matcher: String, hook: HookBody?, editKey: String?)
    /// 自動のメモリと、その整理（dream）の有効と無効（ユーザーの設定）
    case memory(autoMemory: Bool?, autoDream: Bool?)
    /// skill の状態。Claude は on・name-only・user-invocable-only・off（作業フォルダの自分だけの設定）、codex は on・off（ユーザーの設定）。
    /// codex で同じ名前の skill が複数あるときは、読む画面の `path` で指す
    case skill(name: String, path: String? = nil, state: String)
    /// sandbox の動き方（auto-allow・regular・disabled）と、sandbox の外で動かすのを許すか（作業フォルダの自分だけの設定）
    case sandbox(mode: String?, allowUnsandboxedCommands: Bool?)
    /// 権限の設定の値（codex。鍵は approval_policy・approvals_reviewer・sandbox_mode・default_permissions・
    /// sandbox_workspace_write の network_access・exclude_tmpdir_env_var・exclude_slash_tmp だけ）。nil で鍵を消す
    case permissionSetting(key: String, value: String?)
    /// hook の有効と信頼（codex）。`trusted` が true なら今の中身を信頼し、false なら信頼を外す
    case hookState(editKey: String, enabled: Bool?, trusted: Bool?)
    /// MCP の server の有効と無効（codex。ユーザーの設定にある server だけ。Claude は `mcp_toggle`）
    case mcpServer(name: String, enabled: Bool)
    /// plugin（`id` は `<名前>@<marketplace>`）。`scope` は Claude だけ（省けば CLI の既定）。codex はユーザーの設定だけ。
    /// `confirm` と `confirmDigest`（前の結果の `confirmation.digest`）は、確かめた後の送り直しで付ける
    case plugin(
        op: PluginOp, id: String, scope: ConversationSettingsScope? = nil, acceptCommand: String? = nil, confirm: Bool? = nil, confirmDigest: String? = nil)
    /// marketplace。`scope` は Claude だけ
    case marketplace(
        op: MarketplaceOp, source: String? = nil, name: String? = nil, scope: ConversationSettingsScope? = nil, confirm: Bool? = nil,
        confirmDigest: String? = nil)

    /// 人が `shownCommand` を見て選んだ後の送り直し（plugin だけ。ほかはそのまま）
    public func accepting(command sha256: String) -> Self {
        guard case .plugin(let op, let id, let scope, _, let confirm, let confirmDigest) = self else { return self }
        return .plugin(op: op, id: id, scope: scope, acceptCommand: sha256, confirm: confirm, confirmDigest: confirmDigest)
    }

    /// 人が `confirmation` を確かめた後の送り直し（plugin と marketplace だけ。ほかはそのまま）
    public func confirming(digest: String) -> Self {
        switch self {
        case .plugin(let op, let id, let scope, let acceptCommand, _, _):
            .plugin(op: op, id: id, scope: scope, acceptCommand: acceptCommand, confirm: true, confirmDigest: digest)
        case .marketplace(let op, let source, let name, let scope, _, _):
            .marketplace(op: op, source: source, name: name, scope: scope, confirm: true, confirmDigest: digest)
        default: self
        }
    }

    public var target: Target {
        switch self {
        case .permissionRule: .permissionRule
        case .hook: .hook
        case .memory: .memory
        case .skill: .skill
        case .sandbox: .sandbox
        case .permissionSetting: .permissionSetting
        case .hookState: .hookState
        case .mcpServer: .mcpServer
        case .plugin: .plugin
        case .marketplace: .marketplace
        }
    }
}

extension ConversationSettingsEdit: Codable {
    private enum CodingKeys: String, CodingKey {
        case target, op, behavior, rules, scope, event, matcher, hook, editKey, autoMemory, autoDream, name, path, state, mode, allowUnsandboxedCommands
        case key, value, enabled, trusted, id, acceptCommand, confirm, confirmDigest, source
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Target.self, forKey: .target) {
        case .permissionRule:
            self = .permissionRule(
                op: try c.decode(Op.self, forKey: .op), behavior: try c.decode(String.self, forKey: .behavior), rules: try c.decode([String].self, forKey: .rules),
                scope: try c.decode(ConversationSettingsScope.self, forKey: .scope))
        case .hook:
            self = .hook(
                op: try c.decode(Op.self, forKey: .op), scope: try c.decode(ConversationSettingsScope.self, forKey: .scope),
                event: try c.decode(String.self, forKey: .event), matcher: try c.decodeIfPresent(String.self, forKey: .matcher) ?? "",
                hook: try c.decodeIfPresent(HookBody.self, forKey: .hook), editKey: try c.decodeIfPresent(String.self, forKey: .editKey))
        case .memory:
            self = .memory(autoMemory: try c.decodeIfPresent(Bool.self, forKey: .autoMemory), autoDream: try c.decodeIfPresent(Bool.self, forKey: .autoDream))
        case .skill:
            self = .skill(
                name: try c.decode(String.self, forKey: .name), path: try c.decodeIfPresent(String.self, forKey: .path), state: try c.decode(String.self, forKey: .state))
        case .sandbox:
            self = .sandbox(
                mode: try c.decodeIfPresent(String.self, forKey: .mode),
                allowUnsandboxedCommands: try c.decodeIfPresent(Bool.self, forKey: .allowUnsandboxedCommands))
        case .permissionSetting:
            self = .permissionSetting(key: try c.decode(String.self, forKey: .key), value: try c.decodeIfPresent(String.self, forKey: .value))
        case .hookState:
            self = .hookState(
                editKey: try c.decode(String.self, forKey: .editKey), enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled),
                trusted: try c.decodeIfPresent(Bool.self, forKey: .trusted))
        case .mcpServer:
            self = .mcpServer(name: try c.decode(String.self, forKey: .name), enabled: try c.decode(Bool.self, forKey: .enabled))
        case .plugin:
            self = .plugin(
                op: try c.decode(PluginOp.self, forKey: .op), id: try c.decode(String.self, forKey: .id),
                scope: try c.decodeIfPresent(ConversationSettingsScope.self, forKey: .scope), acceptCommand: try c.decodeIfPresent(String.self, forKey: .acceptCommand),
                confirm: try c.decodeIfPresent(Bool.self, forKey: .confirm), confirmDigest: try c.decodeIfPresent(String.self, forKey: .confirmDigest))
        case .marketplace:
            self = .marketplace(
                op: try c.decode(MarketplaceOp.self, forKey: .op), source: try c.decodeIfPresent(String.self, forKey: .source),
                name: try c.decodeIfPresent(String.self, forKey: .name), scope: try c.decodeIfPresent(ConversationSettingsScope.self, forKey: .scope),
                confirm: try c.decodeIfPresent(Bool.self, forKey: .confirm), confirmDigest: try c.decodeIfPresent(String.self, forKey: .confirmDigest))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        switch self {
        case .permissionRule(let op, let behavior, let rules, let scope):
            try c.encode(op, forKey: .op)
            try c.encode(behavior, forKey: .behavior)
            try c.encode(rules, forKey: .rules)
            try c.encode(scope, forKey: .scope)
        case .hook(let op, let scope, let event, let matcher, let hook, let editKey):
            try c.encode(op, forKey: .op)
            try c.encode(scope, forKey: .scope)
            try c.encode(event, forKey: .event)
            try c.encode(matcher, forKey: .matcher)
            try c.encodeIfPresent(hook, forKey: .hook)
            try c.encodeIfPresent(editKey, forKey: .editKey)
        case .memory(let autoMemory, let autoDream):
            try c.encodeIfPresent(autoMemory, forKey: .autoMemory)
            try c.encodeIfPresent(autoDream, forKey: .autoDream)
        case .skill(let name, let path, let state):
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(state, forKey: .state)
        case .sandbox(let mode, let allowUnsandboxedCommands):
            try c.encodeIfPresent(mode, forKey: .mode)
            try c.encodeIfPresent(allowUnsandboxedCommands, forKey: .allowUnsandboxedCommands)
        case .permissionSetting(let key, let value):
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(value, forKey: .value)
        case .hookState(let editKey, let enabled, let trusted):
            try c.encode(editKey, forKey: .editKey)
            try c.encodeIfPresent(enabled, forKey: .enabled)
            try c.encodeIfPresent(trusted, forKey: .trusted)
        case .mcpServer(let name, let enabled):
            try c.encode(name, forKey: .name)
            try c.encode(enabled, forKey: .enabled)
        case .plugin(let op, let id, let scope, let acceptCommand, let confirm, let confirmDigest):
            try c.encode(op, forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(scope, forKey: .scope)
            try c.encodeIfPresent(acceptCommand, forKey: .acceptCommand)
            try c.encodeIfPresent(confirm, forKey: .confirm)
            try c.encodeIfPresent(confirmDigest, forKey: .confirmDigest)
        case .marketplace(let op, let source, let name, let scope, let confirm, let confirmDigest):
            try c.encode(op, forKey: .op)
            try c.encodeIfPresent(source, forKey: .source)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(scope, forKey: .scope)
            try c.encodeIfPresent(confirm, forKey: .confirm)
            try c.encodeIfPresent(confirmDigest, forKey: .confirmDigest)
        }
    }
}

/// `edit_settings` の結果。断られたときは `session_command_failed` の失敗で、params の `reason` に理由の種類
/// （duplicate・not_found・ambiguous・locked・file_error・invalid・conflict・other）が入る
public struct ConversationSettingsEditResult: Codable, Hashable, Sendable {
    /// engine が返した注意の文。engine の文は書いた値（規則・hook のコマンドの秘密）を引用しうるので、daemon は入れない（いつも空）
    public var warnings: [String]
    /// 書いた権限の規則（engine が整えた形。規則を足したときだけ）
    public var stored: [String]?
    /// 動いている会話に効かせるには会話を起こし直す
    public var needsRestart: Bool
    /// 書いた値がこの会話に効かない理由。`permission_mode` は taskboard の会話が開くときに渡す権限のモードが勝つ
    /// （端末で起こす codex には効く）。ほかは上書きしている設定の層の名前（project・system など）
    public var overriddenBy: String?
    /// まだ書いていない：marketplace が決めたこのコマンドを動かして入れる。人に見せ、選んだら `acceptCommand` に `sha256` を入れて送り直す
    public var shownCommand: ShownCommand?
    /// まだ書いていない：書くと元に戻せないものが消える。人に確かめ、`confirm: true` と `digest` を付けて送り直す
    public var confirmation: Confirmation?
    /// 入れた plugin のアプリのうち、使う前にログインが要るもの（codex。名前）
    public var appsNeedingAuth: [String]?

    public struct ShownCommand: Codable, Hashable, Sendable {
        public var command: String
        public var sha256: String

        public init(command: String, sha256: String) {
            self.command = command
            self.sha256 = sha256
        }
    }

    public struct Confirmation: Codable, Hashable, Sendable {
        public enum Loss: String, Codable, Hashable, Sendable {
            /// plugin のデータの置き場
            case data
            /// plugin の保存した設定（userConfig。秘密の値を含む）
            case options
        }
        public struct Target: Codable, Hashable, Sendable {
            /// `<名前>@<marketplace>`
            public var id: String
            /// 入れた層（user・project・local）
            public var scope: String?

            public init(id: String, scope: String? = nil) {
                self.id = id
                self.scope = scope
            }
        }

        public var loss: Loss
        /// 外す plugin（marketplace を外すときは、その marketplace から外す plugin の全部）
        public var plugins: [Target]
        /// 消える設定の名前（値は入れない）
        public var options: [String]
        /// 外す plugin・層・消える設定の名前から作った値。送り直しの `confirmDigest` に入れる。daemon は書く直前の対象から作り直し、
        /// 合わなければ（人が見た後に対象が替わった）書かずに新しい `confirmation` を返す
        public var digest: String

        public init(loss: Loss, plugins: [Target], options: [String] = [], digest: String) {
            self.loss = loss
            self.plugins = plugins
            self.options = options
            self.digest = digest
        }
    }

    public init(
        warnings: [String] = [], stored: [String]? = nil, needsRestart: Bool = false, overriddenBy: String? = nil, shownCommand: ShownCommand? = nil,
        confirmation: Confirmation? = nil, appsNeedingAuth: [String]? = nil
    ) {
        self.warnings = warnings
        self.stored = stored
        self.needsRestart = needsRestart
        self.overriddenBy = overriddenBy
        self.shownCommand = shownCommand
        self.confirmation = confirmation
        self.appsNeedingAuth = appsNeedingAuth
    }
}

/// `sandbox`：sandbox の状態
public struct ConversationSandbox: Codable, Hashable, Sendable {
    /// この Mac で sandbox を使えるか
    public var supported: Bool
    /// 上の層の設定（管理者の設定など）で固定されていて、ここでは替えられない
    public var locked: Bool
    public var enabled: Bool
    /// auto-allow・regular・disabled
    public var mode: String
    public var autoAllowAvailable: Bool
    /// sandbox で動かせないコマンドを sandbox の外で動かすのを許すか
    public var allowUnsandboxedCommands: Bool
    /// sandbox の外で動かすコマンドの決まり（読むだけ。ここでは足せない）
    public var excludedCommands: [String]
    /// 要るものが入っていないので sandbox が動かない
    public var missingDependencies: Bool

    public init(
        supported: Bool, locked: Bool, enabled: Bool, mode: String, autoAllowAvailable: Bool, allowUnsandboxedCommands: Bool, excludedCommands: [String],
        missingDependencies: Bool
    ) {
        self.supported = supported
        self.locked = locked
        self.enabled = enabled
        self.mode = mode
        self.autoAllowAvailable = autoAllowAvailable
        self.allowUnsandboxedCommands = allowUnsandboxedCommands
        self.excludedCommands = excludedCommands
        self.missingDependencies = missingDependencies
    }
}

extension Conversation.Engine {
    /// `edit_settings` で書ける設定
    public func supports(edit target: ConversationSettingsEdit.Target) -> Bool {
        guard supports(ConversationControlRequest.Kind.editSettings) else { return false }
        switch (self, target) {
        case (.claude, .permissionRule), (.claude, .hook), (.claude, .memory), (.claude, .skill), (.claude, .sandbox): return true
        case (.codex, .permissionSetting), (.codex, .hook), (.codex, .hookState), (.codex, .skill), (.codex, .mcpServer): return true
        case (.claude, .plugin), (.claude, .marketplace), (.codex, .plugin), (.codex, .marketplace): return true
        default: return false
        }
    }
}
