import Foundation

/// 会話の画面の taskboard の操作（`/` の候補にも並べる）。名前は `/` の後に打つ語
public enum ConversationTaskboardAction: String, CaseIterable, Hashable, Sendable {
    case fork
    case rewind
    case shell
    case diff
    /// CLI の `/status`・`/cost`・`/usage` の画面の代わりに、会話の［状態］を開く
    case status
    case cost
    case usage
    /// CLI の TUI の画面の代わりにアプリのシートで開く（`/export`・`/tasks`・`/permissions`・`/hooks`・`/memory`・`/skills`）
    case export
    case tasks
    case permissions
    case hooks
    case memory
    case skills
    /// 引数を取る操作（`/btw <質問>`・`/add-dir <フォルダ>`・`/cd <フォルダ>`）
    case btw
    case addDir = "add-dir"
    case cd
    /// engine のアカウントのログイン（`/login`）。その Mac のすべてのセッションに効く
    case login
    /// CLI の `/plugin` の画面の代わりに、会話の［プラグイン］のシートを開く
    case plugin
    /// 会話を圧縮する（codex。Claude は CLI の `/compact` を送る）
    case compact
    /// 会話の名前を `/rename <名前>` の名前にする（codex。Claude は CLI の `/rename` を送る）
    case rename
    /// 同じ会話で新しい thread を始める（codex の `/new`・`/clear`。Claude は CLI の `/clear` を送る）
    case new
    /// コードをレビューさせる（codex の `/review`。後ろに書いた文はレビューの指示。Claude は CLI の `/review` を送る）
    case review
    /// 会話を終了する（`/exit`・`/quit`）。会話のメニューの［終了］と同じで、CLI には送らない
    case exit

    /// 名前のほかに受ける名前。CLI の一覧より先に taskboard の操作にする
    static let aliases: [String: ConversationTaskboardAction] = ["quit": .exit, "clear": .new]

    /// 打った文の後ろに引数を取るか。候補から選んだら、送らずに引数を入れるシートを開く
    public var takesArgument: Bool {
        switch self {
        case .btw, .addDir, .cd: true
        default: false
        }
    }
}

/// 入力欄の下の欄。`/` で選んだら送らずに開く（CLI の TUI の画面の代わり）
public enum ConversationControlField: String, CaseIterable, Hashable, Sendable {
    case model
    case effort
    case mcp
    case context
}

/// 会話の `/` の候補の 1 行
public struct ConversationSlashItem: Hashable, Sendable, Identifiable {
    public enum Action: Hashable, Sendable {
        /// 名前を入力欄に入れ、CLI に送る（名前と alias の解決は CLI がする）
        case send(String)
        case control(ConversationControlField)
        case taskboard(ConversationTaskboardAction)
    }

    public var name: String
    /// CLI のコマンドの説明。taskboard の操作と欄は nil（画面が文を持つ）
    public var description: String?
    public var argumentHint: String?
    public var builtin: Bool
    /// 打った語が名前でなく alias に合ったとき、その alias
    public var matchedAlias: String?
    public var action: Action

    public var id: String { name }

    /// 頭が合うもの（名前か alias）を先に、名前の途中に含むものを後に並べる。大文字と小文字は区別しない。
    /// CLI と同じ名前の taskboard の操作と欄は 1 行にし、taskboard の側にする。
    /// `leading` が false（文の途中の `/`）なら、CLI に送る組み込みでないものだけにする。
    /// 行の操作は `Conversation.Engine.slashAction` で engine に合わせる（無い操作と、無い欄・`unavailableFields` の欄は出さない）
    public static func matching(
        _ typed: String, commands: [ConversationCommand], engine: Conversation.Engine = .claude, unavailableFields: Set<ConversationControlField> = [],
        leading: Bool = true, limit: Int = 8
    ) -> [ConversationSlashItem] {
        let usable = items(commands, engine: engine).compactMap { item -> ConversationSlashItem? in
            guard let action = engine.slashAction(item.action, unavailable: unavailableFields) else { return nil }
            var usable = item
            usable.action = action
            return usable
        }
        let all = leading ? usable : usable.filter { item in
            if case .send = item.action { !item.builtin } else { false }
        }
        guard !typed.isEmpty else { return Array(all.prefix(limit)) }
        var head: [ConversationSlashItem] = []
        var inner: [ConversationSlashItem] = []
        let aliases = aliasesByName(commands)
        for item in all {
            if starts(item.name, with: typed) {
                head.append(item)
            } else if let alias = aliases[item.name]?.first(where: { starts($0, with: typed) }) {
                var hit = item
                hit.matchedAlias = alias
                head.append(hit)
            } else if item.name.range(of: typed, options: .caseInsensitive) != nil {
                inner.append(item)
            }
        }
        return Array((head + inner).prefix(limit))
    }

