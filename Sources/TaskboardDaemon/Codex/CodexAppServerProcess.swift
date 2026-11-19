import Darwin
import Foundation

/// `codex app-server`（stdio）の子。stdin を閉じると子は自分で終わる（0.162.1 の実測）ので、止めるときは先に閉じてから SIGTERM を送り、それでも残れば SIGKILL を送る
final class CodexAppServerProcess: CodexChannel, @unchecked Sendable {
    let lines: AsyncStream<Data>
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()

    /// stderr は捨てる（ログイン・コネクタの URL を書くことがあり、ログに写さない）
    init(executable: URL, environment: [String: String]) throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // daemon は SIGPIPE を無視していないので、終わった子に書いても daemon が落ちないようにする
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (lines, continuation) = AsyncStream<Data>.makeStream()
        self.lines = lines
        let buffer = LineBuffer()
        let reading = stdout.fileHandleForReading
        reading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            for line in buffer.append(data) where !line.isEmpty { continuation.yield(line) }
        }
        process.terminationHandler = { _ in
            // EOF が届かないときの保険。残りを読み切る間を置いてから終える
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) {
                reading.readabilityHandler = nil
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            reading.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    func write(_ data: Data) throws {
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        try? stdin.fileHandleForWriting.close()
        let process = process
        let grace = DispatchTimeInterval.seconds(Int(Subprocess.killGrace))
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM に応えない子を残さない
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// 改行区切り。readabilityHandler は任意の境界で呼ばれるので、行の途中を持ち越す
    private final class LineBuffer: @unchecked Sendable {
        private var pending = Data()
        private let lock = NSLock()

        func append(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(data)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                lines.append(Data(pending[pending.startIndex..<newline]))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }

    /// ログインシェルの環境と、その PATH にある codex で子を起こす（launchd の daemon の PATH には codex が無い）
    static func launcher(shell: String = LoginShell.path ?? "/bin/zsh") -> CodexMachine.Launch {
        {
            let install = try await CodexInstall.resolve(shell: shell)
            return try CodexAppServerProcess(executable: install.executable, environment: install.environment)
        }
    }

    static func executable(path: String, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        path.split(separator: ":").map { "\($0)/codex" }.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

/// ログインシェルの環境と、その PATH にある codex。app-server を起こすときも、`codex mcp logout` を走らせるときも、同じ引き方で決める
struct CodexInstall: Sendable {
    var executable: URL
    var environment: [String: String]

    static func resolve(shell: String = LoginShell.path ?? "/bin/zsh") async throws -> CodexInstall {
        let environment = await LoginShellEnvironment.capture(shell: shell) ?? ClaudeCheck.fallbackEnvironment()
        guard let executable = CodexAppServerProcess.executable(path: environment["PATH"] ?? "") else { throw CodexLaunchError.notFound }
        return CodexInstall(executable: executable, environment: environment)
    }
}

enum CodexLaunchError: Error, CustomStringConvertible {
    case notFound

    var description: String { "codex がログインシェルの PATH に無い" }
}

/// コネクタの認証の戻り先のアドレスを、このマシンの上で GET する。redirect は追わない（応答の中身と状態は見ない。結果は codex の完了の知らせで分かる）
enum CodexCallbackOpener {
    static func open(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await session.data(from: url)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
