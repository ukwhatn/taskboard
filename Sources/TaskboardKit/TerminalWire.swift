// ui-copy:ignore-file
// このファイルの文（端末の電文の解釈の失敗の文）は、MCP の応答・保存される状態・ログに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation

// `/v1/terminal/{pane_id}` の WebSocket の電文。
// サーバ → クライアント: 端末のバイト列はバイナリ frame、制御情報は JSON テキスト frame。
// クライアント → サーバ: JSON テキスト frame だけ。

/// サーバが送る制御情報。
public enum TerminalServerMessage: Hashable, Sendable {
    /// 直後のバイナリ frame の予告。全画面を描き直す frame と、サイズが変わった frame の前に送る。
    case frame(seq: UInt64, full: Bool, cols: Int, rows: Int)
    /// 観察中（読むだけ）か操作中（入力が届く）か。
    case mode(TerminalMode)
    /// 操作を取ろうとしたが、別のクライアントが操作中。`acquire(takeover: true)` で奪える。
    case controllerBusy
    /// 操作を失った。別のクライアントに奪われた（`takenOver`）か、シェルとの接続が切れた（`disconnected`）。
    case controlLost(TerminalControlLossReason)
    /// この pane の中継を終える。クライアントは再接続しない。
    case closed(reason: TerminalCloseReason, message: String?)
}

public enum TerminalMode: String, Codable, Hashable, Sendable {
    case observe
    case control
}

public enum TerminalControlLossReason: String, Codable, Hashable, Sendable {
    case takenOver = "taken_over"
    case disconnected
}

public enum TerminalCloseReason: String, Codable, Hashable, Sendable {
    /// そのシェルが無い。
    case paneNotFound = "pane_not_found"
    /// クライアントが受け取るより速く出力が溜まり、上限を超えた。再接続すれば最初の frame で全画面が戻る。
    case queueOverflow = "queue_overflow"
}

/// クライアントが送る操作。
public enum TerminalClientMessage: Hashable, Sendable {
    /// 操作権を取る。既に別のクライアントが持っていれば `takeover` が false のときは `controllerBusy` が返る。
    case acquire(takeover: Bool)
    /// 端末への入力バイト列。観察中に送ると、まず `acquire(takeover: false)` を試みてから届ける。
    case input(Data)
    case resize(cols: Int, rows: Int)
    /// 操作権を返す。観察に戻る。
    case release
}

// MARK: - Codable（`{"type": ..., ...}` の平らな JSON）

extension TerminalServerMessage: Codable {
    private struct Raw: Codable {
        var type: String
        var seq: UInt64?
        var full: Bool?
        var cols: Int?
        var rows: Int?
        var mode: TerminalMode?
        var reason: String?
        var message: String?
    }

    public init(from decoder: Decoder) throws {
        let raw = try Raw(from: decoder)
        switch raw.type {
        case "frame":
            guard let seq = raw.seq, let full = raw.full, let cols = raw.cols, let rows = raw.rows else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "frame に seq/full/cols/rows が要る"))
            }
            self = .frame(seq: seq, full: full, cols: cols, rows: rows)
        case "mode":
            guard let mode = raw.mode else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "mode が要る"))
            }
            self = .mode(mode)
        case "controller_busy":
            self = .controllerBusy
        case "control_lost":
            guard let reason = raw.reason.flatMap(TerminalControlLossReason.init(rawValue:)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "control_lost の reason が不明: \(raw.reason ?? "nil")"))
            }
            self = .controlLost(reason)
        case "closed":
            guard let reason = raw.reason.flatMap(TerminalCloseReason.init(rawValue:)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "closed の reason が不明: \(raw.reason ?? "nil")"))
            }
            self = .closed(reason: reason, message: raw.message)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown server message \(raw.type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var raw: Raw
        switch self {
        case .frame(let seq, let full, let cols, let rows):
            raw = Raw(type: "frame")
            raw.seq = seq
            raw.full = full
            raw.cols = cols
            raw.rows = rows
        case .mode(let mode):
            raw = Raw(type: "mode")
            raw.mode = mode
        case .controllerBusy:
            raw = Raw(type: "controller_busy")
        case .controlLost(let reason):
            raw = Raw(type: "control_lost")
            raw.reason = reason.rawValue
        case .closed(let reason, let message):
            raw = Raw(type: "closed")
            raw.reason = reason.rawValue
            raw.message = message
        }
        try raw.encode(to: encoder)
    }
}

extension TerminalClientMessage: Codable {
    private struct Raw: Codable {
        var type: String
        var takeover: Bool?
        var bytes: String?
        var cols: Int?
        var rows: Int?
    }

    public init(from decoder: Decoder) throws {
        let raw = try Raw(from: decoder)
        switch raw.type {
        case "acquire":
            self = .acquire(takeover: raw.takeover ?? false)
        case "input":
            guard let data = raw.bytes.flatMap({ Data(base64Encoded: $0) }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "input の bytes が base64 でない"))
            }
            self = .input(data)
        case "resize":
            guard let cols = raw.cols, let rows = raw.rows else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "resize に cols/rows が要る"))
            }
            self = .resize(cols: cols, rows: rows)
        case "release":
            self = .release
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown client message \(raw.type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var raw: Raw
        switch self {
        case .acquire(let takeover):
            raw = Raw(type: "acquire")
            raw.takeover = takeover
        case .input(let data):
            raw = Raw(type: "input")
            raw.bytes = data.base64EncodedString()
        case .resize(let cols, let rows):
            raw = Raw(type: "resize")
            raw.cols = cols
            raw.rows = rows
        case .release:
            raw = Raw(type: "release")
        }
        try raw.encode(to: encoder)
    }
}

// MARK: - 新しい pane
