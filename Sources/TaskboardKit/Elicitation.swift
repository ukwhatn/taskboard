import Foundation

/// MCP の server が人に聞く問い（MCP の elicitation）。engine に依らない形で、Claude の `elicitation` も codex の `mcpServer/elicitation/request` もこれに写す。
/// form は MCP の仕様の範囲（平らな object の、文字・数・整数・真偽・文字の選択）だけを入力欄にし、それ以外は `unsupported` にする（断る・取り消すだけを受ける）
public struct Elicitation: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case form
        /// 外のページを開かせる（MCP の server の認証など）
        case url
        /// この版が知らない形（codex の `openai/form` など）。断る・取り消すだけを受ける
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Mode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var serverName: String
    public var message: String
    /// MCP の server が付けた見出し（Claude の `_meta['anthropic/permissionDisplay']` の title）
    public var title: String?
    public var mode: Mode
    /// mode が form のとき
    public var form: Form?
    /// mode が url のとき、開く先の scheme・host・port。URL の全文は state・DB・ログに載せず、会話の actor だけが持ち、
    /// ［開く］の要求（`ConversationControlRequest.Kind.elicitationURL`）の応答で渡す。nil なら開けない（`OAuthLinks.openable` を通らない、
    /// daemon が起き直して全文を失った）ので、断る・取り消すだけを受ける
    public var link: Link?
    /// url の問いと、server が送る完了の知らせを結ぶ id
    public var elicitationID: String?

    public init(
        serverName: String, message: String, title: String? = nil, mode: Mode, form: Form? = nil, link: Link? = nil, elicitationID: String? = nil
    ) {
        self.serverName = serverName
        self.message = message
        self.title = title
        self.mode = mode
        self.form = form
        self.link = link
        self.elicitationID = elicitationID
    }

    /// 開く前に出す、開く先
    public struct Link: Codable, Hashable, Sendable {
        public var scheme: String
        public var host: String
        public var port: Int?

        public init(scheme: String, host: String, port: Int? = nil) {
            self.scheme = scheme
            self.host = host
            self.port = port
        }

        /// `OAuthLinks.openable` を通った URL の開く先
        public init?(openable url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme, let host = components.host else {
                return nil
            }
            self.init(scheme: scheme.lowercased(), host: host.lowercased(), port: components.port)
        }

        /// 「https://auth.example.com:8443」の形
        public var origin: String { "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "") }
    }

    /// 受ける答え。form の入力欄と開ける url の問いは 3 つとも、それ以外は断る・取り消すだけ
    public var allowedActions: [ElicitationAction] {
        switch mode {
        case .form where form?.unsupported == false: [.accept, .decline, .cancel]
        case .url where link != nil: [.accept, .decline, .cancel]
        default: [.decline, .cancel]
        }
    }

    /// 答えを確かめる。アプリは送る前に、daemon は engine に渡す前に同じものを呼ぶ。`content` は form を受けるときだけ持つ
    public func check(_ action: ElicitationAction, content: [String: ElicitationValue]?) throws(ElicitationAnswerError) {
        guard allowedActions.contains(action) else { throw .actionNotAllowed }
        guard action == .accept, mode == .form, let form else {
            if content != nil { throw .contentNotAllowed }
            return
        }
        try form.check(content ?? [:])
    }
}

/// ［開く］の応答（`elicitation_url` の control）。要求した端末にだけ返す
public struct ElicitationURLResponse: Codable, Hashable, Sendable {
    public var url: String

    public init(url: String) {
        self.url = url
    }
}

public enum ElicitationAction: String, Codable, Sendable, CaseIterable {
    /// 入力して送る（url は開いたことを知らせる）
    case accept
    /// 断る
    case decline
    /// 答えずに閉じる
    case cancel
}

/// form の答えの値。MCP の form の答えは文字・数・真偽だけ
public enum ElicitationValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// 答えを受けない理由。欄の答えなら欄の名前（schema の property の名前）を持つ
public enum ElicitationAnswerError: Error, Hashable, Sendable {
    /// この問いでは使えない答え（入力欄にできない form や開けない url を受ける）
    case actionNotAllowed
    /// 受ける以外の答えか、form でない問いに入力を付けた
    case contentNotAllowed
    case missing(String)
    case unknownField(String)
    case wrongType(String)
    /// 文字の長さ（`ElicitationLimits.textBytes` を含む）か、数の範囲の外
    case outOfRange(String)
    case badFormat(String)
    case notAnOption(String)
}

public enum ElicitationLimits {
    public static let fields = 20
    public static let options = 100
    /// 答えの文字 1 つの上限（UTF-8 のバイト数）
    public static let textBytes = 10 * 1024
    public static let schemaBytes = 64 * 1024
}

extension Elicitation {
    public struct Form: Codable, Hashable, Sendable {
        /// schema の並び順
        public var fields: [Field]
        /// MCP の仕様の範囲の外か、上限を超えた。入力欄にせず、断る・取り消すだけを受ける
        public var unsupported: Bool

