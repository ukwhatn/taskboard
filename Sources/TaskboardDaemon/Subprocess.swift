import Foundation

/// ユーザーのログインシェル（ディレクトリサービスの UserShell）。会話のシェルと、会話の環境を引くときに使う
public enum LoginShell {
    public static let path: String? = {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }()

    static var environment: [String: String]? { path.map { ["SHELL": $0] } }
}

enum SubprocessError: Error, CustomStringConvertible {
    /// 0 以外で終わった（コマンド, stderr）
    case commandFailed(String, String)

    var description: String {
        switch self {
        case .commandFailed(let command, let stderr): "\(command) failed: \(stderr)"
        }
    }
}

/// 短命な子プロセス。失敗は stderr を添えて `SubprocessError.commandFailed`。
///
/// 子の終了を `terminationHandler` で受け、終了から `drainGrace` 待っても閉じないパイプは読むのをやめる。
/// `waitUntilExit` + `readDataToEndOfFile` は、子が残した孫（gh の credential helper など）がパイプを握ると timeout の後も戻らず、
/// 協調スレッドも塞ぐので使わない（実測で daemon の PR 取得がそこで止まった）
enum Subprocess {
    static let drainGrace: TimeInterval = 1
    /// terminate に応じない子を SIGKILL するまでの猶予
    static let killGrace: TimeInterval = 2

    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var openPipes = 2
        private var status: Int32?
        private var finished = false
        private(set) var timedOut = false
        private let outputLimit: Int?
        private var overflowed = false
        private let continuation: CheckedContinuation<Outcome, Never>

        init(outputLimit: Int?, _ continuation: CheckedContinuation<Outcome, Never>) {
            self.outputLimit = outputLimit
            self.continuation = continuation
        }

        /// 上限を超えたら false。超えた後の分は積まない
        func append(_ data: Data, error: Bool) -> Bool {
            let within = lock.withLock {
                if data.isEmpty {
                    openPipes -= 1
                } else if !overflowed {
                    if error { stderr.append(data) } else { stdout.append(data) }
                    if let outputLimit, stdout.count + stderr.count > outputLimit { overflowed = true }
                }
                return !overflowed
            }
            finishIfDone(force: false)
            return within
        }

        func exited(_ code: Int32) {
            lock.withLock { status = code }
            finishIfDone(force: false)
        }

        func markTimedOut() { lock.withLock { timedOut = true } }

        var isFinished: Bool { lock.withLock { finished } }

        /// `force` は終了済みならパイプの EOF を待たずに返す
        func finishIfDone(force: Bool) {
            let result: Outcome? = lock.withLock {
                guard !finished, let status, openPipes <= 0 || force else { return nil }
                finished = true
                return Outcome(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut, overflowed: overflowed)
            }
            if let result { continuation.resume(returning: result) }
        }
    }

    /// 子の終わり方と出力。`overflowed` なら出力は上限の後の分を含まない（上限を超えた 1 回の読みの分までは入る）
    struct Outcome: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var timedOut: Bool
        var overflowed: Bool
    }

    /// `outputLimit` は stdout と stderr を合わせたバイト数の上限。超えたら子を止めて失敗にする（出し続ける子の出力をメモリに積み続けない）
    @discardableResult
    static func run(
        _ executable: URL, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil, timeout: Duration = .seconds(25),
        outputLimit: Int? = nil
    ) async throws -> String {
        let outcome = try await capture(executable, arguments, cwd: cwd, environment: environment, timeout: timeout, outputLimit: outputLimit)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let command = executable.lastPathComponent + " " + arguments.prefix(2).joined(separator: " ")
        if outcome.overflowed, let outputLimit { throw SubprocessError.commandFailed(command, "出力が \(outputLimit) バイトを超えたので止めた") }
        guard outcome.status == 0, !outcome.timedOut else {
            var message = String(decoding: outcome.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if outcome.timedOut { message = ([message, "\(Int(seconds)) 秒で打ち切った"]).filter { !$0.isEmpty }.joined(separator: " / ") }
            throw SubprocessError.commandFailed(command, message)
        }
        return String(decoding: outcome.stdout, as: UTF8.self)
    }

    /// 終了コードを問わず、終わり方と出力を返す（起こせなければ投げる）。`outputLimit` を超えたら子を止めて `overflowed`。
    /// `input` は標準入力に書いて閉じる（無ければ標準入力は空）
    static func capture(
        _ executable: URL, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil, timeout: Duration = .seconds(25),
        outputLimit: Int? = nil, input: Data? = nil
    ) async throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = input.map { _ in Pipe() }
        // daemon は SIGPIPE を無視していないので、読まずに終わった子に書いても落ちないようにする（`CodexAppServerProcess` と同じ）
        if let stdin { _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        var launchError: Error?
        let outcome = await withCheckedContinuation { continuation in
            let run = Run(outputLimit: outputLimit, continuation)
            for (pipe, isError) in [(out, false), (err, true)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    // 超えても読むのはやめない（やめるとパイプが詰まって子が終わらない）。積まずに捨てて、子を止める
                    if !run.append(data, error: isError), process.isRunning { process.terminate() }
                }
            }
            process.terminationHandler = { process in
                run.exited(process.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) { run.finishIfDone(force: true) }
            }
            do {
                try process.run()
            } catch {
                launchError = error
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                run.exited(-1)
                run.finishIfDone(force: true)
                return
            }
            if let stdin, let input {
                // 子が読まずに終わっても塞がらないよう、書くのは別のスレッドで
                DispatchQueue.global().async {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard !run.isFinished, process.isRunning else { return }
                run.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if let launchError { throw launchError }
        return outcome
    }
}