    /// 送ろうとした文（文の頭から `/名前` か `/名前 引数`）を、CLI に送らずにアプリが開くなら、その操作と引数。
    /// taskboard の操作はどの engine でも、欄は CLI が `/` を解釈しない engine（Codex）でだけ受ける。組み込みのコマンドの表で代わりの操作があるもの（`/bashes` など）も受ける。
    /// 行の操作は `matching` と同じく `slashAction` で決める
    public static func intercepted(
        _ text: String, engine: Conversation.Engine, commands: [ConversationCommand] = [], unavailableFields: Set<ConversationControlField> = []
    ) -> (action: Action, argument: String)? {
        guard let name = typedName(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let argument = trimmed.dropFirst(1 + name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let action: Action
        if let taskboard = ConversationTaskboardAction(rawValue: name) ?? ConversationTaskboardAction.aliases[name] {
            action = .taskboard(taskboard)
        } else if let field = ConversationControlField(rawValue: name), !engine.hasCLICommands {
            action = .control(field)
        } else if case .alternative(let taskboard)? = ConversationBuiltinCommands.disposition(of: text, engine: engine, commands: commands)?.disposition {
            action = .taskboard(taskboard)
        } else {
            return nil
        }
        return engine.slashAction(action, unavailable: unavailableFields).map { ($0, argument) }
    }

    /// CLI のコマンド（一覧の順）の後に、CLI に無い taskboard の操作を並べる。
    /// CLI が一覧を返さない engine（Codex）は CLI に無い欄も並べる（Claude Code は CLI の一覧にある欄だけを欄にする）
    private static func items(_ commands: [ConversationCommand], engine: Conversation.Engine) -> [ConversationSlashItem] {
        let actions = Dictionary(uniqueKeysWithValues: ConversationTaskboardAction.allCases.map { ($0.rawValue, $0) })
        let fields = Dictionary(uniqueKeysWithValues: ConversationControlField.allCases.map { ($0.rawValue, $0) })
        var seen = Set<String>()
        var result: [ConversationSlashItem] = []
        for command in commands where seen.insert(command.name).inserted {
            // CLI が一覧を返す engine で、その engine が使えない taskboard の操作と同じ名前のコマンド（Claude の `/compact`）は、CLI に送るまま
            let action: Action =
                if let taskboard = actions[command.name], engine.supports(action: taskboard) || !engine.hasCLICommands {
                    .taskboard(taskboard)
                } else if let field = fields[command.name] { .control(field) } else { .send(command.name) }
            let ownsText = if case .send = action { true } else { false }
            result.append(
                ConversationSlashItem(
                    name: command.name, description: ownsText ? command.description : nil, argumentHint: ownsText ? command.argumentHint : nil,
                    builtin: command.builtin == true, action: action))
        }
        for action in ConversationTaskboardAction.allCases where !seen.contains(action.rawValue) {
            result.append(ConversationSlashItem(name: action.rawValue, builtin: false, action: .taskboard(action)))
        }
        for field in ConversationControlField.allCases where !engine.hasCLICommands && !seen.contains(field.rawValue) {
            result.append(ConversationSlashItem(name: field.rawValue, builtin: false, action: .control(field)))
        }
        return result
    }

    /// 引ける alias。taskboard の操作と欄に替えたコマンドの alias は、CLI のものなので引かない
    private static func aliasesByName(_ commands: [ConversationCommand]) -> [String: [String]] {
        let owned = Set(ConversationTaskboardAction.allCases.map(\.rawValue) + ConversationControlField.allCases.map(\.rawValue))
        var result: [String: [String]] = [:]
        for command in commands where !owned.contains(command.name) && result[command.name] == nil {
            result[command.name] = command.aliases ?? []
        }
        return result
    }

    private static func starts(_ text: String, with typed: String) -> Bool {
        text.range(of: typed, options: [.caseInsensitive, .anchored]) != nil
    }

    public init(
        name: String, description: String? = nil, argumentHint: String? = nil, builtin: Bool, matchedAlias: String? = nil, action: Action
    ) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.builtin = builtin
        self.matchedAlias = matchedAlias
        self.action = action
    }
}

extension Conversation {

}

extension ChatMessage {
    /// 巻き戻せる発言。人が送った文だけで、taskboard が入れた知らせは除く（`/rewind` が委譲先の知らせの前まで戻すことになる）。
    /// 人が taskboard の画面で答えた回答と済ませた手作業は人の発言として残す
    public var isRewindTarget: Bool { isHumanPrompt && (taskboardNotice.map { $0 == .answer || $0 == .finished } ?? true) }

