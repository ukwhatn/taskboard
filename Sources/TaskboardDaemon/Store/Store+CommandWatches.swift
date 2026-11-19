import Foundation
import GRDB
import TaskboardKit

/// コマンドの見張り（`Watch.Kind.command`）の記録。動かすのは `CommandWatcher`、届けるのは `WatchNotices`
extension Store {
    static let commandWatchMigration = "v36 command watches"
    /// 有効な command の見張りの数の上限（1 つずつがプロセスを起こすので、増えすぎないように）
    static let commandWatchLimit = 20

    static func registerCommandWatchMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(commandWatchMigration) { db in
            try db.alter(table: "watch") { t in
                // `CommandWatchSpec` の JSON。前の回の様子は `snapshot` に `CommandWatchState` の JSON
                t.add(column: "command", .text)
            }
        }
    }

    /// 前の回の様子
    struct CommandWatchState: Codable, Hashable, Sendable {
        /// 前の回が条件に合ったか（合っていない状態から合ったときだけ届ける）
        var matched: Bool?
        /// `changes` の前の回の出力と終了コードの digest
        var digest: String?
        /// `finishes` を動かし始めた時刻（daemon が途中で起き直したら、結果が分からないので届けて終える）
        var startedAt: Date?
    }

    /// 1 回の結果。`watchEvent.notice` に JSON で持つ
    struct CommandWatchResult: Codable, Hashable, Sendable {
        var exitCode: Int32?
        var timedOut = false
        /// daemon が途中で起き直して、`finishes` の結果が分からない
        var interrupted = false
        var seconds: Int = 0
        /// 出力の末尾（`outputTailLimit` 字まで）
        var outputTail: String = ""
        /// 持つ量を超えて捨てた出力があった
        var truncated = false
        /// `matches` で合った最初の行
        var matchedLine: String?

        static let outputTailLimit = 2_000
    }

    struct CommandEventRecord: Hashable, Sendable {
        var id: Int64
        var result: CommandWatchResult
        var createdAt: Date
    }

    /// 長さ・形・範囲を確かめ、`cwd` を絶対パスにそろえた写しを返す
    static func validCommand(_ spec: CommandWatchSpec) throws -> CommandWatchSpec {
        var spec = spec
        spec.command = spec.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.command.isEmpty, spec.command.utf8.count <= CommandWatchSpec.commandLimit else {
            throw StoreError.invalid("command が空か \(CommandWatchSpec.commandLimit) バイトを超える")
        }
        if let cwd = spec.cwd?.trimmingCharacters(in: .whitespaces), !cwd.isEmpty {
            var isDirectory: ObjCBool = false
            guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw StoreError.invalid("cwd \(cwd) は在るディレクトリの絶対パスにする")
            }
            spec.cwd = cwd
        } else {
            spec.cwd = nil
        }
        let pattern = spec.pattern?.nilIfBlank
        switch spec.condition {
        case .matches:
            guard let pattern, pattern.count <= CommandWatchSpec.patternLimit else {
                throw StoreError.invalid("matches には \(CommandWatchSpec.patternLimit) 字までの pattern（正規表現）を渡す")
            }
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw StoreError.invalid("pattern \(pattern) を正規表現として読めない") }
            spec.pattern = pattern
        default:
            guard pattern == nil else { throw StoreError.invalid("pattern は matches だけ") }
            spec.pattern = nil
        }
        if spec.condition == .finishes {
            guard spec.intervalSeconds == nil else { throw StoreError.invalid("interval_seconds は finishes では使えない（1 回だけ動かす）") }
        } else if let interval = spec.intervalSeconds, !CommandWatchSpec.intervals.contains(interval) {
            throw StoreError.invalid("interval_seconds は \(CommandWatchSpec.intervals.lowerBound)〜\(CommandWatchSpec.intervals.upperBound)")
        }
        let limit = spec.condition == .finishes ? CommandWatchSpec.finishTimeouts.limit : CommandWatchSpec.checkTimeouts.limit
        if let timeout = spec.timeoutSeconds, !(1...limit).contains(timeout) { throw StoreError.invalid("timeout_seconds は 1〜\(limit)") }
        return spec
    }

    /// 有効な command の見張り（古い順）
    func activeCommandWatches() throws -> [WatchRow] {
        try database.read { db in
            try WatchRow.filter(Column("state") == Watch.State.active.rawValue && Column("kind") == Watch.Kind.command.rawValue).order(Column("id")).fetchAll(db)
        }
    }

    /// 前の回の様子。まだ動かしていなければ nil
    func commandWatchState(_ row: WatchRow) -> CommandWatchState? {
        row.snapshot.flatMap { try? JSONDecoder().decode(CommandWatchState.self, from: Data($0.utf8)) }
    }

    /// 回の結果を書く（1 つの transaction）。`result` があれば出来事にする。`checked` が false なら取った時刻を動かさない（`finishes` を始めたとき）。
    /// 有効な見張りに出来事を足したら true
    @discardableResult
    func recordCommandCheck(id: Int64, state: CommandWatchState, result: CommandWatchResult?, checked: Bool = true, at now: Date) throws -> Bool {
        let encoder = JSONEncoder()
        let (touched, shown): (Bool, Bool) = try database.write { db in
            guard var row = try WatchRow.fetchOne(db, key: id), row.stateValue == .active, row.kind == Watch.Kind.command.rawValue else { return (false, false) }
            let before = row
            if let result {
                try db.execute(
                    sql: "INSERT INTO watchEvent (watchId, kind, notice, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [id, Watch.Kind.command.rawValue, String(decoding: try encoder.encode(result), as: UTF8.self), now])
            }
            row.snapshot = String(decoding: try encoder.encode(state), as: UTF8.self)
            if checked {
                row.fetchedAt = now
                row.error = nil
            }
            let shown = !row.sameShown(as: before)
            if shown { row.updatedAt = now }
            try row.update(db)
            return (result != nil, shown)
        }
        if shown { changed(.watch(id)) }
        return touched
    }

    /// 届けていない回の結果（古い順、全部）
    func undeliveredCommandEvents(watch id: Int64) throws -> [CommandEventRecord] {
        try database.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(
                db, sql: "SELECT id, notice, createdAt FROM watchEvent WHERE watchId = ? AND deliveredAt IS NULL ORDER BY createdAt, id", arguments: [id]
            ).map { row in
                CommandEventRecord(
                    id: row["id"], result: try decoder.decode(CommandWatchResult.self, from: Data((row["notice"] as String).utf8)), createdAt: row["createdAt"])
            }
        }
    }
}

extension JSONEncoder {
    /// 鍵の並びを決めて書く（同じ中身なら同じ文字列にして、同じ見張りを見分ける）
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

extension String {
    fileprivate var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
