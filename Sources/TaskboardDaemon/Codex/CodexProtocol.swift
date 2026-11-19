import Foundation
import TaskboardKit

/// codex app-server の params・result のうち、daemon が読み書きする分だけ（0.162.1 の `codex app-server generate-ts` の v2 の型）。
/// 知らない欄は読み飛ばし、読めない item は `CodexItem.other` にする
enum CodexProtocol {
    // MARK: 送るもの

    struct Initialize: Encodable {
        struct ClientInfo: Encodable {
            var name: String
            var title: String
            var version: String
        }
        struct Capabilities: Encodable { var experimentalApi: Bool }
        var clientInfo: ClientInfo
        var capabilities: Capabilities
    }

    struct ThreadStart: Encodable {
        var cwd: String
        var model: String?
        var approvalPolicy: String?
        var sandbox: String?
        var developerInstructions: String?
        var config: [String: MCPServer]?
        var ephemeral = false

        struct MCPServer: Encodable {
            var command: String
            var args: [String]
            var env: [String: String]
        }
    }

    struct ThreadResume: Encodable {
        var threadId: String
        var model: String?
        var approvalPolicy: String?
        var sandbox: String?
        var developerInstructions: String?
        var config: [String: ThreadStart.MCPServer]?
        var excludeTurns = true
    }

    struct TurnStart: Encodable {
        var threadId: String
        var clientUserMessageId: String
        var input: [UserInput]
        var model: String?
        var effort: String?
        var approvalPolicy: String?
        /// 権限のモードを替えた後の最初の turn だけ（ほかの turn は thread の設定のまま。設定の書き込み先の network などを上書きしない）
        var sandboxPolicy: SandboxPolicy?
        /// Plan のときだけ `plan`、ほかは `default`（experimental）。送ると model・effort は settings の値が使われる
        var collaborationMode: CollaborationMode?
    }

    /// `turn/start` の `collaborationMode`。`developer_instructions` は null（そのモードの組み込みの指示）
    struct CollaborationMode: Encodable {
        var mode: String
        var model: String
        var effort: String?

