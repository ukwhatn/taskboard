import Foundation

/// Claude の権限の確認で、CLI が出した「今後は聞かない」候補（`can_use_tool` の `permission_suggestions` の 1 件）。
/// 選ぶと許可に添えて CLI に返す。返す中身は daemon が持ち、答えは `id` で指す
public struct PermissionSuggestion: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// 許可の規則を足す（`subject` は `Bash(npm test:*)` のような規則）
        case rule
        /// 作業フォルダを足す（`subject` はパス）
        case directory
        /// 権限のモードを替える（`subject` はモードの名前）
        case mode
        /// この版が知らない種類。画面に出さず、答えに使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    /// どこに残すか
    public enum Scope: String, Codable, Sendable {
        /// この会話の間だけ
        case session
        /// このフォルダの `.claude/settings.local.json`（個人用で、リポジトリには入らない）
        case folder
        /// このプロジェクトの `.claude/settings.json`（リポジトリで共有する）
        case project
        /// このユーザーの全部のプロジェクト
        case user
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Scope(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// 画面・通知・MCP の応答で、残す先を言う句
        public var phrase: String {
            switch self {
            case .session, .unknown: String(localized: "この会話の間")
            case .folder: String(localized: "このフォルダの設定に保存")
            case .project: String(localized: "プロジェクトの設定に保存")
            case .user: String(localized: "すべてのプロジェクトで")
            }
        }
    }

    /// 答えで指す id。CLI の候補の並びの番号
    public var id: String
    public var kind: Kind
    public var subject: String
    public var scope: Scope

    public init(id: String, kind: Kind, subject: String, scope: Scope) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.scope = scope
    }

    /// 画面と通知に出せる候補。この版が知らない種類と残す先は外す（どこに残るか言えない候補を選ばせない）
    public static func shown(_ suggestions: [PermissionSuggestion]?) -> [PermissionSuggestion] {
        (suggestions ?? []).filter { $0.kind != .unknown && $0.scope != .unknown }
    }
}

extension ConversationRequest {
    /// 通知の［常に許可］で選ぶ候補。ロック画面では何を許可するか読めないので、許可の規則に限る（フォルダの追加とモードの変更は出さない）
    public var alwaysSuggestion: PermissionSuggestion? {
        PermissionSuggestion.shown(suggestions).first { $0.kind == .rule }
    }
}