        public init(fields: [Field], unsupported: Bool = false) {
            self.fields = fields
            self.unsupported = unsupported
        }

        public static let unsupportedForm = Form(fields: [], unsupported: true)

        /// `requestedSchema` の JSON から作る。範囲の外は `unsupportedForm`
        public init(schema data: Data) {
            guard data.count <= ElicitationLimits.schemaBytes,
                let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
                let fields = Self.fields(object, order: JSONKeyOrder.propertyKeys(data))
            else {
                self = .unsupportedForm
                return
            }
            self.init(fields: fields)
        }

        /// 範囲の内か。上の段の鍵は type・properties・required と注記だけを受ける
        private static func fields(_ schema: [String: Any], order: [String]) -> [Field]? {
            let known: Set = ["type", "properties", "required", "$schema", "title", "description"]
            guard schema["type"] as? String == "object", Set(schema.keys).isSubset(of: known),
                let properties = schema["properties"] as? [String: Any], properties.count <= ElicitationLimits.fields
            else { return nil }
            let required = schema["required"].map { $0 as? [String] } ?? []
            guard let required, Set(required).isSubset(of: properties.keys) else { return nil }
            // JSONSerialization は鍵の順を残さないので、並びは JSON の文の順から取る
            let keys = order.count == properties.count && Set(order) == Set(properties.keys) ? order : properties.keys.sorted()
            var fields: [Field] = []
            for key in keys {
                guard let property = properties[key] as? [String: Any], let field = Field(key: key, schema: property, required: required.contains(key))
                else { return nil }
                fields.append(field)
            }
            return fields
        }

        func check(_ content: [String: ElicitationValue]) throws(ElicitationAnswerError) {
            for key in content.keys.sorted() where !fields.contains(where: { $0.key == key }) { throw .unknownField(key) }
            for field in fields {
                guard let value = content[field.key] else {
                    if field.required { throw .missing(field.key) }
                    continue
                }
                try field.check(value)
            }
        }
    }

