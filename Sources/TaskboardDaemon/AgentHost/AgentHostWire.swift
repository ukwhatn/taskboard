import Foundation
import NIOCore

/// daemon と agent host の間のやり取り。1 行 1 JSON で、要求には `id` を付け、host は同じ `id` で応答する。
/// 応答の無い知らせ（子の出力・終わり）は `event` を持つ。host は会話の中身を知らず、子の出力の行を番号つきで控えて渡すだけ
enum AgentHostWire {
    /// 変えたら daemon が古い host を見分けられるよう上げる
    static let protocolVersion = 2
    /// daemon が会話を任せ続ける最も古い版。これより新しい要求（シェル）は `protocolVersion` の host にだけ送る。
    /// 版が上がるたびに drain すると、入れ替えを待つ間に動いている会話を誰も読まなくなる
    static let oldestServedVersion = 1
    /// シェル（`shell_*`）を受ける最も古い版
    static let shellVersion = 2

    static func encode<T: Encodable>(_ value: T) throws -> ByteBuffer {
        var data = try JSONEncoder().encode(value)
        data.append(UInt8(ascii: "\n"))
        return ByteBuffer(bytes: data)
    }

    /// 応答か知らせか。`event` があれば知らせ
    enum Frame: Sendable {
        case reply(AgentHostReply)
        case notice(AgentHostNotice)
    }

    static func decodeFrame(_ data: Data) throws -> Frame {
        struct Head: Decodable { var event: String? }
        if try JSONDecoder().decode(Head.self, from: data).event != nil {
            return .notice(try JSONDecoder().decode(AgentHostNotice.self, from: data))
        }
        return .reply(try JSONDecoder().decode(AgentHostReply.self, from: data))
    }
}

struct AgentHostRequest: Codable, Sendable, Equatable {
    enum Op: String, Codable, Sendable {
        case hello, spawn, write, signal, subscribe, unsubscribe, trim, list, drain
        case closeInput = "close_input"
        /// 擬似端末でログインシェルを起こす（`key`・`argv`・`env`・`cwd`・`cols`・`rows`）。同じ key のシェルが生きていれば起こさずに成功する
        case shellOpen = "shell_open"
        /// シェルに書く（`data` は base64）
        case shellInput = "shell_input"
        case shellResize = "shell_resize"
        /// シェルの process group に HUP を送り、擬似端末を閉じる
        case shellClose = "shell_close"
        /// ためた出力を応答の `data` で返し、以後の出力を `shell_output` で送る
        case shellSubscribe = "shell_subscribe"
        case shellUnsubscribe = "shell_unsubscribe"
        case shellList = "shell_list"
    }

    var id: Int
    var op: Op
    var key: String?
    var argv: [String]?
    var env: [String: String]?
    var cwd: String?
    /// 子の標準入力に書く文字（`write`）
    var data: String?
    /// `INT`・`TERM`・`KILL`
    var signal: String?
    /// `subscribe`：この番号より後の行から送る
    var after: Int?
    /// `trim`：この番号までの行を控えから捨てる
    var through: Int?
    /// `shell_open`・`shell_resize`：擬似端末の大きさ
    var cols: Int?
    var rows: Int?

    init(
        id: Int, op: Op, key: String? = nil, argv: [String]? = nil, env: [String: String]? = nil, cwd: String? = nil, data: String? = nil,
        signal: String? = nil, after: Int? = nil, through: Int? = nil, cols: Int? = nil, rows: Int? = nil
    ) {
        self.id = id
        self.op = op
        self.key = key
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.data = data
        self.signal = signal
        self.after = after
        self.through = through
        self.cols = cols
        self.rows = rows
    }
}

struct AgentHostReply: Codable, Sendable, Equatable {
    var id: Int
    var ok: Bool
    var error: String?
    /// `hello`
    var protocolVersion: Int?
    /// `hello` は host の pid、`spawn` は子の pid
    var pid: Int32?
    /// `hello`：host が起動した時刻（Unix 時刻の秒）。変わっていれば host が起き直していて、番号は 1 から振り直されている
    var startedAt: Double?
    var processes: [AgentHostProcessInfo]?
    /// `shell_subscribe`：ためた出力（base64）と、その終わりの位置（シェルを起こしてからの出力のバイト数）
    var data: String?
    var offset: Int?
    /// `shell_list`
    var shells: [AgentHostShellInfo]?

    init(
        id: Int, ok: Bool, error: String? = nil, protocolVersion: Int? = nil, pid: Int32? = nil, startedAt: Double? = nil,
        processes: [AgentHostProcessInfo]? = nil, data: String? = nil, offset: Int? = nil, shells: [AgentHostShellInfo]? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.startedAt = startedAt
        self.processes = processes
        self.data = data
        self.offset = offset
        self.shells = shells
    }
}

struct AgentHostShellInfo: Codable, Sendable, Equatable {
    var key: String
    var pid: Int32
    var cols: Int
    var rows: Int
    var startedAt: Double
}

struct AgentHostProcessInfo: Codable, Sendable, Equatable {
    var key: String
    var pid: Int32
    var alive: Bool
    var exit: AgentHostExit?
    /// 最後に振った番号（まだ 1 行も無ければ 0）
    var lastSeq: Int
    /// 控えにある最も古い番号。これより前は捨てた
    var firstSeq: Int
    var keptBytes: Int
    var startedAt: Double
}

struct AgentHostNotice: Codable, Sendable, Equatable {
    enum Event: String, Codable, Sendable {
        /// 子の標準出力の 1 行
        case output
        /// 控えの上限で捨てた行がある（`through` まで）
        case gap
        /// 上限を超えた 1 行を捨てた（`seq` の行。`bytes` はその長さ）
        case oversize
        /// 子が終わり、標準出力も読み終えた
        case exit
        /// シェルの出力（`data` は base64、`seq` はその始まりの位置）
        case shellOutput = "shell_output"
        /// シェルが終わった（擬似端末も閉じた）
        case shellExit = "shell_exit"
    }

    var event: Event
    var key: String
    var seq: Int?
    var line: String?
    var through: Int?
    var bytes: Int?
    var exit: AgentHostExit?
    var data: String?

    init(
        event: Event, key: String, seq: Int? = nil, line: String? = nil, through: Int? = nil, bytes: Int? = nil, exit: AgentHostExit? = nil,
        data: String? = nil
    ) {
        self.event = event
        self.key = key
        self.seq = seq
        self.line = line
        self.through = through
        self.bytes = bytes
        self.exit = exit
        self.data = data
    }
}
