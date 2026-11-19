import Darwin
import Foundation
import Logging
import NIOCore
import NIOPosix

/// host が持つシェル（擬似端末のログインシェル）。daemon を入れ替えても切れないよう、会話の子と同じく host が持つ。
/// 出力は直近 `keptBytes` をためておき、購読した接続に流す。位置は起こしてからの出力のバイト数で数える
actor AgentHostShells {
    struct Limits: Sendable {
        var keptBytes = 1 << 20
    }

    private struct Shell {
        var generation: Int
        var pid: pid_t
        var cols: Int
        var rows: Int
        var startedAt: Date
        /// 大きさを変える ioctl の口（読み書きの口は NIO が持つ）
        var control: CInt
        var writer: NIOAsyncChannelOutboundWriter<ByteBuffer>?
        var kept = Data()
        var written = 0
        var subscribers: Set<Int> = []
    }

    let limits: Limits
    let logger: Logger
    /// 子の env に `OrphanedChildren.hostMarker` で渡す値（`AgentHostRegistry.init`）
    private let hostTag: String?
    private var shells: [String: Shell] = [:]
    private var generation = 0
    private var sinks: [Int: AgentHostSink] = [:]

    init(limits: Limits = Limits(), hostTag: String? = nil, logger: Logger) {
        self.limits = limits
        self.hostTag = hostTag
        self.logger = logger
    }

    func attach(_ sink: AgentHostSink) { sinks[sink.id] = sink }

    func detach(_ id: Int) {
        sinks[id] = nil
        for key in shells.keys { shells[key]?.subscribers.remove(id) }
    }

    func handle(_ request: AgentHostRequest, key: String, from connection: Int) async throws -> AgentHostReply {
        switch request.op {
        case .shellOpen:
            guard let argv = request.argv, !argv.isEmpty else { throw AgentHostRegistry.Failure.missing("argv") }
            guard let cwd = request.cwd else { throw AgentHostRegistry.Failure.missing("cwd") }
            let pid = try await open(key: key, argv: argv, env: request.env ?? [:], cwd: cwd, cols: request.cols ?? 80, rows: request.rows ?? 24)
            return AgentHostReply(id: request.id, ok: true, pid: pid)
        case .shellInput:
            guard let data = request.data.flatMap({ Data(base64Encoded: $0) }) else { throw AgentHostRegistry.Failure.missing("data") }
            guard let writer = shells[key]?.writer else { throw AgentHostRegistry.Failure.unknown(key) }
            try await writer.write(ByteBuffer(bytes: data))
        case .shellResize:
            guard var shell = shells[key] else { throw AgentHostRegistry.Failure.unknown(key) }
            let size = Self.clamp(cols: request.cols ?? shell.cols, rows: request.rows ?? shell.rows)
            shell.cols = size.cols
            shell.rows = size.rows
            shells[key] = shell
            var window = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(shell.control, TIOCSWINSZ, &window)
        case .shellClose:
            close(key: key)
        case .shellSubscribe:
            guard let shell = shells[key], sinks[connection] != nil else { throw AgentHostRegistry.Failure.unknown(key) }
            shells[key]?.subscribers.insert(connection)
            return AgentHostReply(id: request.id, ok: true, data: Self.tail(shell.kept, limit: limits.keptBytes).base64EncodedString(), offset: shell.written)
        case .shellUnsubscribe:
            shells[key]?.subscribers.remove(connection)
        default:
            throw AgentHostRegistry.Failure.missing("op")
        }
        return AgentHostReply(id: request.id, ok: true)
    }

    func list() -> [AgentHostShellInfo] {
        shells.sorted { $0.key < $1.key }.map { key, shell in
            AgentHostShellInfo(key: key, pid: shell.pid, cols: shell.cols, rows: shell.rows, startedAt: shell.startedAt.timeIntervalSince1970)
        }
    }

    /// 末尾の `limit` バイト。行の途中（エスケープ列の途中）から始めないよう、4KB 以内に改行があればその後から
    static func tail(_ data: Data, limit: Int) -> Data {
        guard data.count > limit else { return data }
        var start = data.endIndex - limit
        if let newline = data[start...].prefix(4096).firstIndex(of: UInt8(ascii: "\n")) { start = newline + 1 }
        return Data(data[start...])
    }

    static func clamp(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        (min(max(cols, 2), 500), min(max(rows, 2), 500))
    }

    // MARK: 起こす・閉じる

    private func open(key: String, argv: [String], env: [String: String], cwd: String, cols: Int, rows: Int) async throws -> pid_t {
        if let running = shells[key] { return running.pid }
        let size = Self.clamp(cols: cols, rows: rows)
        var environment = env
        environment[OrphanedChildren.hostMarker] = hostTag
        let spawned = try AgentHostPTY.spawn(argv: argv, environment: environment, cwd: cwd, cols: size.cols, rows: size.rows)
        generation += 1
        let generation = generation
        let control = dup(spawned.master)
        let output = dup(spawned.master)
        shells[key] = Shell(generation: generation, pid: spawned.pid, cols: size.cols, rows: size.rows, startedAt: Date(), control: control)
        Thread.detachNewThread { [weak self] in
            let exit = AgentHostProcess.waitForExit(spawned.pid)
            Task { await self?.exited(key: key, generation: generation, exit: exit) }
        }
        do {
            let channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .takingOwnershipOfDescriptors(input: spawned.master, output: output) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
                    }
                }
            Task.detached { [weak self] in
                // シェルが擬似端末を閉じると、読み口は EOF でなく EIO で終わる
                try? await channel.executeThenClose { inbound, outbound in
                    await self?.attachWriter(key: key, generation: generation, writer: outbound)
                    for try await chunk in inbound { await self?.received(key: key, generation: generation, Data(chunk.readableBytesView)) }
                }
            }
        } catch {
            kill(-spawned.pid, SIGKILL)
            Darwin.close(spawned.master)
            Darwin.close(output)
            throw error
        }
        logger.info("shell opened", metadata: ["key": .string(key), "pid": .stringConvertible(spawned.pid)])
        return spawned.pid
    }

    private func attachWriter(key: String, generation: Int, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        guard shells[key]?.generation == generation else { return }
        shells[key]?.writer = writer
    }

    /// HUP で終わらないシェル（HUP を無視するコマンドの前面にいる）は 2 秒後に KILL する
    private func close(key: String) {
        guard let shell = shells[key] else { return }
        kill(-shell.pid, SIGHUP)
        shell.writer?.finish()
        let generation = shell.generation
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.killIfStill(key: key, generation: generation)
        }
    }

    private func killIfStill(key: String, generation: Int) {
        guard let shell = shells[key], shell.generation == generation else { return }
        kill(-shell.pid, SIGKILL)
    }

    // MARK: シェルから

    private func received(key: String, generation: Int, _ data: Data) {
        guard var shell = shells[key], shell.generation == generation, !data.isEmpty else { return }
        let start = shell.written
        shell.written += data.count
        shell.kept.append(data)
        // 上限の倍までためてから切る（出力のたびに 1MB を写し直さない）
        if shell.kept.count > limits.keptBytes * 2 { shell.kept = Self.tail(shell.kept, limit: limits.keptBytes) }
        shells[key] = shell
        let notice = AgentHostNotice(event: .shellOutput, key: key, seq: start, data: data.base64EncodedString())
        for id in shell.subscribers { sinks[id]?.send(notice) }
    }

    private func exited(key: String, generation: Int, exit: AgentHostExit) {
        guard let shell = shells[key], shell.generation == generation else { return }
        shell.writer?.finish()
        Darwin.close(shell.control)
        shells[key] = nil
        logger.info("shell exited", metadata: ["key": .string(key), "status": "\(exit.status.map(String.init) ?? "-")", "signal": "\(exit.signal.map(String.init) ?? "-")"])
        let notice = AgentHostNotice(event: .shellExit, key: key, exit: exit)
        for id in shell.subscribers { sinks[id]?.send(notice) }
    }
}

