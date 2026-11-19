import Foundation

/// そのマシンの Claude Code で選べるモデル（`GET /v1/claude`）。daemon が CLI の initialize の答えの `models` から覚えた値
public struct ClaudeMachineInfo: Codable, Hashable, Sendable {
    /// initialize の `models` の 1 件（`default` は daemon が落とす。`--model` を渡さないのと同じなので）
    public struct Model: Codable, Hashable, Sendable, Identifiable {
        /// CLI の名前（別名の `opus`、版つきの `claude-opus-4-8`）
        public var value: String
        /// CLI が解決した名前（`claude-opus-5-5[1m]`）
        public var resolvedModel: String
        public var displayName: String
        public var description: String?
        /// 選べる effort の段階。nil は effort を選べないモデル
        public var efforts: [String]?

        public var id: String { value }

        public init(value: String, resolvedModel: String, displayName: String, description: String? = nil, efforts: [String]?) {
            self.value = value
            self.resolvedModel = resolvedModel
            self.displayName = displayName
            self.description = description
            self.efforts = efforts
        }
    }

    /// nil は、まだ CLI から受けていない
    public var models: [Model]?
    /// 一覧を受けた CLI の版
    public var version: String?
    public var readAt: Date?

    public init(models: [Model]?, version: String? = nil, readAt: Date? = nil) {
        self.models = models
        self.version = version
        self.readAt = readAt
    }
}

/// モデルの名前の引き方（daemon・MCP・アプリが同じものを使う）。マシンの一覧が無ければ控えの一覧で引く
public struct ClaudeModels: Hashable, Sendable {
    public typealias Model = ClaudeMachineInfo.Model

    public let models: [Model]

    public init(_ info: ClaudeMachineInfo?) {
        if let listed = info?.models, !listed.isEmpty {
            models = listed
        } else {
            models = Self.fallback
        }
    }

    /// 一覧を返さない daemon と、まだ CLI から一覧を受けていない daemon の分。この版より前の daemon が受け付けた名前と同じにする
    public static let fallback: [Model] = {
        let all = Effort.allCases.map(\.rawValue)
        return [
            Model(value: "opus", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus 5.5", efforts: all),
            Model(value: "sonnet", resolvedModel: "claude-sonnet-5", displayName: "Sonnet 5", efforts: all),
            Model(value: "fable", resolvedModel: "claude-fable-5-1", displayName: "Fable 5.1", efforts: all),
            Model(value: "haiku", resolvedModel: "claude-haiku-5-5", displayName: "Haiku 5.5", efforts: all),
            Model(value: "claude-sonnet-5-5", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5", efforts: all),
        ]
    }()

    /// 1M context の版で起こすモデル。CLI の別名がこの 2 つには `[1m]` を付けないので、taskboard が付ける（ほかは CLI の解決した名前のまま）
    static let oneMillion: Set<String> = ["claude-opus-5-5", "claude-fable-5-1"]

    /// 別名（`opus` など。CLI の版が上がると指す先が新しいモデルに替わる）
    public var primary: [Model] { models.filter { !Self.isVersioned($0) } }
    /// 版つきの名前（`claude-opus-4-8` など）
    public var others: [Model] { models.filter(Self.isVersioned) }

    /// 別名・版つきの名前・解決した名前（`[1m]` の有無を問わない）から引く
    public func model(named name: String) -> Model? {
        if let exact = models.first(where: { $0.value == name }) { return exact }
        let base = Self.base(name)
        return models.first { Self.base($0.resolvedModel) == base }
    }

    /// `--model` に渡す値。一覧に無い名前は nil
    public func argument(for name: String) -> String? {
        model(named: name).map(Self.argument)
    }

    public static func argument(_ model: Model) -> String {
        let base = base(model.resolvedModel)
        return oneMillion.contains(base) ? base + "[1m]" : model.resolvedModel
    }

    /// 画面と MCP の応答に出す名前。一覧に無い名前はそのまま
    public func label(_ name: String) -> String {
        model(named: name)?.displayName ?? name
    }

    /// 選べる effort。nil（既定のモデル）と一覧に無いモデルは全部、effort を選べないモデルは空。`Effort` に無い段階は落とす
    public func efforts(for name: String?) -> [Effort] {
        guard let name, let model = model(named: name) else { return Effort.allCases }
        guard let efforts = model.efforts else { return [] }
        return Effort.allCases.filter { efforts.contains($0.rawValue) }
    }

    /// 断りの文に並べる名前
    public var names: [String] { models.map(\.value) }

    private static func isVersioned(_ model: Model) -> Bool { model.value.hasPrefix("claude-") }

    private static func base(_ name: String) -> String {
        name.hasSuffix("[1m]") ? String(name.dropLast(4)) : name
    }
}
