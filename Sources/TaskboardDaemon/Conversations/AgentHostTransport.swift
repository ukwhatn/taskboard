import Foundation

/// 会話が agent host に送る要求の口。本物は `AgentHostClient`、テストは偽物の host に替える
protocol AgentHostTransport: Sendable {
    func call(
        _ op: AgentHostRequest.Op, key: String?, argv: [String]?, env: [String: String]?, cwd: String?, data: String?, signal: String?, after: Int?,
        through: Int?, cols: Int?, rows: Int?
    ) async throws -> AgentHostReply
}

extension AgentHostClient: AgentHostTransport {}

extension AgentHostTransport {
    func spawn(key: String, argv: [String], env: [String: String], cwd: String) async throws -> AgentHostReply {
        try await call(.spawn, key: key, argv: argv, env: env, cwd: cwd, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
    }

    func write(key: String, _ data: Data) async throws {
        _ = try await call(.write, key: key, argv: nil, env: nil, cwd: nil, data: String(decoding: data, as: UTF8.self), signal: nil, after: nil, through: nil, cols: nil, rows: nil)
    }

    func closeInput(key: String) async throws {
        _ = try await call(.closeInput, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil)
    }

    func signal(key: String, _ name: String) async throws {
        _ = try await call(.signal, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: name, after: nil, through: nil, cols: nil, rows: nil)
    }

    func subscribe(key: String, after: Int) async throws {
        _ = try await call(.subscribe, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: after, through: nil, cols: nil, rows: nil)
    }

    func trim(key: String, through: Int) async throws {
        _ = try await call(.trim, key: key, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: through, cols: nil, rows: nil)
    }

    func list() async throws -> [AgentHostProcessInfo] {
        try await call(.list, key: nil, argv: nil, env: nil, cwd: nil, data: nil, signal: nil, after: nil, through: nil, cols: nil, rows: nil).processes ?? []
    }
}

/// 会話を起こすときの CLI と環境（確かめた版の実行ファイルと、ログインシェルから取った環境）
struct EngineLaunch: Sendable, Equatable {
    var executable: String
    var environment: [String: String]
}
