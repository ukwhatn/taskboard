import Foundation
import GRDB
import TaskboardKit

/// ペアリングした端末（`device` 表）。token は SHA-256 の hex だけを持つ。止めた端末は行を消す
extension Store {
    static func registerDeviceMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9 paired devices") { db in
            try db.create(table: "device") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("platform", .text).notNull()
                t.column("tokenHash", .text).notNull().unique()
                t.column("createdAt", .datetime).notNull()
                t.column("lastSeenAt", .datetime)
            }
        }
    }

    /// APNs の登録（`PushRegistration`）。token が null なら登録していない
    static func registerDevicePushMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13 device push") { db in
            try db.alter(table: "device") { t in
                t.add(column: "pushToken", .text)
                t.add(column: "pushEnvironment", .text)
                t.add(column: "pushTopic", .text)
                t.add(column: "pushKinds", .text)
                t.add(column: "pushSound", .boolean)
                t.add(column: "pushMachineName", .text)
                t.add(column: "pushConnection", .text)
                t.add(column: "pushRegisteredAt", .datetime)
            }
        }
    }

    public struct DeviceRecord: Sendable, Hashable {
        public var info: DeviceInfo
        public var tokenHash: String
    }

    public func devices() throws -> [DeviceRecord] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, platform, tokenHash, createdAt, lastSeenAt FROM device ORDER BY createdAt, id").map { row in
                DeviceRecord(
                    info: DeviceInfo(
                        id: row["id"], name: row["name"], platform: DevicePlatform(rawValue: row["platform"]) ?? .ios,
                        createdAt: row["createdAt"], lastSeenAt: row["lastSeenAt"]),
                    tokenHash: row["tokenHash"])
            }
        }
    }

    public func insertDevice(_ device: DeviceInfo, tokenHash: String) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO device (id, name, platform, tokenHash, createdAt, lastSeenAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [device.id, device.name, device.platform.rawValue, tokenHash, device.createdAt, device.lastSeenAt])
        }
    }

    /// 行が無ければ false
    public func deleteDevice(id: String) throws -> Bool {
        try database.write { db in
            try db.execute(sql: "DELETE FROM device WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    public func touchDevice(id: String, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE device SET lastSeenAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    /// APNs の登録のある端末
    public struct PushTarget: Sendable, Hashable {
        public var deviceID: String
        public var deviceName: String
        public var registration: PushRegistration
        public var registeredAt: Date
    }

    public func pushTargets() throws -> [PushTarget] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, pushToken, pushEnvironment, pushTopic, pushKinds, pushSound, pushMachineName, pushConnection, pushRegisteredAt
                    FROM device WHERE pushToken IS NOT NULL ORDER BY createdAt, id
                    """
            ).compactMap { row in
                guard let environment = PushEnvironment(rawValue: row["pushEnvironment"] ?? "") else { return nil }
                let words = (row["pushKinds"] as String? ?? "").split(separator: ",").map(String.init)
                let kinds = words.compactMap(NotifyKind.init(rawValue:))
                let turns = words.lazy.compactMap { $0.hasPrefix(Self.turnsPrefix) ? TurnNotify(rawValue: String($0.dropFirst(Self.turnsPrefix.count))) : nil }.first
                return PushTarget(
                    deviceID: row["id"], deviceName: row["name"],
                    registration: PushRegistration(
                        token: row["pushToken"], environment: environment, topic: row["pushTopic"] ?? "", kinds: kinds, turns: turns, sound: row["pushSound"] ?? false,
                        machineName: row["pushMachineName"] ?? "", connection: row["pushConnection"] ?? ""),
                    registeredAt: row["pushRegisteredAt"] ?? .distantPast)
            }
        }
    }

    /// pushKinds の列の中のターンの完了の通知の語（`turns=background`）。列を足さずに持つ。古い daemon は種類として読めない語を捨てる
    static let turnsPrefix = "turns="

    static func pushKindsColumn(_ registration: PushRegistration) -> String {
        (registration.kinds.map(\.rawValue) + (registration.turns.map { [turnsPrefix + $0.rawValue] } ?? [])).joined(separator: ",")
    }

    /// 端末の登録を置き換える。同じトークンを別の端末の行が持っていたら、そちらの登録を消す（同じ iPhone をペアリングし直したとき 2 通届かないように）。
    /// 端末の行が無ければ false
    public func setPushRegistration(deviceID: String, _ registration: PushRegistration, at date: Date) throws -> Bool {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE device SET pushToken = ?, pushEnvironment = ?, pushTopic = ?, pushKinds = ?, pushSound = ?, pushMachineName = ?,
                    pushConnection = ?, pushRegisteredAt = ? WHERE id = ?
                    """,
                arguments: [
                    registration.token, registration.environment.rawValue, registration.topic, Self.pushKindsColumn(registration),
                    registration.sound, registration.machineName, registration.connection, date, deviceID,
                ])
            guard db.changesCount > 0 else { return false }
            try db.execute(sql: "UPDATE device SET \(Self.clearPushColumns) WHERE pushToken = ? AND id != ?", arguments: [registration.token, deviceID])
            return true
        }
    }

    /// 端末の登録を消す。`token` を渡したら、そのトークンのままのときだけ消す（送っている間に登録し直した新しいトークンを消さない）。
    /// 消したら true
    @discardableResult
    public func clearPushRegistration(deviceID: String, token: String? = nil) throws -> Bool {
        try database.write { db in
            if let token {
                try db.execute(
                    sql: "UPDATE device SET \(Self.clearPushColumns) WHERE id = ? AND pushToken = ?", arguments: [deviceID, token])
            } else {
                try db.execute(sql: "UPDATE device SET \(Self.clearPushColumns) WHERE id = ? AND pushToken IS NOT NULL", arguments: [deviceID])
            }
            return db.changesCount > 0
        }
    }

    private static let clearPushColumns = """
        pushToken = NULL, pushEnvironment = NULL, pushTopic = NULL, pushKinds = NULL, pushSound = NULL, pushMachineName = NULL,
        pushConnection = NULL, pushRegisteredAt = NULL
        """
}
