import Foundation
import TaskboardKit

/// codex app-server の `plugin/list` の応答から、plugin の一覧と、入れる・外すときに渡す値を作る（0.162.1 で実測）。
/// codex は marketplace が決めたコマンドで入れる plugin を一覧に出さない（入れようとすると見つからない）ので、2 回の往復は無い
enum CodexPlugins {
    struct Entry {
        var plugin: ConversationPlugins.Plugin
        /// `plugin/install` の `pluginName`
        var pluginName: String
        /// ファイルの marketplace は `marketplacePath`、目録だけの marketplace（remote）は `remoteMarketplaceName` で入れる
        var marketplacePath: String?
    }

    static func entries(_ result: [String: Any]?) -> [Entry] {
        (result?["marketplaces"] as? [[String: Any]] ?? []).flatMap { market -> [Entry] in
            let marketplace = market["name"] as? String ?? ""
            let path = market["path"] as? String
            return (market["plugins"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                let interface = item["interface"] as? [String: Any]
                let installed = item["installed"] as? Bool ?? false
                let plugin = ConversationPlugins.Plugin(
                    id: id, name: name, marketplace: marketplace, description: (interface?["shortDescription"] ?? interface?["longDescription"]) as? String,
                    version: (item["localVersion"] ?? item["version"]) as? String, scope: installed ? "user" : nil, installed: installed,
                    enabled: installed ? item["enabled"] as? Bool : nil, source: (item["source"] as? [String: Any])?["type"] as? String)
                return Entry(plugin: plugin, pluginName: name, marketplacePath: path)
            }
        }
    }

    /// marketplace を外す前に外す、その marketplace の入れた plugin の id。形が違う（`marketplaces` が無い・項目に id や `installed` が無い）ときは
    /// 空とみなさず失敗にする（空とみなすと plugin を外さずに marketplace を外し、config と cache が取り残される）
    static func installedIDsForRemoval(_ result: [String: Any]?, marketplace: String) throws -> [String] {
        guard let markets = result?["marketplaces"] as? [Any] else { throw ConversationError.failed("plugin の一覧を読めない") }
        var ids: [String] = []
        for value in markets {
            guard let market = value as? [String: Any], let name = market["name"] as? String, let plugins = market["plugins"] as? [Any] else {
                throw ConversationError.failed("plugin の一覧を読めない")
            }
            for item in plugins {
                guard let plugin = item as? [String: Any], let id = plugin["id"] as? String, !id.isEmpty, let installed = plugin["installed"] as? Bool else {
                    throw ConversationError.failed("plugin の一覧を読めない")
                }
                if name == marketplace, installed { ids.append(id) }
            }
        }
        return ids
    }

    static func plugins(_ result: [String: Any]?, query: String?) -> ConversationPlugins {
        let all = entries(result).map(\.plugin)
        let filtered = ConversationPlugins.filtered(all.filter { !$0.installed }, query: query)
        let marketplaces = (result?["marketplaces"] as? [[String: Any]] ?? []).compactMap { market -> ConversationPlugins.Marketplace? in
            guard let name = market["name"] as? String else { return nil }
            return ConversationPlugins.Marketplace(name: name, source: market["path"] as? String)
        }
        return ConversationPlugins(installed: all.filter(\.installed), available: filtered.plugins, availableTotal: filtered.total, marketplaces: marketplaces)
    }

    /// `plugin/install` の params
    static func installParams(_ entry: Entry) -> [String: Any] {
        var params: [String: Any] = ["pluginName": entry.pluginName]
        if let path = entry.marketplacePath { params["marketplacePath"] = path } else { params["remoteMarketplaceName"] = entry.plugin.marketplace }
        return params
    }

    /// `plugin/install` の応答のうち、使う前にログインが要るアプリの名前
    static func appsNeedingAuth(_ result: [String: Any]?) -> [String]? {
        let names = (result?["appsNeedingAuth"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        return names.isEmpty ? nil : names
    }

    /// 有効と無効は `plugins."<id>".enabled`。id に点があると鍵が切れるので、`plugins` の表に `upsert` する（ほかの plugin の行は残る）
    static func enabled(_ id: String, _ enabled: Bool) -> CodexSettingsEdits.Write {
        CodexSettingsEdits.Write(edits: [["keyPath": "plugins", "value": [id: ["enabled": enabled]], "mergeStrategy": "upsert"]], effect: .now)
    }
}
