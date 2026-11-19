import Foundation
import GRDB
import TaskboardKit

/// マシン単位の設定（`setting` 表。キーごとに JSON を 1 行）。行が無いキーは `MachineSettings.defaults` の値
extension Store {
    static func registerSettingsMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8 settings and session launch args") { db in
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.alter(table: "taskSession") { t in
                t.add(column: "launchArgs", .text).notNull().defaults(to: "[]")
            }
            // 再開の起動は daemon が途中で落ちても同じ会話で起こし直す（引数の resume を記録から組み直す）
            try db.alter(table: "launch") { t in
                t.add(column: "resumeAgentSessionId", .text)
            }
        }
    }

    private enum SettingKey {
        static let orchestrator = "orchestrator"
        static let idleStopMinutes = "idleStopMinutes"
        static let usagePause = "usagePause"
    }

    public func settings() throws -> MachineSettings {
        try database.read { db in try Self.fetchSettings(db) }
    }

    /// 省略した項目は変えない。`idleStopMinutes` が `MachineSettings.idleStopChoices` に無いか、区切る使用率が `UsagePause.percentRange` の外なら `.invalid`
    public func updateSettings(_ update: MachineSettingsUpdate) throws -> MachineSettings {
        if let minutes = update.idleStopMinutes, !MachineSettings.idleStopChoices.contains(minutes) {
            let choices = MachineSettings.idleStopChoices.map(String.init).joined(separator: " / ")
            throw StoreError.invalid("idleStopMinutes は \(choices) のどれか: \(minutes)")
        }
        let range = MachineSettings.UsagePause.percentRange
        for (name, percent) in [("usagePauseFiveHourPercent", update.usagePauseFiveHourPercent), ("usagePauseSevenDayPercent", update.usagePauseSevenDayPercent)] {
            if let percent, !range.contains(percent) {
                throw StoreError.invalid("\(name) は \(range.lowerBound)〜\(range.upperBound): \(percent)")
            }
        }
        let settings = try database.write { db in
            var settings = try Self.fetchSettings(db)
            if let enabled = update.orchestratorEnabled { settings.orchestrator.enabled = enabled }
            if let args = update.orchestratorAgentArgs { settings.orchestrator.agentArgs = args }
            if let minutes = update.idleStopMinutes { settings.idleStopMinutes = minutes }
            if let percent = update.usagePauseFiveHourPercent { settings.usagePause.fiveHourPercent = percent }
            if let percent = update.usagePauseSevenDayPercent { settings.usagePause.sevenDayPercent = percent }
            try Self.saveSetting(db, key: SettingKey.orchestrator, value: settings.orchestrator)
            try Self.saveSetting(db, key: SettingKey.idleStopMinutes, value: settings.idleStopMinutes)
            try Self.saveSetting(db, key: SettingKey.usagePause, value: settings.usagePause)
            return settings
        }
        changed(.settings)
        return settings
    }

    private static func fetchSettings(_ db: Database) throws -> MachineSettings {
        var settings = MachineSettings.defaults
        if let orchestrator = try fetchSetting(db, key: SettingKey.orchestrator, as: MachineSettings.Orchestrator.self) {
            settings.orchestrator = orchestrator
        }
        if let minutes = try fetchSetting(db, key: SettingKey.idleStopMinutes, as: Int.self) { settings.idleStopMinutes = minutes }
        if let pause = try fetchSetting(db, key: SettingKey.usagePause, as: MachineSettings.UsagePause.self) { settings.usagePause = pause }
        return settings
    }

    /// 読めない値（手で壊した等）は既定に戻す。daemon の起動を止めない
    private static func fetchSetting<T: Decodable>(_ db: Database, key: String, as: T.Type) throws -> T? {
        guard let text = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static func saveSetting<T: Encodable>(_ db: Database, key: String, value: T) throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute(
            sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, text])
    }
}
