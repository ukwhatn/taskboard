import Foundation

/// codex app-server の要求の id。こちらは文字列（`CodexRequestIDs`）、server は 0 からの数を振る（0.162.1 の実測）
enum CodexRequestID: Hashable, Sendable, Codable {
    case number(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let number): try c.encode(number)
        case .string(let string): try c.encode(string)
        }
    }
}

/// こちらが振る要求の id。`<世代>-<連番>` の文字列で、世代は子を起こすたびに変える。
/// daemon が控えを読み直すとき、前の世代の要求への応答を見分けて捨てる
struct CodexRequestIDs: Sendable {
    let generation: Int
    private var counter = 0

    init(generation: Int) { self.generation = generation }

    mutating func next() -> CodexRequestID {
        counter += 1
        return .string("\(generation)-\(counter)")
    }

    static func generation(of id: CodexRequestID) -> Int? {
        guard case .string(let text) = id else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        return Int(parts[0])
    }
}

/// codex app-server の stdio の 1 行（JSON-RPC から `jsonrpc` の欄を抜いた形。1 行 1 JSON）。
/// 外枠（id・method・error）だけを読み、`params`・`result` は method ごとの型で読み直す
struct CodexRPCLine: Sendable {
    enum Kind: Equatable, Sendable {
        /// こちらの要求への応答
        case response(id: CodexRequestID)
        /// こちらの要求が断られた
        case failure(id: CodexRequestID, code: Int, message: String)
        /// server からの要求（承認・問いなど）。答えを返すまで server は待つ
        case request(id: CodexRequestID, method: String)
        case notification(method: String)
    }

    let kind: Kind
    let data: Data

    /// JSON の object でない行と、id も method も無い行は nil
    init?(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch (envelope.id, envelope.method, envelope.error) {
        case (let id?, let method?, _): kind = .request(id: id, method: method)
        case (nil, let method?, _): kind = .notification(method: method)
        case (let id?, nil, let error?): kind = .failure(id: id, code: error.code, message: error.message)
        case (let id?, nil, nil) where envelope.hasResult: kind = .response(id: id)
        default: return nil
        }
        self.data = data
    }

    func params<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(ParamsBox<T>.self, from: data).params
    }

    func result<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(ResultBox<T>.self, from: data).result
    }

    /// 断りの `error.data`
    func errorData<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(ErrorBox<T>.self, from: data).error.data
    }

    private struct Envelope: Decodable {
        struct RPCError: Decodable {
            var code: Int
            var message: String
        }
        var id: CodexRequestID?
        var method: String?
        var error: RPCError?
        var hasResult: Bool

        enum CodingKeys: String, CodingKey { case id, method, error, result }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(CodexRequestID.self, forKey: .id)
            method = try c.decodeIfPresent(String.self, forKey: .method)
            error = try c.decodeIfPresent(RPCError.self, forKey: .error)
            hasResult = c.contains(.result)
        }
    }

    private struct ParamsBox<T: Decodable>: Decodable { var params: T }
    private struct ResultBox<T: Decodable>: Decodable { var result: T }
    private struct ErrorBox<T: Decodable>: Decodable {
        struct Body: Decodable { var data: T }
        var error: Body
    }
}

/// app-server に書く 1 行（末尾の改行つき）
enum CodexRPC {
    static func request(id: CodexRequestID, method: String, params: some Encodable) throws -> Data {
        try line(Request(id: id, method: method, params: params))
    }

    static func notification(method: String) -> Data {
        Data(#"{"method":"\#(method)"}"#.utf8) + Data([UInt8(ascii: "\n")])
    }

    /// server の要求への答え
    static func reply(to id: CodexRequestID, result: some Encodable) throws -> Data {
        try line(Reply(id: id, result: result))
    }

    /// server の要求を断る（この daemon が答えられない種類）
    static func refuse(_ id: CodexRequestID, code: Int, message: String) throws -> Data {
        struct Failure: Encodable {
            struct Body: Encodable {
                var code: Int
                var message: String
            }
            var id: CodexRequestID
            var error: Body
        }
        return try line(Failure(id: id, error: .init(code: code, message: message)))
    }

    /// JSON-RPC の「method が無い」
    static let methodNotFound = -32601

    private struct Request<P: Encodable>: Encodable {
        var id: CodexRequestID
        var method: String
        var params: P
    }

    private struct Reply<R: Encodable>: Encodable {
        var id: CodexRequestID
        var result: R
    }

    private static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value) + Data([UInt8(ascii: "\n")])
    }
}