/// 擬似端末で子を起こす。子を session の頭にして擬似端末を制御端末にする（Ctrl-C が前面のコマンドに届く）。
/// `posix_spawn` は制御端末を持たせられないので `forkpty` で起こし、fork の後は async-signal-safe な呼び出しだけで exec する
enum AgentHostPTY {
    struct Spawned {
        var pid: pid_t
        var master: CInt
    }

    static func spawn(argv: [String], environment: [String: String], cwd: String, cols: Int, rows: Int) throws -> Spawned {
        guard let executable = argv.first else { throw AgentHostSpawnError.emptyArguments }
        let path = strdup(executable)
        let directory = strdup(cwd)
        let cArguments = argv.map { strdup($0) } + [nil]
        let cEnvironment = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            free(path)
            free(directory)
            for pointer in cArguments + cEnvironment { free(pointer) }
        }
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        let highestDescriptor = CInt(min(limit.rlim_cur, 65_536))
        var window = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: CInt = -1
        let pid = cArguments.withUnsafeBufferPointer { arguments in
            cEnvironment.withUnsafeBufferPointer { environment in
                let pid = forkpty(&master, nil, nil, &window)
                if pid == 0 {
                    // 子。host の socket と会話の子の pipe を持ち出さない（会話の子の標準入力の口を握ると、入力を閉じても EOF が届かない）
                    var descriptor: CInt = 3
                    while descriptor < highestDescriptor {
                        Darwin.close(descriptor)
                        descriptor += 1
                    }
                    // host は SIGPIPE を無視し、同じプロセスの ServiceLifecycle は SIGINT・SIGTERM を無視にする。無視は exec を越えて残り、Ctrl-C が効かなくなる
                    for number in 1..<NSIG where number != SIGKILL && number != SIGSTOP {
                        signal(number, SIG_DFL)
                    }
                    var none = sigset_t()
                    sigemptyset(&none)
                    sigprocmask(SIG_SETMASK, &none, nil)
                    if chdir(directory) != 0 { _ = chdir("/") }
                    execve(path, arguments.baseAddress, environment.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw AgentHostSpawnError.spawn(errno) }
        return Spawned(pid: pid, master: master)
    }
}