    /// フォークの起点にできる発言（transcript に行がある）。手元で作った知らせと、読み飛ばした行の印は除く
    public var isForkTarget: Bool {
        !["notice-", "large-", "line-"].contains { id.hasPrefix($0) }
    }
}

/// 巻き戻せる範囲。戻せるのは最後に圧縮した後の人の発言だけで、圧縮より前の発言は読むだけ（daemon も断る）
public struct ChatRewindRange: Hashable, Sendable {
    /// 読み込んだ発言の中で圧縮している
    public let compacted: Bool
    /// 最後の圧縮より前の、巻き戻せない人の発言の id
    public let readOnly: Set<String>

    public init(_ messages: [ChatMessage]) {
        let last = messages.lastIndex(where: \.isCompactBoundary)
        compacted = last != nil
        readOnly = last.map { Set(messages[..<$0].lazy.filter(\.isRewindTarget).map(\.id)) } ?? []
    }

    public func allows(_ message: ChatMessage) -> Bool { message.isRewindTarget && !readOnly.contains(message.id) }

    /// 巻き戻せる最後の発言（`/rewind`）。最後の圧縮の後に人の発言が無ければ nil
    public static func last(in messages: [ChatMessage]) -> ChatMessage? {
        for message in messages.reversed() {
            if message.isCompactBoundary { return nil }
            if message.isRewindTarget { return message }
        }
        return nil
    }
}

extension ChatMessage {
    /// 本筋の圧縮の印（サブエージェントの中の圧縮は本筋の範囲を変えない）
    public var isCompactBoundary: Bool { isCompactSummary && !isSubagent }
}

/// 会話のコードブロックの Run の手元。購読の続き（`ConversationRunUpdate`）を足し、`GET …/runs/{run}` の全部で置き換える
public struct ConversationRunStore: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String
        public var messageID: String?
        /// 始めた応答が届くまで nil（購読の出来事は code を運ばない）
        public var code: String?
        public var status: ConversationRun.Status
        public var exitCode: Int32?
        public var output: String
        public var truncated: Bool
    }

    /// 始めた順
    public private(set) var entries: [Entry] = []

    public init() {}

    /// 始めた応答。先に届いた出力と、終わった状態は残す
    public mutating func started(_ run: ConversationRun) {
        guard let i = index(run.id) else {
            entries.append(Self.entry(run))
            return
        }
        entries[i].code = run.code
        entries[i].messageID = entries[i].messageID ?? run.messageID
        if entries[i].output.isEmpty { entries[i].output = run.output }
    }

    public mutating func apply(_ update: ConversationRunUpdate) {
        guard let i = index(update.id) else {
            entries.append(
                Entry(
                    id: update.id, messageID: update.messageID, code: nil, status: update.status, exitCode: update.exitCode, output: update.chunk,
                    truncated: update.truncated))
            return
        }
        entries[i].output += update.chunk
        entries[i].status = update.status
        entries[i].exitCode = update.exitCode ?? entries[i].exitCode
        entries[i].truncated = entries[i].truncated || update.truncated
    }

    /// 全部の出力（開き直したとき）
    public mutating func replace(_ run: ConversationRun) {
        if let i = index(run.id) { entries[i] = Self.entry(run) } else { entries.append(Self.entry(run)) }
    }

    /// そのブロック（発言と本文）で最後に始めた Run
    public func latest(messageID: String?, code: String) -> Entry? {
        guard let messageID else { return nil }
        return entries.last { $0.messageID == messageID && $0.code == code }
    }

    private func index(_ id: String) -> Int? { entries.firstIndex { $0.id == id } }

    private static func entry(_ run: ConversationRun) -> Entry {
        Entry(id: run.id, messageID: run.messageID, code: run.code, status: run.status, exitCode: run.exitCode, output: run.output, truncated: run.truncated)
    }
}

/// 発言の行に出す、そこから分けたフォークの数。フォークの地点は transcript の行の uuid（`Conversation.forkAt`）で、
/// その行までで最後の、操作の帯がある発言（人の発言とアシスタントの文。サブエージェントの中は除く）に数える
public struct ChatForkAnchors: Sendable {
    /// 行の uuid → その行までで最後の帯がある発言の id
    private let anchors: [String: String]

    public init(_ messages: [ChatMessage]) {
        var anchors: [String: String] = [:]
        var last: String?
        for message in messages where message.parentToolID == nil {
            if message.kind == .text, !message.isInjected, !message.isThinking, message.isForkTarget { last = message.id }
            if let last { anchors[Self.lineID(message.id)] = last }
        }
        self.anchors = anchors
    }

    /// 発言の id → その発言から分けたフォークの数
    public func counts(_ points: [String]) -> [String: Int] {
        points.reduce(into: [:]) { counts, point in
            if let anchor = anchors[point] { counts[anchor, default: 0] += 1 }
        }
    }

    /// block の発言（`uuid#i`）の行の uuid
    static func lineID(_ messageID: String) -> String {
        messageID.firstIndex(of: "#").map { String(messageID[..<$0]) } ?? messageID
    }
}
