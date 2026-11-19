import Foundation

// 会話の読む画面とその場の操作（`/export`・`/tasks`・`/permissions`・`/hooks`・`/memory`・`/skills`・`/btw`・`/add-dir`・`/cd`・`/login`）の応答。
// daemon が engine の応答から要る欄だけを写して返す

/// `export_conversation`：会話を文にしたもの
public struct ConversationExport: Codable, Hashable, Sendable {
    public var text: String
    /// 保存するときに出すファイル名（時刻と最初の指示。.txt）
    public var defaultFilename: String

    public init(text: String, defaultFilename: String) {
        self.text = text
        self.defaultFilename = defaultFilename
    }
}

/// `list_background_tasks`：今動いている裏のタスク
public struct ConversationBackgroundTasks: Codable, Hashable, Sendable {
    public struct Task: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        /// engine の種類の名前（Claude Code は `local_bash`・`local_agent` など）
        public var type: String?
        public var description: String?
        /// Claude Code だけ。false は前景（Claude Code が結果を待っている）、true は裏に回ったもの。nil は分からない（前の版の daemon・codex）
        public var backgrounded: Bool?
        /// 以下は codex の裏のターミナルだけ（Claude Code は返さない）
        public var cwd: String?
        public var pid: Int?
        public var cpuPercent: Double?
        public var memoryKB: Int?

        public init(
            id: String, type: String? = nil, description: String? = nil, backgrounded: Bool? = nil, cwd: String? = nil, pid: Int? = nil,
            cpuPercent: Double? = nil, memoryKB: Int? = nil
        ) {
            self.id = id
            self.type = type
            self.description = description
            self.backgrounded = backgrounded
            self.cwd = cwd
            self.pid = pid
            self.cpuPercent = cpuPercent
            self.memoryKB = memoryKB
        }
    }

    public var tasks: [Task]
    /// 一覧が分かっているか。host の控えから行が落ちた会話は分からない
    public var known: Bool

    public init(tasks: [Task], known: Bool = true) {
        self.tasks = tasks
        self.known = known
    }
}

/// 裏のタスク 1 つの様子（`Conversation.backgroundTaskStates`）。id はツールの結果の `ChatMessage.backgroundTaskID` と同じ値
public struct ConversationBackgroundTaskState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running, completed, failed
        /// 止めた（Claude Code の `killed`・`stopped`）
        case stopped
        /// 終わったが終わり方が分からない（プロセスが終わった・知らせなしに一覧から消えた）。新しい daemon が足した値もこれと読む
        case ended

        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .ended
        }
    }

    public var id: String
    public var status: Status

    public init(id: String, status: Status) {
        self.id = id
        self.status = status
    }
}

/// `task_output`：裏のタスクの出力の末尾
public struct ConversationTaskOutput: Codable, Hashable, Sendable {
    /// 出力の末尾（Claude Code は 8KiB まで）。エスケープの列もそのまま入るので、文として出す
    public var output: String
    public var totalBytes: Int
    /// `output` が長い出力の末尾だけか（codex は頭の出力が揃っているか分からないので、いつも true）
    public var truncated: Bool

    public init(output: String, totalBytes: Int, truncated: Bool) {
        self.output = output
        self.totalBytes = totalBytes
        self.truncated = truncated
    }
}

/// `permission_rules`：権限の規則と、足した作業フォルダ
public struct ConversationPermissionRules: Codable, Hashable, Sendable {
    public struct Rule: Codable, Hashable, Sendable {
        /// allow・deny・ask
        public var behavior: String
        /// 規則の出どころ（userSettings・projectSettings・localSettings・session・cliArg など）
        public var source: String
        /// 規則の文字のまま
        public var rule: String
        /// `edit_settings` で外せる（出どころがユーザー・作業フォルダの設定のファイル）
        public var editable: Bool?

        public init(behavior: String, source: String, rule: String, editable: Bool? = nil) {
            self.behavior = behavior
            self.source = source
            self.rule = rule
            self.editable = editable
        }
    }

    public struct Directory: Codable, Hashable, Sendable {
        public var path: String
        public var source: String

        public init(path: String, source: String) {
            self.path = path
            self.source = source
        }
    }

    /// 規則の形でない権限の設定（codex の approval_policy・sandbox_mode など。Claude Code は無い）
    public struct Setting: Codable, Hashable, Sendable {
        /// 設定の鍵（codex の config.toml の点区切りの鍵）
        public var key: String
        public var value: String
        /// 出どころ（session は今の会話に効いている値、ほかは user・project・system・mdm など設定の層）
        public var source: String

        public init(key: String, value: String, source: String) {
            self.key = key
            self.value = value
            self.source = source
        }
    }

    public var rules: [Rule]
    public var directories: [Directory]
    public var settings: [Setting]?

    public init(rules: [Rule], directories: [Directory], settings: [Setting]? = nil) {
        self.rules = rules
        self.directories = directories
        self.settings = settings
    }
}

