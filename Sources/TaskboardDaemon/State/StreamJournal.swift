import Foundation

/// `/v1/stream` の状態の出来事の控え。番号（rev）は 1 つずつ増え、件数か大きさの上限を超えたら古い方から落とす。
/// 繋ぎ直したアプリの `hello` の番号の続きが控えに全部あれば、その続きを送る（無ければ状態の全体を送る）
struct StreamJournal: Sendable {
    let countLimit: Int
    let byteLimit: Int
    /// 最後に振った番号
    private(set) var rev = 0
    /// この番号より後の出来事は全部控えにある
    private(set) var base = 0
    private var entries: [(rev: Int, frame: Data)] = []
    private var bytes = 0

    init(countLimit: Int = 2_000, byteLimit: Int = 4 << 20) {
        self.countLimit = countLimit
        self.byteLimit = byteLimit
    }

    /// 次の番号を振る（`frame` はその番号を載せて作る）
    func nextRev() -> Int { rev + 1 }

    /// `nextRev()` の番号の出来事を控えに足す
    mutating func append(_ frame: Data) {
        rev += 1
        entries.append((rev, frame))
        bytes += frame.count
        while entries.count > countLimit || (bytes > byteLimit && !entries.isEmpty) {
            let first = entries.removeFirst()
            bytes -= first.frame.count
            base = first.rev
        }
    }

    /// 状態の全体を送った（`nextRev()` の番号で）。それより前の続きは送れなくなる
    mutating func reset() {
        rev += 1
        entries.removeAll()
        bytes = 0
        base = rev
    }

    /// `after` より後の出来事。控えから落ちていれば nil（`after` が今の番号より先のときも）
    func frames(after: Int) -> [Data]? {
        guard after >= base, after <= rev else { return nil }
        return entries.drop(while: { $0.rev <= after }).map(\.frame)
    }
}
