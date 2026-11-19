import Foundation
import TaskboardKit

/// 文書のリモートコンテンツ（外部のホストの画像・CSS・script）を読み込むと許したホスト。この端末で文書ごとに覚える。
/// 許した後の版でホストが増えたら、増えた分を許すまで止めて描く
enum DocumentRemoteContent {
    /// `hosts` を全部許してあるか（ホストの無い文書は許すものが無いので true）
    static func isAllowed(_ hosts: [String], for key: DocKey, in defaults: UserDefaults = AppDefaults.store) -> Bool {
        Set(hosts).isSubset(of: allowed(key, in: defaults))
    }

    static func allow(_ hosts: [String], for key: DocKey, in defaults: UserDefaults = AppDefaults.store) {
        var all = defaults.dictionary(forKey: AppPreferences.docRemoteHostsKey) as? [String: [String]] ?? [:]
        all[name(key)] = Array(allowed(key, in: defaults).union(hosts)).sorted()
        defaults.set(all, forKey: AppPreferences.docRemoteHostsKey)
    }

    private static func allowed(_ key: DocKey, in defaults: UserDefaults) -> Set<String> {
        let all = defaults.dictionary(forKey: AppPreferences.docRemoteHostsKey) as? [String: [String]] ?? [:]
        return Set(all[name(key)] ?? [])
    }

    private static func name(_ key: DocKey) -> String { "\(key.machine.rawValue)/\(key.id)" }
}
