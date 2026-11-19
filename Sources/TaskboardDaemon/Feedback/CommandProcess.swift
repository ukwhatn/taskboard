import Darwin
import Foundation

/// 監視のコマンドの子。shell を自分の process group の頭にして起こし、標準出力と標準エラーを 1 本の pipe にまとめる
enum CommandProcess {
    struct Spawned: Sendable {
        var pid: pid_t
        var output: CInt
    }

    enum Event: Sendable {
        case output(Data)
        /// 出力の口が閉じた（グループの全員が pipe を閉じた）
        case closed
        case exited(AgentHostExit)
    }

    static func spawn(argv: [String], environment: [String: String], cwd: String) throws -> Spawned {
        guard let executable = argv.first else { throw AgentHostSpawnError.emptyArguments }
        var output: [CInt] = [-1, -1]
        guard pipe(&output) == 0 else { throw AgentHostSpawnError.pipe(errno) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, output[1], 2)
        posix_spawn_file_actions_addchdir(&actions, cwd)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)

        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in cArguments + cEnvironment { free(pointer) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, cArguments, cEnvironment)
        close(output[1])
        guard status == 0 else {
            close(output[0])
            throw AgentHostSpawnError.spawn(status)
        }
        return Spawned(pid: pid, output: output[0])
    }

    /// 出力を読むスレッドと、shell の終わりを待つスレッドを起こす（どちらも塞いで待つので協調スレッドで呼ばない）
    static func watch(_ process: Spawned, _ continuation: AsyncStream<Event>.Continuation) {
        let finished = Finished(continuation, parts: 2)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = read(process.output, &buffer, buffer.count)
                if count > 0 {
                    continuation.yield(.output(Data(buffer[0..<count])))
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(process.output)
            continuation.yield(.closed)
            finished.done()
        }
        Thread.detachNewThread {
            continuation.yield(.exited(AgentHostProcess.waitForExit(process.pid)))
            finished.done()
        }
    }

    /// 2 本のスレッドが両方終わったら流れを閉じる
    private final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let continuation: AsyncStream<Event>.Continuation

        init(_ continuation: AsyncStream<Event>.Continuation, parts: Int) {
            self.continuation = continuation
            remaining = parts
        }

        func done() {
            let last = lock.withLock {
                remaining -= 1
                return remaining == 0
            }
            if last { continuation.finish() }
        }
    }
}