        private enum CodingKeys: String, CodingKey { case mode, settings }
        private enum SettingsKeys: String, CodingKey { case model, reasoning_effort, developer_instructions }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mode, forKey: .mode)
            var settings = c.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings)
            try settings.encode(model, forKey: .model)
            try settings.encode(effort, forKey: .reasoning_effort)
            try settings.encodeNil(forKey: .developer_instructions)
        }
    }

    struct TurnSteer: Encodable {
        var threadId: String
        var clientUserMessageId: String
        var input: [UserInput]
        var expectedTurnId: String
    }

    /// `turn/steer` を断った理由のうち、圧縮・review の turn で足せないもの（`error.data` の TurnError。turn が無い・替わったときは data が無い）
    struct NotSteerable: Decodable {
        struct Info: Decodable {
            struct Kind: Decodable { var turnKind: String }
            var activeTurnNotSteerable: Kind
        }
        var codexErrorInfo: Info
    }

    /// `thread/queue/*`（experimental）。codex の状態の DB に残る待ち行列で、thread が空くと先頭を自動で始める（中断で空いたときは始めない）
    struct QueueAdd: Encodable {
        var threadId: String
        var input: [UserInput]
        var clientUserMessageId: String
    }

    struct QueuedSubmission: Decodable {
        var id: String
        var clientUserMessageId: String
        /// 送った形（text・localImage）でないものが混じっていれば nil。steer では渡せない
        var input: [UserInput]?

        private enum CodingKeys: String, CodingKey { case id, clientUserMessageId, input }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            clientUserMessageId = try c.decode(String.self, forKey: .clientUserMessageId)
            input = try? c.decode([UserInput].self, forKey: .input)
        }
    }

    struct QueueAdded: Decodable { var queuedSubmission: QueuedSubmission }

    struct QueueList: Encodable {
        var threadId: String
        var cursor: String?
    }

    struct QueuePage: Decodable {
        var data: [QueuedSubmission]
        var nextCursor: String?
    }

    struct QueueItem: Encodable {
        var threadId: String
        var queuedSubmissionId: String
    }

    struct QueueDeleted: Decodable { var deleted: Bool }

    /// `thread/settings/update`（この後の turn と、待ち行列から始まる turn に効く）。nil の欄は送らない
    struct ThreadSettingsUpdate: Encodable {
        var threadId: String
        var model: String?
        var effort: String?
    }

    /// `turn/settings/update`（動いている turn のこの後の手順に効く。0.162.1 では feature `step_model_switching` が無いと断る）
    struct TurnSettingsUpdate: Encodable {
        var threadId: String
        var turnId: String
        var model: String?
        var effort: String?
    }

    /// `thread/start` の `sandbox`（"read-only" など）を turn の `sandboxPolicy` の形にしたもの
    struct SandboxPolicy: Encodable, Equatable {
        var mode: String

        private enum CodingKeys: String, CodingKey { case type, networkAccess, writableRoots, excludeTmpdirEnvVar, excludeSlashTmp }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch mode {
            case "read-only":
                try c.encode("readOnly", forKey: .type)
                try c.encode(false, forKey: .networkAccess)
            case "workspace-write":
                try c.encode("workspaceWrite", forKey: .type)
                try c.encode([String](), forKey: .writableRoots)
                try c.encode(false, forKey: .networkAccess)
                try c.encode(false, forKey: .excludeTmpdirEnvVar)
                try c.encode(false, forKey: .excludeSlashTmp)
            default:
                try c.encode("dangerFullAccess", forKey: .type)
            }
        }
    }

    enum UserInput: Codable, Equatable {
        case text(String)
        case localImage(path: String)

        private enum CodingKeys: String, CodingKey { case type, text, text_elements, path }

        /// 待ち行列の中身を読み直す（text の text_elements は送らないので読まない）
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "text": self = .text(try c.decode(String.self, forKey: .text))
            case "localImage": self = .localImage(path: try c.decode(String.self, forKey: .path))
            case let other: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "送らない種類 \(other)")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
                try c.encode([String](), forKey: .text_elements)
            case .localImage(let path):
                try c.encode("localImage", forKey: .type)
                try c.encode(path, forKey: .path)
            }
        }
    }

    struct ThreadTurn: Encodable {
        var threadId: String
        var turnId: String
    }

    struct ThreadOnly: Encodable { var threadId: String }

    /// `review/start`。delivery を省くと今の thread でレビューする（inline）
    struct ReviewStart: Encodable {
        enum Target: Encodable {
            case uncommittedChanges
            case custom(String)

            private enum CodingKeys: String, CodingKey { case type, instructions }

            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .uncommittedChanges: try c.encode("uncommittedChanges", forKey: .type)
                case .custom(let instructions):
                    try c.encode("custom", forKey: .type)
                    try c.encode(instructions, forKey: .instructions)
                }
            }
        }

        var threadId: String
        var target: Target
    }

    struct ThreadName: Encodable {
        var threadId: String
        var name: String
    }

    struct Decision: Encodable { var decision: String }

    /// `thread/settings/update` の作業フォルダ（experimental。codex はパスを確かめない）
    struct ThreadCwd: Encodable {
        var threadId: String
        var cwd: String
    }

    /// `thread/backgroundTerminals/list`（experimental）
    struct TerminalsList: Encodable {
        var threadId: String
        var cursor: String?
    }

    /// `thread/backgroundTerminals/terminate`（experimental）
    struct TerminalTerminate: Encodable {
        var threadId: String
        var processId: String
    }

    /// `hooks/list`・`skills/list`
    struct Cwds: Encodable { var cwds: [String] }

    /// `config/read`。`includeLayers` で層ごとの中身と版も返す
    struct ConfigRead: Encodable {
        var cwd: String
        var includeLayers: Bool?
    }

    /// `config/batchWrite`（experimental でない）。`reloadUserConfig` で読み込んである thread に読み直させる
    struct ConfigBatchWrite: Encodable {
        var edits: [JSONValue]
        var expectedVersion: String?
        var reloadUserConfig = true
    }

    /// params の無い要求（`config/mcpServer/reload`）
    struct Empty: Encodable {}

    /// `skills/config/write`
    struct SkillsConfigWrite: Encodable {
        var enabled: Bool
        var path: String
    }

    /// `config/read` で読んだ表を書き戻すための JSON（JSONSerialization の値）
    struct JSONValue: Encodable {
        var value: Any

        func encode(to encoder: any Encoder) throws {
            switch value {
            case let object as [String: Any]:
                var c = encoder.container(keyedBy: Key.self)
                for (key, item) in object { try c.encode(JSONValue(value: item), forKey: Key(key)) }
            case let array as [Any]:
                var c = encoder.unkeyedContainer()
                for item in array { try c.encode(JSONValue(value: item)) }
            default:
                var c = encoder.singleValueContainer()
                switch value {
                case let string as String: try c.encode(string)
                case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): try c.encode(number.boolValue)
                case let bool as Bool: try c.encode(bool)
                case let int as Int: try c.encode(int)
                case let number as NSNumber: try c.encode(number.doubleValue)
                case is NSNull: try c.encodeNil()
                default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "JSON でない値"))
                }
            }
        }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ string: String) { stringValue = string }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
    }

    /// `account/login/start`。localhost の callback を通らない device code の流れだけを使う
    struct LoginStart: Encodable { var type = "chatgptDeviceCode" }

    /// `account/login/cancel`
    struct LoginCancel: Encodable { var loginId: String }

    /// `account/login/completed`
    struct LoginCompleted: Decodable {
        var loginId: String?
        var success: Bool
    }

    /// `item/commandExecution/outputDelta`
    struct OutputDelta: Decodable {
        var itemId: String
        var delta: String
    }

    /// `mcpServer/elicitation/request`（MCP の `elicitation/create` と同じ形）。`requestedSchema` は形が決まらないので、行から生で読む
    struct Elicitation: Decodable {
        var threadId: String
        var serverName: String
        var mode: String?
        var message: String
        var url: String?
        var elicitationId: String?
    }

    /// MCP の問いへの答え（`content` は受けたときだけ）
    struct ElicitResult: Encodable {
        var action: String
        var content: [String: ElicitationValue]?
    }

    /// `item/tool/requestUserInput`（experimental）。選択肢が null の問いは自由記述だけ
    struct RequestUserInput: Decodable {
        struct Option: Decodable {
            var label: String
            var description: String?
        }
        struct Question: Decodable {
            var id: String
            var header: String?
            var question: String
            var isSecret: Bool?
            var options: [Option]?
        }
        var threadId: String
        var itemId: String?
        var questions: [Question]
    }

    /// 問いへの答え（問いの id → 選んだ label と自由記述）
    struct UserInputAnswers: Encodable {
        struct Answer: Encodable { var answers: [String] }
        var answers: [String: Answer]
    }

    /// `thread/items/list`。新しい順に読み、`cursor` はその前の頁の `nextCursor`
    struct ItemsList: Encodable, Sendable {
        var threadId: String
        var cursor: String?
        var limit: Int
        var sortDirection = "desc"
    }

    /// `thread/archive`（確かめで作った thread を codex の一覧から外す）
    struct ThreadArchive: Encodable, Sendable { var threadId: String }

    /// `thread/fork`。`lastTurnId` まで（含む）を写す。省くと今の末尾まで
    struct ThreadFork: Encodable, Sendable {
        var threadId: String
        var lastTurnId: String?
        var cwd: String
        var approvalPolicy: String?
        var sandbox: String?
        var excludeTurns = true
    }

    // MARK: 読むもの

    struct Thread: Decodable {
        var id: String
        var cliVersion: String?
        var name: String?
    }

    /// `thread/start`・`thread/resume` の応答
    struct ThreadOpened: Decodable {
        var thread: Thread
        var model: String?
        var reasoningEffort: String?
    }

    struct Turn: Decodable {
        var id: String
        var status: String
        var error: TurnError?
        var durationMs: Int?
    }

    struct TurnError: Decodable { var message: String? }

    struct TurnOpened: Decodable { var turn: Turn }

    struct TurnNotice: Decodable {
        var threadId: String
        var turn: Turn
    }

    struct ThreadStatusChanged: Decodable {
        struct Status: Decodable {
            var type: String
            var activeFlags: [String]?
        }
        var threadId: String
        var status: Status
    }

    struct ItemNotice: Decodable {
        var threadId: String
        var turnId: String?
        var item: CodexItem
    }

    struct Delta: Decodable {
        var threadId: String
        var itemId: String
        var delta: String
    }

    struct TokenUsageUpdated: Decodable {
        struct Breakdown: Decodable {
            var totalTokens: Int
            var inputTokens: Int
            var cachedInputTokens: Int
            var outputTokens: Int
            var reasoningOutputTokens: Int?
            var cacheWriteInputTokens: Int?
        }
        struct Usage: Decodable {
            var total: Breakdown
            var last: Breakdown
            var modelContextWindow: Int?
        }
        var threadId: String
        var tokenUsage: Usage
    }

    struct ThreadNameUpdated: Decodable {
        var threadId: String
        var threadName: String?
    }

    struct Resolved: Decodable {
        var threadId: String?
        var requestId: CodexRequestID
    }

    /// `account/usage/read{threadId}` の応答の thread の分
    struct UsageRead: Decodable {
        struct ThreadUsage: Decodable { var estimatedUsageUsdMicros: Int? }
        var threadUsage: ThreadUsage?
    }

    /// 承認の要求（コマンド・ファイル・権限）に共通の欄。`availableDecisions` は、文字列の答えだけを拾う
    struct Approval: Decodable {
        var threadId: String
        var turnId: String?
        var itemId: String?
        var command: String?
        var cwd: String?
        var reason: String?
        var availableDecisions: [String]?

        private enum CodingKeys: String, CodingKey { case threadId, turnId, itemId, command, cwd, reason, availableDecisions }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            threadId = try c.decode(String.self, forKey: .threadId)
            turnId = try c.decodeIfPresent(String.self, forKey: .turnId)
            itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
            command = try c.decodeIfPresent(String.self, forKey: .command)
            cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            availableDecisions = try c.decodeIfPresent([Loose].self, forKey: .availableDecisions)?.compactMap(\.string)
        }

        /// 文字列か、ほかの形（`{acceptWithExecpolicyAmendment: …}`）の 1 つ
        private struct Loose: Decodable {
            var string: String?
            init(from decoder: any Decoder) throws { string = try? decoder.singleValueContainer().decode(String.self) }
        }
    }

    struct ItemsPage: Decodable {
        struct Entry: Decodable {
            var turnId: String?
            var item: CodexItem
            var completedAtMs: Double?

            var completedAt: Date? { completedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) } }
        }
        var data: [Entry]
        var nextCursor: String?
    }

    /// threadId だけを読む（子の thread の通知を見分ける）
    struct AnyThread: Decodable { var threadId: String? }
}
