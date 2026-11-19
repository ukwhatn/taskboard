import Foundation
import GRDB

/// 状態の列を持つ行（予定・見張り）。取り消しと、終えた行を消す処理が共有する
protocol StatefulRow: FetchableRecord, MutablePersistableRecord {
    var id: Int64? { get }
    var state: String { get set }
    var updatedAt: Date { get set }
}

extension Store.WakeRow: StatefulRow {}
extension Store.WatchRow: StatefulRow {}

extension Store {
    /// 終えた予定・見張りと、届けた知らせを残す期間
    static let finishedRowRetention: TimeInterval = 7 * 24 * 3600

    /// `live` の状態の行だけを `cancelled` にして、書いた後の行を返す（`changed` は呼び手が流す）。それ以外の状態は断る
    func cancel<Row: StatefulRow>(
        _ type: Row.Type, id: Int64, notFound: StoreError, label: String, live: String, cancelled: String, now: Date, _ change: (inout Row) -> Void = { _ in }
    ) throws -> Row {
        try database.write { db in
            guard var row = try Row.fetchOne(db, key: id) else { throw notFound }
            guard row.state == live else { throw StoreError.conflict("\(label) #\(id) は \(row.state)（取り消せるのは \(live) だけ）") }
            row.state = cancelled
            row.updatedAt = now
            change(&row)
            try row.update(db)
            return row
        }
    }

    /// `live` でない状態のまま `cutoff` より前に更新された行を消し、消した行の id を返す。表名は `Row` の型が決め、列名は固定
    static func purgeFinished<Row: StatefulRow>(_ type: Row.Type, live: String, before cutoff: Date, _ db: Database) throws -> [Int64] {
        let finished = "FROM \(Row.databaseTableName) WHERE state != ? AND updatedAt < ?"
        let ids = try Int64.fetchAll(db, sql: "SELECT id \(finished)", arguments: [live, cutoff])
        try db.execute(sql: "DELETE \(finished)", arguments: [live, cutoff])
        return ids
    }
}
