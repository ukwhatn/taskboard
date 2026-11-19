import Foundation

/// `GET /v1/codex`・`POST /v1/codex/connectors/refresh`。daemon が子として持つ thread の無い codex app-server から読んだ値。
/// 読めない値（古い codex に method が無い、まだ読んでいない）は nil。email・token・ログインの URL は持たない
public struct CodexMachineInfo: Codable, Hashable, Sendable {
    /// `account/read`。`kind` は codex の値のまま（apiKey・chatgpt・amazonBedrock）、nil はログインしていない
    public struct Account: Codable, Hashable, Sendable {
        public var kind: String?
        /// codex の値のまま（plus・pro・enterprise_cbp_usage_based など）
        public var planType: String?

        public init(kind: String?, planType: String?) {
            self.kind = kind
            self.planType = planType
        }
    }

    /// `model/list` の 1 件
    public struct Model: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var displayName: String
        public var isDefault: Bool
        /// 既定の一覧に出さないモデル
        public var hidden: Bool
        public var defaultEffort: String?
        public var efforts: [String]

        public init(id: String, displayName: String, isDefault: Bool, hidden: Bool, defaultEffort: String?, efforts: [String]) {
            self.id = id
            self.displayName = displayName
            self.isDefault = isDefault
            self.hidden = hidden
            self.defaultEffort = defaultEffort
            self.efforts = efforts
        }
    }

    /// `mcpServerStatus/list` の 1 件
    public struct Connector: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        /// codex の値のまま（unknown・unsupported・notLoggedIn・bearerToken・oAuth）
        public var authStatus: String?
        /// thread の無い接続では nil
        public var runtimeStatus: String?
        public var toolCount: Int
        /// ツールを読み込めなかった
        public var toolsError: Bool

        public var id: String { name }

        public init(name: String, authStatus: String?, runtimeStatus: String?, toolCount: Int, toolsError: Bool) {
            self.name = name
            self.authStatus = authStatus
            self.runtimeStatus = runtimeStatus
            self.toolCount = toolCount
            self.toolsError = toolsError
        }
    }

    /// コネクタの認証（`POST /v1/codex/connectors/login`）の様子。daemon が起き直すと消える
    public struct Login: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Hashable, Sendable {
            case waiting, succeeded, failed
        }

        public var id: String
        public var name: String
        public var state: State

        public init(id: String, name: String, state: State) {
            self.id = id
            self.name = name
            self.state = state
        }
    }

    /// 子の app-server と握手が済んでいる
    public var connected: Bool
    public var version: String?
    public var account: Account?
    public var models: [Model]?
    public var connectors: [Connector]?
    public var connectorsReadAt: Date?
    /// 待っている認証と、終わった認証のコネクタごとの最後の結果。6-2 までの daemon は nil
    public var logins: [Login]?

    public init(
        connected: Bool, version: String? = nil, account: Account? = nil, models: [Model]? = nil, connectors: [Connector]? = nil,
        connectorsReadAt: Date? = nil, logins: [Login]? = nil
    ) {
        self.connected = connected
        self.version = version
        self.account = account
        self.models = models
        self.connectors = connectors
        self.connectorsReadAt = connectorsReadAt
        self.logins = logins
    }
}

/// `POST /v1/codex/connectors/login`
public struct CodexConnectorLoginRequest: Codable, Hashable, Sendable {
    public var name: String

    public init(name: String) { self.name = name }
}

/// `POST /v1/codex/connectors/login` の応答。認証のページの URL は、頼んだ端末への応答にだけ載せる（state・ログには入れない）
public struct CodexConnectorLogin: Codable, Hashable, Sendable {
    public var loginId: String
    public var authorizationURL: String

    public init(loginId: String, authorizationURL: String) {
        self.loginId = loginId
        self.authorizationURL = authorizationURL
    }
}

/// `POST /v1/codex/connectors/login/callback`。ほかの端末で受けた戻り先のアドレスを、daemon がそのマシンの上で開く
public struct CodexConnectorCallbackRequest: Codable, Hashable, Sendable {
    public var loginId: String
    public var callbackURL: String

    public init(loginId: String, callbackURL: String) {
        self.loginId = loginId
        self.callbackURL = callbackURL
    }
}

/// `POST /v1/codex/connectors/login/cancel`。待ちを消す（それより後の戻り先のアドレスは開かない）
public struct CodexConnectorLoginCancel: Codable, Hashable, Sendable {
    public var loginId: String

    public init(loginId: String) { self.loginId = loginId }
}

/// `POST /v1/codex/connectors/logout`。応答は読み直したコネクタを含む `CodexMachineInfo`
public struct CodexConnectorLogoutRequest: Codable, Hashable, Sendable {
    public var name: String

    public init(name: String) { self.name = name }
}