    /// form の入力欄 1 つ。MCP の `PrimitiveSchemaDefinition` の範囲だけを持つ
    public struct Field: Codable, Hashable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case text
            case number
            case integer
            case boolean
            /// 文字の中から 1 つ選ぶ（`enum` か `oneOf` の const と title）
            case choice
            case unknown

            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public enum Format: String, Codable, Sendable {
            case email
            case uri
            case date
            case dateTime = "date-time"
            case unknown

            public init(from decoder: any Decoder) throws {
                self = Format(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public struct Option: Codable, Hashable, Sendable {
            public var value: String
            /// 出す名前。無ければ `value`
            public var title: String?

            public init(value: String, title: String? = nil) {
                self.value = value
                self.title = title
            }
        }

        public var id: String { key }
        /// schema の property の名前（答えの鍵）
        public var key: String
        public var kind: Kind
        public var title: String?
        public var description: String?
        public var required: Bool
        public var format: Format?
        public var minLength: Int?
        public var maxLength: Int?
        public var minimum: Double?
        public var maximum: Double?
        public var options: [Option]?
        public var defaultValue: ElicitationValue?

        public init(
            key: String, kind: Kind, title: String? = nil, description: String? = nil, required: Bool = false, format: Format? = nil,
            minLength: Int? = nil, maxLength: Int? = nil, minimum: Double? = nil, maximum: Double? = nil, options: [Option]? = nil,
            defaultValue: ElicitationValue? = nil
        ) {
            self.key = key
            self.kind = kind
            self.title = title
            self.description = description
            self.required = required
            self.format = format
            self.minLength = minLength
            self.maxLength = maxLength
            self.minimum = minimum
            self.maximum = maximum
            self.options = options
            self.defaultValue = defaultValue
        }

        /// 範囲の外（知らない鍵・型・format、文字でない選択肢、多く選ぶ選択）なら nil
        init?(key: String, schema: [String: Any], required: Bool) {
            let common: Set = ["type", "title", "description", "default"]
            guard let type = schema["type"] as? String else { return nil }
            guard let title = Self.optional(schema["title"], { $0 as? String }),
                let description = Self.optional(schema["description"], { $0 as? String })
            else { return nil }
            let keys = Set(schema.keys)
            switch type {
            case "string" where schema["enum"] != nil || schema["oneOf"] != nil:
                guard keys.isSubset(of: common.union(["enum", "enumNames", "oneOf"])), let options = Self.options(schema),
                    !options.isEmpty, options.count <= ElicitationLimits.options,
                    let defaultValue = Self.optional(schema["default"], { $0 as? String }),
                    defaultValue.map({ value in options.contains { $0.value == value } }) ?? true
                else { return nil }
                self.init(
                    key: key, kind: .choice, title: title, description: description, required: required, options: options,
                    defaultValue: defaultValue.map(ElicitationValue.string))
            case "string":
                guard keys.isSubset(of: common.union(["minLength", "maxLength", "format"])),
                    let format = Self.optional(schema["format"], { ($0 as? String).flatMap(Format.init(rawValue:)) }), format != .unknown,
                    let minLength = Self.optional(schema["minLength"], Self.count), let maxLength = Self.optional(schema["maxLength"], Self.count),
                    let defaultValue = Self.optional(schema["default"], { $0 as? String })
                else { return nil }
                self.init(
                    key: key, kind: .text, title: title, description: description, required: required, format: format, minLength: minLength,
                    maxLength: maxLength, defaultValue: defaultValue.map(ElicitationValue.string))
            case "number", "integer":
                guard keys.isSubset(of: common.union(["minimum", "maximum"])), let minimum = Self.optional(schema["minimum"], Self.number),
                    let maximum = Self.optional(schema["maximum"], Self.number), let defaultValue = Self.optional(schema["default"], Self.number)
                else { return nil }
                self.init(
                    key: key, kind: type == "integer" ? .integer : .number, title: title, description: description, required: required,
                    minimum: minimum, maximum: maximum, defaultValue: defaultValue.map(ElicitationValue.number))
            case "boolean":
                guard keys.isSubset(of: common), let defaultValue = Self.optional(schema["default"], Self.bool) else { return nil }
                self.init(
                    key: key, kind: .boolean, title: title, description: description, required: required,
                    defaultValue: defaultValue.map(ElicitationValue.bool))
            default:
                return nil
            }
        }

        /// 省ける鍵を読む。鍵が無ければ `.some(nil)`、読めれば `.some(値)`、型が違えば nil（範囲の外）
        private static func optional<T>(_ value: Any?, _ read: (Any) -> T?) -> T?? {
            guard let value else { return .some(nil) }
            return read(value).map { .some($0) }
        }

        /// `enum`（`enumNames` があれば名前）か、`oneOf` の `{const, title}`。どちらか一方だけ
        private static func options(_ schema: [String: Any]) -> [Option]? {
            switch (schema["enum"], schema["oneOf"]) {
            case (let values?, nil):
                guard let values = values as? [String] else { return nil }
                guard let names = optional(schema["enumNames"], { $0 as? [String] }) else { return nil }
                guard let names else { return values.map { Option(value: $0) } }
                guard names.count == values.count else { return nil }
                return zip(values, names).map { Option(value: $0, title: $1) }
            case (nil, let items?):
                guard schema["enumNames"] == nil, let items = items as? [[String: Any]] else { return nil }
                var options: [Option] = []
                for item in items {
                    guard Set(item.keys).isSubset(of: ["const", "title"]), let value = item["const"] as? String else { return nil }
                    guard let title = optional(item["title"], { $0 as? String }) else { return nil }
                    options.append(Option(value: value, title: title))
                }
                return options
            default:
                return nil
            }
        }

        // JSONSerialization は真偽を NSNumber で返すので、数と真偽を CFBoolean で見分ける
        private static func isBool(_ value: Any) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        private static func number(_ value: Any) -> Double? {
            guard !isBool(value), let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }

        private static func count(_ value: Any) -> Int? {
            guard let number = number(value), number >= 0, number == number.rounded(), number <= Double(Int32.max) else { return nil }
            return Int(number)
        }

        private static func bool(_ value: Any) -> Bool? {
            guard isBool(value), let number = value as? NSNumber else { return nil }
            return number.boolValue
        }

        func check(_ value: ElicitationValue) throws(ElicitationAnswerError) {
            switch (kind, value) {
            case (.text, .string(let text)):
                let length = text.unicodeScalars.count
                guard text.utf8.count <= ElicitationLimits.textBytes, length >= (minLength ?? 0), length <= (maxLength ?? .max) else {
                    throw .outOfRange(key)
                }
                if let format, !Self.matches(text, format) { throw .badFormat(key) }
            case (.choice, .string(let text)):
                guard options?.contains(where: { $0.value == text }) == true else { throw .notAnOption(key) }
            case (.number, .number(let number)), (.integer, .number(let number)):
                guard number.isFinite, kind == .number || number == number.rounded() else { throw .wrongType(key) }
                guard number >= (minimum ?? -.infinity), number <= (maximum ?? .infinity) else { throw .outOfRange(key) }
            case (.boolean, .bool):
                break
            default:
                throw .wrongType(key)
            }
        }

        static func matches(_ text: String, _ format: Format) -> Bool {
            switch format {
            case .email:
                let parts = text.split(separator: "@", omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(where: \.isWhitespace)
                    && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
            case .uri:
                guard let components = URLComponents(string: text), let scheme = components.scheme else { return false }
                return !scheme.isEmpty
            case .date:
                // 暦に無い日（2 月 30 日など）は読み直すと別の日になる
                guard let date = try? Date.ISO8601FormatStyle().year().month().day().parse(text) else { return false }
                return Date.ISO8601FormatStyle().year().month().day().format(date) == text
            case .dateTime:
                return (try? Date.ISO8601FormatStyle().parse(text)) != nil || (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) != nil
            case .unknown:
                return false
            }
        }
    }
}
