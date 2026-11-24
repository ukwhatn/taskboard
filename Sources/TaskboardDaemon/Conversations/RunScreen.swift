import Foundation

/// Run の出力を端末のように置く行の画面。`\r` での上書き・`\b`・カーソルの移動・行の消去（スピナーと進捗バーの出し方）を解釈し、色は捨てる。
/// 最後の `liveRows` 行だけを書き換えられる行として持ち、それより上に流れた行は確定（`take` の `committed`）にする。
/// 絶対位置（`CSI H`）と画面の消去（`CSI 2J`）は解釈しない（上に流れた行を消せないので、出力の履歴を残す方を選ぶ）
struct RunScreen {
    enum Control: Equatable {
        case up(Int), down(Int), forward(Int), back(Int)
        /// 次の行（`E`）・前の行（`F`）の頭
        case nextLine(Int), previousLine(Int)
        /// 1 から数えた桁（`G`）
        case column(Int)
        /// 0: カーソルから行末、1: 行頭からカーソル、2: 行全体
        case eraseLine(Int)
        /// 0: カーソルから画面の終わり
        case eraseBelow
    }

    let liveRows: Int
    private var lines: [[Character]] = [[]]
    private var row = 0
    private var col = 0
    /// 文字の途中で切れた UTF-8 のバイト
    private var partial = Data()
    /// まだ `take` で渡していない確定した文
    private var committed = ""
    /// 前の `take` の後に、書き換えられる行が変わった
    private var changed = false

    init(liveRows: Int = 24) {
        self.liveRows = liveRows
    }

    mutating func write(_ data: Data) {
        partial.append(data)
        let (text, used) = ConversationRuns.decodePrefix(partial)
        partial.removeFirst(used)
        guard !text.isEmpty else { return }
        changed = true
        for character in text {
            switch character {
            case "\r\n", "\n": newLine()
            case "\r": col = 0
            case "\u{8}": col = max(col - 1, 0)
            case "\t": col = (col / 8 + 1) * 8
            default: put(character)
            }
        }
        freeze()
    }

    mutating func apply(_ control: Control) {
        changed = true
        switch control {
        case .up(let n): row = max(row - max(n, 1), 0)
        case .down(let n): moveDown(max(n, 1))
        case .forward(let n): col += max(n, 1)
        case .back(let n): col = max(col - max(n, 1), 0)
        case .nextLine(let n):
            moveDown(max(n, 1))
            col = 0
        case .previousLine(let n):
            row = max(row - max(n, 1), 0)
            col = 0
        case .column(let n): col = max(n, 1) - 1
        case .eraseLine(let mode):
            switch mode {
            case 1: for i in 0..<min(col + 1, lines[row].count) { lines[row][i] = " " }
            case 2: lines[row] = []
            default: if col < lines[row].count { lines[row].removeSubrange(col...) }
            }
        case .eraseBelow:
            if col < lines[row].count { lines[row].removeSubrange(col...) }
            lines.removeSubrange((row + 1)...)
        }
        freeze()
    }

    /// 前の `take` の後に確定した文と、今の書き換えられる行（変わっていなければ nil）。`final` なら書き換えられる行も確定にして空にする
    mutating func take(final: Bool = false) -> (committed: String, tail: String?) {
        if final {
            let rest = Self.text(lines)
            if !rest.isEmpty { committed += rest }
            lines = [[]]
            row = 0
            col = 0
            changed = true
        }
        let out = committed
        committed = ""
        defer { changed = false }
        return (out, changed ? Self.text(lines) : nil)
    }

    private mutating func put(_ character: Character) {
        if col < lines[row].count {
            lines[row][col] = character
        } else {
            lines[row].append(contentsOf: repeatElement(" ", count: col - lines[row].count))
            lines[row].append(character)
        }
        col += 1
    }

    private mutating func newLine() {
        moveDown(1)
        col = 0
    }

    private mutating func moveDown(_ n: Int) {
        row += n
        while lines.count <= row { lines.append([]) }
    }

    /// 書き換えられる行を超えて上に流れた行を確定にする
    private mutating func freeze() {
        let over = lines.count - liveRows
        guard over > 0 else { return }
        for line in lines.prefix(over) { committed += Self.trimmed(line) + "\n" }
        lines.removeFirst(over)
        row = max(row - over, 0)
    }

    private static func trimmed(_ line: [Character]) -> String {
        var line = line
        while line.last == " " { line.removeLast() }
        return String(line)
    }

    /// 行の並びの文。最後の空の行（改行で終わった出力のカーソルの行）は改行だけにする
    private static func text(_ lines: [[Character]]) -> String {
        var rows = lines.map(trimmed)
        if rows.last == "" { rows.removeLast(); return rows.map { $0 + "\n" }.joined() }
        return rows.joined(separator: "\n")
    }
}
