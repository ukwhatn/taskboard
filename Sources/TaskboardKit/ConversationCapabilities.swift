import Foundation

/// 制御（`ConversationControlRequest.Kind`）でない会話の操作
public enum ConversationOperation: String, CaseIterable, Sendable {
    case fork
    case rewind
    case attachImages
    /// 生成中に送る発言を、今のターンが終わってから始める（`ConversationSendRequest.later`）。codex は生成中の発言をもともとターンの後に回す
    case sendLater
}

/// engine ごとに使える会話の操作。daemon は無い操作を `engine_unsupported` で断り、アプリは無い操作を出さない
extension Conversation.Engine {
    public func supports(_ kind: ConversationControlRequest.Kind) -> Bool {
        switch self {
        case .claude: kind != .compact && kind != .newThread && kind != .review
        case .codex:
            switch kind {
            case .compact, .newThread, .review: true
            case .interrupt, .setModel, .setEffort, .setNotifyParent, .setPermissionMode, .rename, .cancelLimitResume, .contextUsage, .contextBreakdown, .sendNow, .cancelQueued, .elicitationURL: true
            case .exportConversation, .listBackgroundTasks, .taskOutput, .stopTask, .permissionRules, .hooks, .memory, .skills, .setCwd, .login, .editSettings, .plugins: true
            case .mcpStatus, .mcpReconnect, .mcpToggle, .mcpAuthenticate, .mcpOAuthCallback, .mcpClearAuth: true
            case .usage, .deferQuestions: false
            // codex に脇の質問と作業フォルダの追加は無い。ログインは device code で、ページにコードを打ち込む（貼り返すコードは無い）
            case .sideQuestion, .addDirectory, .loginCode, .sandbox: false
            }
        case .unknown: false
        }
    }

    /// 生成中に送った発言を待ち行列に入れ、区切りで渡すか（Claude は CLI の、codex は app-server の `thread/queue/*` の待ち行列）
    public var queuesMessages: Bool { self == .claude || self == .codex }

    /// `/` の候補と画面に出す taskboard の操作
    public func supports(action: ConversationTaskboardAction) -> Bool {
        typealias Kind = ConversationControlRequest.Kind
        guard self != .unknown else { return false }
        switch action {
        case .fork: return supports(ConversationOperation.fork)
        case .rewind: return supports(ConversationOperation.rewind)
        case .shell, .diff, .status, .cost, .usage: return true
        case .export: return supports(Kind.exportConversation)
        case .tasks: return supports(Kind.listBackgroundTasks)
        case .permissions: return supports(Kind.permissionRules)
        case .hooks: return supports(Kind.hooks)
        case .memory: return supports(Kind.memory)
        case .skills: return supports(Kind.skills)
        case .btw: return supports(Kind.sideQuestion)
        case .addDir: return supports(Kind.addDirectory)
        case .cd: return supports(Kind.setCwd)
        case .login: return supports(Kind.login)
        case .plugin: return supports(Kind.plugins)
        case .compact: return supports(Kind.compact)
        case .new: return supports(Kind.newThread)
        case .review: return supports(Kind.review)
        case .rename: return self == .codex
        case .exit: return true
        }
    }

    public func supports(_ operation: ConversationOperation) -> Bool {
        switch self {
        case .claude: true
        case .codex:
            switch operation {
            case .attachImages, .fork: true
            case .rewind, .sendLater: false
            }
        case .unknown: false
        }
    }
}

extension Conversation.Engine {
    /// 入力欄の下の欄（`/model`・`/mcp` などで開くものを含む）
    public func supports(field: ConversationControlField) -> Bool {
        switch field {
        case .model: supports(ConversationControlRequest.Kind.setModel)
        case .effort: supports(ConversationControlRequest.Kind.setEffort)
        case .mcp: supports(ConversationControlRequest.Kind.mcpStatus)
        case .context: supports(ConversationControlRequest.Kind.contextBreakdown)
        }
    }

    /// CLI が `/` のコマンドの一覧を返し、`/` で始まる文を CLI が解釈するか。
    /// Codex は返さないので、アプリの知っている `/` はすべてアプリが受け、CLI に送らない
    public var hasCLICommands: Bool { self == .claude }

    /// `/` の行の操作を、この engine で動く形にする。無い taskboard の操作と、無い欄・`unavailable` の欄は nil。CLI のコマンドはそのまま
    public func slashAction(_ action: ConversationSlashItem.Action, unavailable: Set<ConversationControlField> = []) -> ConversationSlashItem.Action? {
        switch action {
        case .send: return action
        case .taskboard(let taskboard): return supports(action: taskboard) ? action : nil
        case .control(let field):
            return supports(field: field) && !unavailable.contains(field) ? action : nil
        }
    }
}
