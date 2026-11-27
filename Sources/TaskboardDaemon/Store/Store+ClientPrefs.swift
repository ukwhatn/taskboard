import Foundation
import GRDB
import TaskboardKit

/// 端末（アプリ）の設定の写し（`clientPrefs` 表）。真実源は各端末の UserDefaults で、daemon は端末が報告した値と MCP が書いた値を持つ。
/// 値は項目ごとに書いた側の時刻を持ち、新しい方を採る（端末は自分より新しい値だけを反映する）
extension Store {
    static let clientPrefsMigration = "v52 client prefs"

    static func registerClientPrefsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(clientPrefsMigration) { db in
            try db.create(table: "clientPrefs") { t in
                t.primaryKey("clientId", .text)
                t.column("name", .text).notNull()
                t.column("platform", .text).notNull()
                // 項目のキー → `ClientPrefEntry` の JSON
                t.column("prefValues", .text).notNull()
                t.column("reportedAt", .datetime).notNull()
            }
        }
    }

    public func clientPrefs() throws -> [ClientPrefs] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT clientId, name, platform, prefValues, reportedAt FROM clientPrefs ORDER BY name, clientId").compactMap(Self.clientPrefs)
        }
    }

    /// 項目ごとに新しい方を重ねて保存し、重ねた後の値と、変わったかを返す。名前と種類の無い報告（MCP の書き込み）は、端末の報告が無ければ断る
    public func mergeClientPrefs(id: String, _ report: ClientPrefsReport, now: Date = Date()) throws -> (prefs: ClientPrefs, changed: Bool) {
        guard !id.isEmpty, id.count <= 64 else { throw StoreError.invalid("端末の id が不正") }
        for (key, entry) in report.values {
            guard let pref = ClientPref(rawValue: key) else { throw StoreError.invalid(Copy.text("agent.prefs.unknown", ["key": key])) }
            if let problem = pref.problem(entry.value) { throw StoreError.invalid(problem) }
        }
        return try database.write { db in
            let current = try Row.fetchOne(db, sql: "SELECT clientId, name, platform, prefValues, reportedAt FROM clientPrefs WHERE clientId = ?", arguments: [id])
                .flatMap(Self.clientPrefs)
            let isReport = report.name != nil
            guard current != nil || isReport, let base = current ?? report.platform.map({ ClientPrefs(clientID: id, name: report.name ?? id, platform: $0, values: [:], reportedAt: now) }) else {
                throw StoreError.refused(.notFound, ["kind": "client"], "端末 \(id) の報告が無い")
            }
            var merged = base.merging(report.values)
            if let name = report.name { merged.name = name }
            if let platform = report.platform { merged.platform = platform }
            if isReport { merged.reportedAt = now }
            let changed = merged.values != current?.values || merged.name != current?.name || merged.platform != current?.platform
            let values = String(decoding: try JSONEncoder().encode(merged.values), as: UTF8.self)
            try db.execute(
                sql: """
                    INSERT INTO clientPrefs (clientId, name, platform, prefValues, reportedAt) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(clientId) DO UPDATE SET name = excluded.name, platform = excluded.platform, prefValues = excluded.prefValues, reportedAt = excluded.reportedAt
                    """,
                arguments: [id, merged.name, merged.platform.rawValue, values, merged.reportedAt])
            return (merged, changed)
        }
    }

    private static func clientPrefs(_ row: Row) -> ClientPrefs? {
        guard let platform = DevicePlatform(rawValue: row["platform"]),
            let values = try? JSONDecoder().decode([String: ClientPrefEntry].self, from: Data((row["prefValues"] as String).utf8))
        else { return nil }
        return ClientPrefs(clientID: row["clientId"], name: row["name"], platform: platform, values: values, reportedAt: row["reportedAt"])
    }
}
