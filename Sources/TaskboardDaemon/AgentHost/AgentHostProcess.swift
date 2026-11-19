import Darwin
import Foundation
import NIOCore

/// agent host が起こした子プロセスの、親の側に残る口。
struct SpawnedProcess: Sendable {
    var pid: pid_t
    /// 子の標準入力に書く口
    var input: CInt
    /// 子の標準出力を読む口
    var output: CInt
    /// 子の標準エラーを読む口
    var errors: CInt
}

enum AgentHostSpawnError: Error, CustomStringConvertible {
    case pipe(Int32)
    case spawn(Int32)
    case emptyArguments

    var description: String {
        switch self {
        case .pipe(let code): "pipe を作れない: \(String(cString: strerror(code)))"
        case .spawn(let code): "起こせない: \(String(cString: strerror(code)))"
        case .emptyArguments: "argv が空"
        }
    }
}

enum AgentHostProcess {
    /// 子は自分の process group の頭にする（止めるときに、子が起こした MCP の server や Bash のコマンドもまとめて送れる）。
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` で、0〜2 のほか（host の socket や他の子の pipe）を子に渡さない
    static func spawn(argv: [String], environment: [String: String], cwd: String) throws -> SpawnedProcess {
        guard let executable = argv.first else { throw AgentHostSpawnError.emptyArguments }
        var input: [CInt] = [-1, -1]
        var output: [CInt] = [-1, -1]
        var errors: [CInt] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            let code = errno
            for fd in input + output + errors where fd >= 0 { close(fd) }
            throw AgentHostSpawnError.pipe(code)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
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
        close(input[0])
        close(output[1])
        close(errors[1])
        guard status == 0 else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw AgentHostSpawnError.spawn(status)
        }
        return SpawnedProcess(pid: pid, input: input[1], output: output[0], errors: errors[0])
    }

    /// 終わるまで待って、終わり方を返す。子ごとに 1 本のスレッドで呼ぶ（waitpid で塞ぐので協調スレッドで呼ばない）
    static func waitForExit(_ pid: pid_t) -> AgentHostExit {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { return AgentHostExit(status: nil, signal: nil) }
        }
        let signal = status & 0x7f
        if signal == 0 { return AgentHostExit(status: (status >> 8) & 0xff, signal: nil) }
        return AgentHostExit(status: nil, signal: signal)
    }
}

struct AgentHostExit: Codable, Equatable, Sendable {
    var status: Int32?
    var signal: Int32?
}

/// 子の標準出力の 1 行。上限を超えた行は中身を捨てて長さだけを知らせる
enum AgentHostLine: Sendable, Equatable {
    case line(String)
    case oversize(bytes: Int)
}

/// 改行までの 1 行を 1 つにする。`LineFrameDecoder` と違い 1 行の上限があり、
/// 超えた分は次の区切りまで読み捨てる（相手が区切りを出さずに書き続けてもメモリが増え続けない）
final class BoundedLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = AgentHostLine

    let maximumLength: Int
    private var discarded: Int?
    private var search: NewlineSearch

    init(maximumLength: Int) {
        self.maximumLength = maximumLength
        search = NewlineSearch()
    }

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if let length = search.next(in: buffer) {
            if let skipped = discarded {
                buffer.moveReaderIndex(forwardBy: length + 1)
                discarded = nil
                context.fireChannelRead(wrapInboundOut(.oversize(bytes: skipped + length)))
                return .continue
            }
            let line = buffer.readSlice(length: length)!
            buffer.moveReaderIndex(forwardBy: 1)
            if length > maximumLength {
                context.fireChannelRead(wrapInboundOut(.oversize(bytes: length)))
            } else if length > 0 {
                context.fireChannelRead(wrapInboundOut(.line(String(buffer: line))))
            }
            return .continue
        }
        if buffer.readableBytes > maximumLength {
            discarded = (discarded ?? 0) + buffer.readableBytes
            buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            search.reset()
        }
        return .needMoreData
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        if let skipped = discarded {
            discarded = nil
            context.fireChannelRead(wrapInboundOut(.oversize(bytes: skipped + buffer.readableBytes)))
        } else if buffer.readableBytes > 0 {
            let rest = buffer.readSlice(length: buffer.readableBytes)!
            context.fireChannelRead(wrapInboundOut(.line(String(buffer: rest))))
        }
        buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
        return .needMoreData
    }
}
