import Foundation

/// thread を持たない codex app-server を 1 本起こし、要求を 1 つ送り、終わるのを待ってから応答を返す（止まった会話の履歴とフォーク）。
/// フォークを動いている会話の app-server で作らないのは、作った側がその thread の書き手になり、新しい会話の `thread/resume` が書き手の lock で断られるため
enum CodexOneShot {
    static func call(_ launch: EngineLaunch, _ method: String, _ params: some Encodable & Sendable, timeout: Duration) async throws -> CodexRPCLine {
        // 呼ぶ側が諦めた後（起動の準備の途中で取り消された）には起こさない
        try Task.checkCancellation()
        let channel = try CodexAppServerProcess(executable: URL(fileURLWithPath: launch.executable), environment: launch.environment)
        defer { channel.terminate() }
        return try await withThrowingTaskGroup(of: CodexRPCLine.self) { group in
            group.addTask {
                var ids = CodexRequestIDs(generation: 0)
                var lines = channel.lines.makeAsyncIterator()
                func answer(_ id: CodexRequestID) async throws -> CodexRPCLine {
                    while let data = await lines.next() {
                        guard let line = CodexRPCLine(data) else { continue }
                        switch line.kind {
                        case .response(let got) where got == id: return line
                        case .failure(let got, _, let message) where got == id: throw ConversationError.failed("\(method) を断られた: \(message)")
                        default: continue
                        }
                    }
                    throw ConversationError.failed("codex app-server が \(method) に答える前に終わった")
                }
                let initialize = ids.next()
                try channel.write(
                    CodexRPC.request(
                        id: initialize, method: "initialize",
                        params: CodexProtocol.Initialize(
                            clientInfo: .init(name: "taskboard", title: "taskboard", version: Daemon.version), capabilities: .init(experimentalApi: true))))
                _ = try await answer(initialize)
                try channel.write(CodexRPC.notification(method: "initialized"))
                let request = ids.next()
                try channel.write(CodexRPC.request(id: request, method: method, params: params))
                let line = try await answer(request)
                // 終わるまで待つ。作った thread の書き手の lock は、この app-server が終わるまで残る（終わる前に resume すると断られる）
                channel.terminate()
                while await lines.next() != nil {}
                return line
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ConversationError.failed("\(method) の応答が無い")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
