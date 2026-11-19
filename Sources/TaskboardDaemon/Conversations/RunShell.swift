import Foundation

/// コードブロックの実行のシェルの種類と、擬似端末に打ち込む行。
/// 行は目印（`\u{1e}TB:<種類>:<id>\u{1e}`）を出し、`RunShellScanner` が出力から拾う
enum RunShell: String, Sendable, CaseIterable {
    case bash, zsh, fish

    /// 札から動かすシェルと実行ファイル。ログインシェルと同じ種類ならその実行ファイルを使う。
    /// shell・console はログインシェル（bash・zsh・fish でなければ bash）。fish が見つからなければ nil
    static func resolve(language: String, loginShell: String?, path: String?) -> (shell: RunShell, executable: String)? {
        let login = loginShell.flatMap { RunShell(rawValue: URL(fileURLWithPath: $0).lastPathComponent) }
        let shell: RunShell
        switch language.lowercased() {
        case "bash", "sh": shell = .bash
        case "zsh": shell = .zsh
        case "fish": shell = .fish
        case "shell", "console": shell = login ?? .bash
        default: return nil
        }
        if let loginShell, login == shell { return (shell, loginShell) }
        switch shell {
        case .bash: return (shell, "/bin/bash")
        case .zsh: return (shell, "/bin/zsh")
        case .fish:
            let fish = (path ?? "").split(separator: ":").map { "\($0)/fish" }.first { FileManager.default.isExecutableFile(atPath: $0) }
            return fish.map { (shell, $0) }
        }
    }

    /// 対話モードで起こす（設定ファイルを読ませる）。`-l` は付けない（login の profile が渡した PATH を並べ替えるため）
    var arguments: [String] {
        switch self {
        case .bash: ["-i"]
        // INC_APPEND_HISTORY などで打った行がすぐ履歴に書かれるのを、先頭の空白で避ける
        case .zsh: ["-i", "-o", "histignorespace"]
        case .fish: ["-i", "--private"]
        }
    }

    /// 履歴を書かない・ジョブ制御を切る（Ctrl-C で行の全体を止めるため）・準備の目印。
    /// コードが `exit` するとシェルごと終わるので、終わるときに動いていた Run の終わりの目印を出させる
    func setupLine(id: String) -> Data {
        switch self {
        case .bash, .zsh:
            line(" unset HISTFILE; set +m; trap 'printf \"\\036TB:E:%s:%d\\036\" \"$__tb_run\" $?' EXIT; \(mark("R", id))")
        case .fish:
            line(" status job-control none; function __tb_exit --on-event fish_exit; printf '\\x1eTB:E:%s:%d\\x1e' \"$__tb_run\" $argv[1]; end; \(mark("R", id))")
        }
    }

    /// `file` を今のシェルで読む（変数と cd を残す）。始まりと終わり（終了コードつき）の目印で挟む
    func runLine(id: String, file: String) -> Data {
        switch self {
        case .bash, .zsh: line(" __tb_run=\(id); \(mark("S", id)); . \(quote(file)) </dev/null; printf '\\036TB:E:%s:%d\\036' \(id) $?")
        case .fish: line(" set -g __tb_run \(id); \(mark("S", id)); source \(quote(file)) </dev/null; printf '\\x1eTB:E:%s:%d\\x1e' \(id) $status")
        }
    }

    /// 止めた後の目印。zsh は Ctrl-C で先に打った入力を捨てるので、プロンプトに戻ってから届くよう書き直す
    func stopLine(id: String) -> Data { line(" \(mark("C", id))") }

    private func mark(_ kind: String, _ id: String) -> String {
        switch self {
        case .bash, .zsh: "printf '\\036TB:\(kind):%s\\036' \(id)"
        case .fish: "printf '\\x1eTB:\(kind):%s\\x1e' \(id)"
        }
    }

    private func quote(_ text: String) -> String {
        switch self {
        case .bash, .zsh: "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .fish: "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
    }

    private func line(_ text: String) -> Data { Data((text + "\n").utf8) }
}

/// 実行のシェルの出力を、目印・端末への問い合わせ（DA1）・文に分ける。端末の制御の列と CR、改行とタブ以外の制御文字は落とす。
/// 列が出力の切れ目をまたいでも、続きから読む
struct RunShellScanner {
    enum Mark: Equatable {
        case ready(String)
        case start(String)
        case end(String, Int32)
        case stop(String)
    }

    enum Piece: Equatable {
        case text(Data)
        case mark(Mark)
        /// DA1（`ESC [ c`）。答えるまで進まないシェルがある（fish 4）
        case query
    }

    private enum State {
        case text
        case escape
        case csi([UInt8])
        /// OSC・DCS などの文字列。`escaped` は直前が ESC
        case string(escaped: Bool)
        case mark([UInt8])
    }

    private static let separator: UInt8 = 0x1e
    private static let markLimit = 128
    private var state = State.text

    mutating func feed(_ data: Data) -> [Piece] {
        var pieces: [Piece] = []
        var text = Data()
        func emit(_ piece: Piece) {
            if !text.isEmpty { pieces.append(.text(text)) }
            text.removeAll()
            pieces.append(piece)
        }
        for byte in data {
            switch state {
            case .text:
                switch byte {
                case Self.separator: state = .mark([])
                case 0x1b: state = .escape
                case 0x0a, 0x09: text.append(byte)
                case ..<0x20, 0x7f: break
                default: text.append(byte)
                }
            case .escape:
                switch byte {
                case UInt8(ascii: "["): state = .csi([])
                case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"): state = .string(escaped: false)
                // `ESC ( B` のような中間の文字の続く列
                case 0x20...0x2f: break
                default: state = .text
                }
            case .csi(var parameters):
                switch byte {
                case 0x20...0x3f:
                    parameters.append(byte)
                    state = .csi(parameters)
                case 0x40...0x7e:
                    if byte == UInt8(ascii: "c"), parameters.isEmpty || parameters == [UInt8(ascii: "0")] { emit(.query) }
                    state = .text
                default: break
                }
            case .string(let escaped):
                if byte == 0x07 || escaped {
                    state = .text
                } else {
                    state = .string(escaped: byte == 0x1b)
                }
            case .mark(var bytes):
                if byte == Self.separator {
                    if let mark = Self.parse(bytes) { emit(.mark(mark)) }
                    state = .text
                } else if bytes.count >= Self.markLimit {
                    state = .text
                } else {
                    bytes.append(byte)
                    state = .mark(bytes)
                }
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    private static func parse(_ bytes: [UInt8]) -> Mark? {
        let parts = String(decoding: bytes, as: UTF8.self).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "TB", !parts[2].isEmpty else { return nil }
        switch (parts[1], parts.count) {
        case ("R", 3): return .ready(parts[2])
        case ("S", 3): return .start(parts[2])
        case ("C", 3): return .stop(parts[2])
        case ("E", 4): return Int32(parts[3]).map { .end(parts[2], $0) }
        default: return nil
        }
    }
}