/// `hooks`：hook の一覧（読むだけ）
public struct ConversationHooks: Codable, Hashable, Sendable {
    public struct Hook: Codable, Hashable, Sendable {
        public var event: String
        /// 空なら絞り込みなし
        public var matcher: String
        /// 出どころ（userSettings・projectSettings・localSettings・policySettings・sessionHook・pluginHook など）
        public var source: String
        /// plugin の hook なら plugin の名前
        public var plugin: String?
        /// command・prompt・http など
        public var type: String
        /// 動くもの（command・prompt・URL）の文字
        public var command: String
        /// 以下は codex だけ（Claude Code は返さない）
        public var enabled: Bool?
        /// managed・untrusted・trusted・modified（信頼していない hook は動かない）
        public var trust: String?
        /// 定めているファイル
        public var sourcePath: String?
        public var timeoutSeconds: Int?
        public var isAsync: Bool?
        public var statusMessage: String?
        /// 管理者の設定のもの
        public var managed: Bool?
        /// `edit_settings` で置き換え・外す（codex は有効と信頼も）ときにこの hook を指す鍵（hook の中身のハッシュ。中身はアプリに出さない）。
        /// 書き換えられない hook は nil
        public var editKey: String?
        /// `edit_settings` で置き換え・外すことができる（daemon が断る条件と同じ判定。Claude は出どころが user・project・local の設定の行、
        /// codex は管理者のものでなくユーザーの `config.toml` にある hook）。codex の有効と信頼は `editKey` があれば替えられる
        public var editable: Bool?

        public init(
            event: String, matcher: String, source: String, plugin: String? = nil, type: String, command: String, enabled: Bool? = nil, trust: String? = nil,
            sourcePath: String? = nil, timeoutSeconds: Int? = nil, isAsync: Bool? = nil, statusMessage: String? = nil, managed: Bool? = nil,
            editKey: String? = nil, editable: Bool? = nil
        ) {
            self.event = event
            self.matcher = matcher
            self.source = source
            self.plugin = plugin
            self.type = type
            self.command = command
            self.enabled = enabled
            self.trust = trust
            self.sourcePath = sourcePath
            self.timeoutSeconds = timeoutSeconds
            self.isAsync = isAsync
            self.statusMessage = statusMessage
            self.managed = managed
            self.editKey = editKey
            self.editable = editable
        }
    }

    public var hooks: [Hook]
    /// 読めなかった設定のファイル（codex だけ）
    public var problems: [ConversationReadoutProblem]?
    public var warnings: [String]?

    public init(hooks: [Hook], problems: [ConversationReadoutProblem]? = nil, warnings: [String]? = nil) {
        self.hooks = hooks
        self.problems = problems
        self.warnings = warnings
    }
}

/// `memory`：読み込んでいるメモリのファイル
public struct ConversationMemory: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        /// user・project・project-alt・local・other
        public var kind: String
        public var path: String
        public var exists: Bool

        public init(kind: String, path: String, exists: Bool) {
            self.kind = kind
            self.path = path
            self.exists = exists
        }
    }

    /// 有効と無効を切り替えられる設定（Claude Code の自動のメモリとその整理）
    public struct Toggle: Codable, Hashable, Sendable {
        public var enabled: Bool
        /// 今は切り替えられない（自動のメモリが無効なときの整理など）
        public var toggleable: Bool

        public init(enabled: Bool, toggleable: Bool) {
            self.enabled = enabled
            self.toggleable = toggleable
        }
    }

    public var files: [File]
    public var autoMemory: Toggle?
    public var autoDream: Toggle?

    public init(files: [File], autoMemory: Toggle? = nil, autoDream: Toggle? = nil) {
        self.files = files
        self.autoMemory = autoMemory
        self.autoDream = autoDream
    }
}

/// `skills`：skill の一覧
public struct ConversationSkills: Codable, Hashable, Sendable {
    public struct Skill: Codable, Hashable, Sendable {
        public var name: String
        public var displayName: String
        public var description: String
        /// 出どころ（user・project・plugin・built-in など。engine の文のまま）
        public var source: String
        /// system prompt に入る見積もりのトークン
        public var tokens: Int?
        /// on・name-only・user-invocable-only・off
        public var state: String
        /// 以下は codex だけ（Claude Code は返さない）
        public var path: String?
        public var plugin: String?
        public var shortDescription: String?

        public init(
            name: String, displayName: String, description: String, source: String, tokens: Int? = nil, state: String, path: String? = nil,
            plugin: String? = nil, shortDescription: String? = nil
        ) {
            self.name = name
            self.displayName = displayName
            self.description = description
            self.source = source
            self.tokens = tokens
            self.state = state
            self.path = path
            self.plugin = plugin
            self.shortDescription = shortDescription
        }
    }

    public var skills: [Skill]
    /// 読めなかった skill のファイル（codex だけ）
    public var problems: [ConversationReadoutProblem]?

    public init(skills: [Skill], problems: [ConversationReadoutProblem]? = nil) {
        self.skills = skills
        self.problems = problems
    }
}

/// `side_question`：脇の質問への答え（会話の記録には入らない）
public struct ConversationSideAnswer: Codable, Hashable, Sendable {
    public var response: String

    public init(response: String) {
        self.response = response
    }
}

