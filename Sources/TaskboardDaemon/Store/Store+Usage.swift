import Foundation
import GRDB
import TaskboardKit

/// 利用状況の記録（`UsageRecorder` が書き、`GET /v1/usage/history` が集める）。時刻は UNIX 秒の整数で持ち、区切りは割り算で作る。
/// 90 日（`UsageHistory.retention`）より古いものは `pruneUsage` が消す
extension Store {
    static func registerUsageMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v31 usage analytics") { db in
            // 5 分ごとの利用枠（その間の大きいほう）と、その間に応答したセッションの数
            try db.create(table: "usageSample") { t in
                t.primaryKey("at", .integer)
                t.column("claudeFiveHour", .double)
                t.column("claudeSevenDay", .double)
                t.column("codexPrimary", .double)
                t.column("codexPrimaryWindow", .integer)
                t.column("codexSecondary", .double)
                t.column("codexSecondaryWindow", .integer)
                t.column("codexMonthly", .double)
                t.column("claudeActive", .integer).notNull().defaults(to: 0)
                t.column("codexActive", .integer).notNull().defaults(to: 0)
            }
            // 1 時間・セッション・model ごとのトークン
            try db.create(table: "usageToken") { t in
                t.column("hour", .integer).notNull()
                t.column("engine", .text).notNull()
                t.column("session", .text).notNull()
                t.column("model", .text).notNull()
                t.column("requests", .integer).notNull()
                t.column("input", .integer).notNull()
                t.column("cacheWrite", .integer).notNull()
                t.column("cacheRead", .integer).notNull()
                t.column("output", .integer).notNull()
                t.primaryKey(["hour", "engine", "session", "model"])
            }
            // skill の発火（kind = skill。name は skill の名前、source は model・command）と圧縮（kind = compaction。name は auto・manual か空）
            try db.create(table: "usageEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .integer).notNull()
                t.column("engine", .text).notNull()
                t.column("session", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("source", .text)
                t.column("before", .integer)
                t.column("after", .integer)
            }
            try db.create(index: "usageEvent_kind_at", on: "usageEvent", columns: ["kind", "at"])
            try db.create(table: "usageSession") { t in
                t.column("engine", .text).notNull()
                t.column("session", .text).notNull()
                t.column("cwd", .text)
                t.column("title", .text)
                t.column("firstAt", .integer)
                t.column("lastAt", .integer)
                t.column("maxContext", .integer)
                t.primaryKey(["engine", "session"])
            }
            // transcript ごとに読み終えた位置と、続きを読むのに要る値
            try db.create(table: "usageCursor") { t in
                t.primaryKey("path", .text)
                t.column("inode", .integer).notNull()
                t.column("offset", .integer).notNull()
                t.column("countFrom", .integer)
                t.column("model", .text)
                t.column("lastMessageId", .text)
                t.column("lastTotal", .integer)
                t.column("lastContext", .integer)
            }
        }
    }

    /// transcript ごとの読んだ位置の全部（パスが鍵）
    func usageCursors() throws -> [String: UsageCursor] {
        try database.read { db in
            var cursors: [String: UsageCursor] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM usageCursor") {
                cursors[row["path"]] = UsageCursor(
                    inode: UInt64(row["inode"] as Int64), offset: UInt64(row["offset"] as Int64),
                    countFrom: (row["countFrom"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    model: row["model"], lastMessageID: row["lastMessageId"], lastTotal: row["lastTotal"], lastContext: row["lastContext"])
            }
            return cursors
        }
    }

    /// 1 回の見回りの分を 1 つの transaction で書く。読んだ位置も同じ transaction で進めるので、落ちても同じ行を 2 回数えない
    func recordUsage(_ batch: UsageBatch) throws {
        try database.write { db in
            for token in batch.tokens {
                try db.execute(
                    sql: """
                        INSERT INTO usageToken (hour, engine, session, model, requests, input, cacheWrite, cacheRead, output) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hour, engine, session, model) DO UPDATE SET requests = requests + excluded.requests, input = input + excluded.input,
                          cacheWrite = cacheWrite + excluded.cacheWrite, cacheRead = cacheRead + excluded.cacheRead, output = output + excluded.output
                        """,
                    arguments: [
                        token.hour, token.engine.rawValue, token.session, token.model, token.requests, token.tokens.input, token.tokens.cacheWrite,
                        token.tokens.cacheRead, token.tokens.output,
                    ])
            }
            for event in batch.events {
                try db.execute(
                    sql: "INSERT INTO usageEvent (at, engine, session, kind, name, source, before, after) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    arguments: [event.at, event.engine.rawValue, event.session, event.kind.rawValue, event.name, event.source, event.before, event.after])
            }
            for session in batch.sessions {
                try db.execute(
                    sql: """
                        INSERT INTO usageSession (engine, session, cwd, title, firstAt, lastAt, maxContext) VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(engine, session) DO UPDATE SET cwd = COALESCE(excluded.cwd, cwd), title = COALESCE(excluded.title, title),
                          firstAt = MIN(COALESCE(firstAt, excluded.firstAt), COALESCE(excluded.firstAt, firstAt)),
                          lastAt = MAX(COALESCE(lastAt, excluded.lastAt), COALESCE(excluded.lastAt, lastAt)),
                          maxContext = MAX(COALESCE(maxContext, excluded.maxContext), COALESCE(excluded.maxContext, maxContext))
                        """,
                    arguments: [
                        session.engine.rawValue, session.session, session.cwd, session.title, session.firstAt, session.lastAt, session.maxContext,
                    ])
            }
            for sample in batch.samples {
                try db.execute(
                    sql: """
                        INSERT INTO usageSample (at, claudeFiveHour, claudeSevenDay, codexPrimary, codexPrimaryWindow, codexSecondary, codexSecondaryWindow,
                          codexMonthly, claudeActive, codexActive) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(at) DO UPDATE SET
                          claudeFiveHour = MAX(COALESCE(claudeFiveHour, excluded.claudeFiveHour), COALESCE(excluded.claudeFiveHour, claudeFiveHour)),
                          claudeSevenDay = MAX(COALESCE(claudeSevenDay, excluded.claudeSevenDay), COALESCE(excluded.claudeSevenDay, claudeSevenDay)),
                          codexPrimary = MAX(COALESCE(codexPrimary, excluded.codexPrimary), COALESCE(excluded.codexPrimary, codexPrimary)),
                          codexPrimaryWindow = COALESCE(excluded.codexPrimaryWindow, codexPrimaryWindow),
                          codexSecondary = MAX(COALESCE(codexSecondary, excluded.codexSecondary), COALESCE(excluded.codexSecondary, codexSecondary)),
                          codexSecondaryWindow = COALESCE(excluded.codexSecondaryWindow, codexSecondaryWindow),
                          codexMonthly = MAX(COALESCE(codexMonthly, excluded.codexMonthly), COALESCE(excluded.codexMonthly, codexMonthly)),
                          claudeActive = MAX(claudeActive, excluded.claudeActive), codexActive = MAX(codexActive, excluded.codexActive)
                        """,
                    arguments: [
                        Int64(sample.at.timeIntervalSince1970), sample.claudeFiveHour, sample.claudeSevenDay, sample.codexPrimary, sample.codexPrimaryWindow, sample.codexSecondary,
                        sample.codexSecondaryWindow, sample.codexMonthly, sample.claudeActive, sample.codexActive,
                    ])
            }
            for (path, cursor) in batch.cursors {
                try db.execute(
                    sql: """
                        INSERT INTO usageCursor (path, inode, offset, countFrom, model, lastMessageId, lastTotal, lastContext) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET inode = excluded.inode, offset = excluded.offset, countFrom = excluded.countFrom, model = excluded.model,
                          lastMessageId = excluded.lastMessageId, lastTotal = excluded.lastTotal, lastContext = excluded.lastContext
                        """,
                    arguments: [
                        path, Int64(cursor.inode), Int64(cursor.offset), cursor.countFrom.map { Int64($0.timeIntervalSince1970) }, cursor.model,
                        cursor.lastMessageID, cursor.lastTotal, cursor.lastContext,
                    ])
            }
        }
    }

    /// `before` より古い記録と、無くなった transcript の読んだ位置を消す
    func pruneUsage(before date: Date, missingPaths: [String]) throws {
        let cutoff = Int64(date.timeIntervalSince1970)
        try database.write { db in
            try db.execute(sql: "DELETE FROM usageSample WHERE at < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM usageToken WHERE hour < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM usageEvent WHERE at < ?", arguments: [cutoff])
            try db.execute(sql: "DELETE FROM usageSession WHERE COALESCE(lastAt, 0) < ?", arguments: [cutoff])
            for path in missingPaths {
                try db.execute(sql: "DELETE FROM usageCursor WHERE path = ?", arguments: [path])
            }
        }
    }

    public func usageHistory(_ query: UsageHistoryQuery) throws -> UsageHistory {
        let from = Int64(query.from.timeIntervalSince1970), to = Int64(query.to.timeIntervalSince1970)
        let bucket = Int64(query.bucketSeconds)
        let tokenBucket = max(bucket, Int64(UsageHistory.tokenSeconds))
        func date(_ seconds: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
        func engine(_ raw: String) -> AgentKind { AgentKind(rawValue: raw) ?? .claude }
        func counts(_ row: Row) -> TokenCounts {
            TokenCounts(input: row["input"], cacheWrite: row["cacheWrite"], cacheRead: row["cacheRead"], output: row["output"])
        }
        return try database.read { db in
            let since = try Int64.fetchOne(db, sql: "SELECT MIN(at) FROM usageSample")
            let samples = try Row.fetchAll(
                db,
                sql: """
                    SELECT (at / ?) * ? AS t, MAX(claudeFiveHour) AS c5, MAX(claudeSevenDay) AS c7, MAX(codexPrimary) AS xp, MAX(codexPrimaryWindow) AS xpw,
                      MAX(codexSecondary) AS xs, MAX(codexSecondaryWindow) AS xsw, MAX(codexMonthly) AS xm, MAX(claudeActive) AS ca, MAX(codexActive) AS xa
                    FROM usageSample WHERE at >= ? AND at < ? GROUP BY t ORDER BY t
                    """, arguments: [bucket, bucket, from, to]
            ).map { row in
                UsageHistory.Sample(
                    at: date(row["t"]), claudeFiveHour: row["c5"], claudeSevenDay: row["c7"], codexPrimary: row["xp"], codexPrimaryWindow: row["xpw"],
                    codexSecondary: row["xs"], codexSecondaryWindow: row["xsw"], codexMonthly: row["xm"], claudeActive: row["ca"], codexActive: row["xa"])
            }
            let hourFrom = (from / 3600) * 3600
            let tokens = try Row.fetchAll(
                db,
                sql: """
                    SELECT (hour / ?) * ? AS t, engine, model, SUM(requests) AS requests, SUM(input) AS input, SUM(cacheWrite) AS cacheWrite,
                      SUM(cacheRead) AS cacheRead, SUM(output) AS output
                    FROM usageToken WHERE hour >= ? AND hour < ? GROUP BY t, engine, model ORDER BY t
                    """, arguments: [tokenBucket, tokenBucket, hourFrom, to]
            ).map { row in
                UsageHistory.TokenBucket(at: date(row["t"]), engine: engine(row["engine"]), model: row["model"], requests: row["requests"], tokens: counts(row))
            }
            let skills = try Row.fetchAll(
                db,
                sql: """
                    SELECT engine, name, source, COUNT(*) AS n, MAX(at) AS last FROM usageEvent WHERE kind = 'skill' AND at >= ? AND at < ?
                    GROUP BY engine, name, source ORDER BY n DESC, name
                    """, arguments: [from, to]
            ).map { row in
                UsageHistory.SkillCount(
                    engine: engine(row["engine"]), name: row["name"], source: UsageHistory.SkillSource(rawValue: row["source"] ?? "") ?? .model, count: row["n"],
                    lastAt: date(row["last"]))
            }
            let compactions = try Row.fetchAll(
                db,
                sql: """
                    SELECT at, engine, session, name, before, after FROM usageEvent WHERE kind = 'compaction' AND at >= ? AND at < ?
                    ORDER BY at DESC LIMIT ?
                    """, arguments: [from, to, UsageHistory.compactionLimit]
            ).map { row in
                UsageHistory.Compaction(
                    at: date(row["at"]), engine: engine(row["engine"]), session: row["session"],
                    trigger: UsageHistory.Compaction.Trigger(rawValue: row["name"] ?? ""), before: row["before"], after: row["after"])
            }.reversed()
            let compactionCounts = Dictionary(
                try Row.fetchAll(
                    db, sql: "SELECT engine, session, COUNT(*) AS n FROM usageEvent WHERE kind = 'compaction' AND at >= ? AND at < ? GROUP BY engine, session",
                    arguments: [from, to]
                ).map { (($0["engine"] as String) + "\u{0}" + ($0["session"] as String), $0["n"] as Int) }, uniquingKeysWith: +)
            let sessions = try Row.fetchAll(
                db,
                sql: """
                    SELECT t.engine, t.session, SUM(t.requests) AS requests, SUM(t.input) AS input, SUM(t.cacheWrite) AS cacheWrite,
                      SUM(t.cacheRead) AS cacheRead, SUM(t.output) AS output, MAX(t.hour) AS last, s.cwd, s.title, s.maxContext
                    FROM usageToken t LEFT JOIN usageSession s ON s.engine = t.engine AND s.session = t.session
                    WHERE t.hour >= ? AND t.hour < ? GROUP BY t.engine, t.session
                    ORDER BY SUM(t.input + t.cacheWrite + t.cacheRead + t.output) DESC LIMIT ?
                    """, arguments: [hourFrom, to, UsageHistory.sessionLimit]
            ).map { row in
                let kind = engine(row["engine"])
                let session: String = row["session"]
                return UsageHistory.SessionTotal(
                    engine: kind, session: session, cwd: row["cwd"], title: row["title"], requests: row["requests"], tokens: counts(row),
                    maxContext: row["maxContext"], compactions: compactionCounts[kind.rawValue + "\u{0}" + session] ?? 0, lastAt: date(row["last"]))
            }
            let sessionCount =
                try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM (SELECT DISTINCT engine, session FROM usageToken WHERE hour >= ? AND hour < ?)", arguments: [hourFrom, to])
                ?? 0
            return UsageHistory(
                from: query.from, to: query.to, bucketSeconds: query.bucketSeconds, recordingSince: since.map(date), samples: samples, tokens: tokens,
                skills: skills, compactions: Array(compactions), sessions: sessions, sessionCount: sessionCount)
        }
    }
}
