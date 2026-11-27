import Foundation
import TaskboardKit

/// 設定画面の値（`ClientPref`）を、接続しているすべての daemon に写す。MCP が daemon に書いた値は、ここで受けてこの端末の設定にする。
/// 真実源はこの端末の UserDefaults。項目ごとに書いた時刻を持ち、daemon の値がこの端末の値より新しいときだけ採る。
/// 送るかは見回り（`Notifications` の 2 秒ごと）のたびに今の中身と前に送った中身を比べて決める（`PushCenter` と同じ）。
/// fixtures・debug の口・test host のアプリ（`AppDefaults.isScratch`）は送らない（確かめるアプリが本物の daemon に偽の端末を残す）
@MainActor
final class ClientPrefsSync {
    static let shared = ClientPrefsSync()

    private static let clientIDKey = "prefs.clientID"
    private static let stampsKey = "prefs.stamps"

    private var defaults: UserDefaults { AppDefaults.store }
    /// 前の見回りで読んだ値。変わった項目だけ時刻を付け直す
    private var lastValues: [String: ClientPrefValue]?
    /// 接続先ごとに、最後に受け付けられた中身と、そのときの接続の回数
    private var sent: [String: (report: [String: ClientPrefEntry], connection: Int)] = [:]
    private var inFlight: Set<String> = []

    var clientID: String {
        if let id = defaults.string(forKey: Self.clientIDKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.clientIDKey)
        return id
    }

    /// daemon の値をこの端末に反映したら true（`AppModel` が持つ値を読み直す）
    @discardableResult
    func tick(fleet: Fleet) -> Bool {
        guard !AppDefaults.isScratch else { return false }
        var adopted = false
        let entries = stampedEntries()
        for (fleetID, state) in fleet.allMachines where state.connected {
            if let remote = state.clientPrefs[clientID], adopt(remote) { adopted = true }
            guard let writer = fleet.writer(fleetID: fleetID), !inFlight.contains(fleetID) else { continue }
            if let last = sent[fleetID], last.report == entries, last.connection == state.connection { continue }
            send(entries, to: writer, fleetID: fleetID, connection: state.connection)
        }
        return adopted
    }

    private func send(_ entries: [String: ClientPrefEntry], to writer: any DaemonWriter, fleetID: String, connection: Int) {
        inFlight.insert(fleetID)
        let report = ClientPrefsReport(name: AppModel.deviceName, platform: AppModel.devicePlatform, values: entries)
        let id = clientID
        Task {
            defer { inFlight.remove(fleetID) }
            do {
                let merged = try await writer.reportClientPrefs(id: id, report)
                sent[fleetID] = (entries, connection)
                _ = adopt(merged)
            } catch {
                // 古い daemon（口が無い 404）と繋がらないときは、接続し直すか中身が変わるまで送らない
                sent[fleetID] = (entries, connection)
            }
        }
    }

    /// daemon の値のうち、この端末の値より新しいものをこの端末の設定にする。次の見回りで、ほかの daemon にも同じ時刻で送られる
    private func adopt(_ remote: ClientPrefs) -> Bool {
        var stamps = storedStamps()
        var changed = false
        for pref in ClientPref.allCases {
            guard let entry = remote.values[pref.rawValue], entry.at > (stamps[pref.rawValue] ?? .distantPast) else { continue }
            if pref.problem(entry.value) == nil, read(pref) != entry.value { write(entry.value, for: pref) }
            stamps[pref.rawValue] = entry.at
            lastValues?[pref.rawValue] = read(pref)
            changed = true
        }
        if changed { store(stamps) }
        return changed
    }

    /// 今の値に時刻を付けたもの。前の見回りから変わった項目と、まだ時刻の無い項目は今の時刻にする
    private func stampedEntries() -> [String: ClientPrefEntry] {
        var stamps = storedStamps()
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        var values: [String: ClientPrefValue] = [:]
        var entries: [String: ClientPrefEntry] = [:]
        var restamped = false
        for pref in ClientPref.allCases {
            guard let value = read(pref) else { continue }
            values[pref.rawValue] = value
            if stamps[pref.rawValue] == nil || (lastValues != nil && lastValues?[pref.rawValue] != value) {
                stamps[pref.rawValue] = now
                restamped = true
            }
            entries[pref.rawValue] = ClientPrefEntry(value: value, at: stamps[pref.rawValue] ?? now)
        }
        lastValues = values
        if restamped { store(stamps) }
        return entries
    }

    private func storedStamps() -> [String: Date] {
        (defaults.dictionary(forKey: Self.stampsKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func store(_ stamps: [String: Date]) {
        defaults.set(stamps.mapValues(\.timeIntervalSince1970), forKey: Self.stampsKey)
    }

    /// 未設定の項目は送らない（daemon には「アプリの既定」と出る）
    private func read(_ pref: ClientPref) -> ClientPrefValue? {
        guard let object = defaults.object(forKey: pref.rawValue) else { return nil }
        switch pref.kind {
        case .bool: return (object as? Bool).map(ClientPrefValue.bool)
        case .number: return (object as? Double).map(ClientPrefValue.number)
        case .string: return (object as? String).map(ClientPrefValue.string)
        case .strings: return (object as? [String]).map(ClientPrefValue.strings)
        }
    }

    private func write(_ value: ClientPrefValue, for pref: ClientPref) {
        switch value {
        case .bool(let bool): defaults.set(bool, forKey: pref.rawValue)
        case .number(let number): defaults.set(number, forKey: pref.rawValue)
        case .string(let text): defaults.set(text, forKey: pref.rawValue)
        case .strings(let items): defaults.set(items, forKey: pref.rawValue)
        }
    }
}