/// `add_directory`：足した作業フォルダ（実体のパス）
public struct ConversationDirectoryAdded: Codable, Hashable, Sendable {
    public var directory: String

    public init(directory: String) {
        self.directory = directory
    }
}

/// `set_cwd`：作業フォルダを替えた結果。替えたのは `moved` のときだけ
public struct ConversationCwdChange: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case moved
        /// そのフォルダを信頼していない（アプリは信頼を与えず、端末で開くよう案内する）
        case needsTrust = "needs_trust"
        case rejected
        /// この版が知らない答え
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var outcome: Outcome
    /// 替えた後の作業フォルダ（`moved`）か、信頼が要るフォルダ（`needsTrust`）
    public var directory: String?
    /// 断った理由（not_found・not_a_directory・blocked_by_rule・busy・unsafe_path）
    public var reason: String?

    public init(outcome: Outcome, directory: String? = nil, reason: String? = nil) {
        self.outcome = outcome
        self.directory = directory
        self.reason = reason
    }
}

/// `login`：ログインのページ。要求した端末への応答にだけ載せる（ログ・state・DB・知らせに出さない）
public struct ConversationLogin: Codable, Hashable, Sendable {
    /// ほかの端末で開くページ。ログインを終えるとページにコードが出るので、`login_code` で渡す
    public var manualURL: String
    /// 会話の Mac のブラウザで開くページ。ログインを終えると CLI に戻り、コードは要らない
    public var automaticURL: String
    /// ページで打ち込むコード（codex の device code。どの端末で開いても同じページで、`login_code` は使わない）
    public var userCode: String?

    public init(manualURL: String, automaticURL: String, userCode: String? = nil) {
        self.manualURL = manualURL
        self.automaticURL = automaticURL
        self.userCode = userCode
    }
}

/// 読む画面の一覧で、読めなかったファイルと理由
public struct ConversationReadoutProblem: Codable, Hashable, Sendable {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

/// `plugins`：plugin と marketplace の一覧。入れられる plugin は多い（公式の目録で数千件）ので、`value` の文字で絞り、`availableLimit` 件までにする
public struct ConversationPlugins: Codable, Hashable, Sendable {
    public static let availableLimit = 200

    public struct Plugin: Codable, Hashable, Sendable {
        /// `<名前>@<marketplace>`
        public var id: String
        public var name: String
        public var marketplace: String
        public var description: String?
        public var version: String?
        /// 入れた層（Claude の user・project・local）。入れていなければ nil
        public var scope: String?
        public var installed: Bool
        public var enabled: Bool?
        /// 取り込み元の種類（local・github・git・url・npm・archive・command・remote など）
        public var source: String?
        /// 保存する設定（userConfig）がある
        public var hasOptions: Bool?

        public init(
            id: String, name: String, marketplace: String, description: String? = nil, version: String? = nil, scope: String? = nil, installed: Bool,
            enabled: Bool? = nil, source: String? = nil, hasOptions: Bool? = nil
        ) {
            self.id = id
            self.name = name
            self.marketplace = marketplace
            self.description = description
            self.version = version
            self.scope = scope
            self.installed = installed
            self.enabled = enabled
            self.source = source
            self.hasOptions = hasOptions
        }
    }

    public struct Marketplace: Codable, Hashable, Sendable {
        public var name: String
        /// 足した元（パス・URL・owner/repo）
        public var source: String?

        public init(name: String, source: String? = nil) {
            self.name = name
            self.source = source
        }
    }

    public var installed: [Plugin]
    /// 入れていない plugin のうち、絞る文字に合うもの（`availableLimit` 件まで）
    public var available: [Plugin]
    /// 絞る文字に合う入れていない plugin の数（`available` が切れていればそれより多い）
    public var availableTotal: Int
    public var marketplaces: [Marketplace]

    public init(installed: [Plugin], available: [Plugin], availableTotal: Int, marketplaces: [Marketplace]) {
        self.installed = installed
        self.available = available
        self.availableTotal = availableTotal
        self.marketplaces = marketplaces
    }

    /// 入れていない plugin を、名前・説明・id に文字を含むもの（大文字と小文字は区別しない）に絞り、`availableLimit` 件までにする
    public static func filtered(_ plugins: [Plugin], query: String?) -> (plugins: [Plugin], total: Int) {
        let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let matched = needle.isEmpty ? plugins : plugins.filter { plugin in
            [plugin.id, plugin.name, plugin.description ?? ""].contains { $0.lowercased().contains(needle) }
        }
        return (Array(matched.prefix(availableLimit)), matched.count)
    }
}

/// 会話の計画の 1 項目（Claude Code の TaskCreate・TaskUpdate の一覧）。並びは作った順
public struct ConversationPlanItem: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, inProgress, completed

        /// 新しい daemon が足した値は未着手と読む
        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pending
        }
    }

    public var id: String
    public var title: String
    /// 進めている間に出す文（「〜を調査中」）。engine が付けなければ nil
    public var activeTitle: String?
    public var status: Status

    public init(id: String, title: String, activeTitle: String? = nil, status: Status) {
        self.id = id
        self.title = title
        self.activeTitle = activeTitle
        self.status = status
    }
}
