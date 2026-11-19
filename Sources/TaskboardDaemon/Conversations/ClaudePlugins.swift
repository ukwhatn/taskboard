import CryptoKit
import Foundation
import TaskboardKit

/// plugin と marketplace の書き込みと一覧を `claude plugin` のサブコマンド（`--json`）に読み替える（2.1.304 で実測）。
/// 書き込みは stdout の最後の行に結果の JSON を 1 行出す（その前に人向けの文が出ることがある）。一覧は複数行の JSON
enum ClaudePlugins {
    /// CLI の引数に渡す名前・id・source。`-` で始まるものはオプションと読まれるので受けない。引数はシェルを通さないので、
    /// marketplace のパスの空白（`allowsSpaces`）は通す。改行と制御文字はどれも受けない
    static func token(_ value: String?, _ what: String, allowsSpaces: Bool = false) throws -> String {
        guard let value, !value.isEmpty, !value.hasPrefix("-"), value.utf8.count <= 2048,
            !value.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) || (!allowsSpaces && CharacterSet.whitespaces.contains($0))
            })
        else { throw ConversationError.invalid("\(what)が違う") }
        return value
    }

    static func scope(_ scope: ConversationSettingsScope) -> String {
        switch scope {
        case .user: "user"
        case .project: "project"
        case .local: "local"
        }
    }

    // MARK: 引数

    static func install(_ id: String, scope: ConversationSettingsScope?, acceptCommand: String?) -> [String] {
        ["plugin", "install", id, "--json"] + scopeArguments(scope) + (acceptCommand.map { ["--accept-command", $0] } ?? [])
    }

    static func update(_ id: String, scope: ConversationSettingsScope?, acceptCommand: String?) -> [String] {
        ["plugin", "update", id, "--json"] + scopeArguments(scope) + (acceptCommand.map { ["--accept-command", $0] } ?? [])
    }

    /// `keepData` が false だと、plugin のデータの置き場（`~/.claude/plugins/data/<id>/`）も消える
    static func uninstall(_ id: String, scope: String?, keepData: Bool) -> [String] {
        ["plugin", "uninstall", id, "--json"] + (scope.map { ["-s", $0] } ?? []) + (keepData ? ["--keep-data"] : [])
    }

    static func toggle(_ id: String, enabled: Bool, scope: ConversationSettingsScope?) -> [String] {
        ["plugin", enabled ? "enable" : "disable", id, "--json"] + scopeArguments(scope)
    }

    static func configure(_ id: String) -> [String] { ["plugin", "configure", id, "--json"] }
    static let list = ["plugin", "list", "--json", "--available"]
    static let installed = ["plugin", "list", "--json"]
    static let marketplaces = ["plugin", "marketplace", "list", "--json"]

    static func marketplaceAdd(_ source: String, scope: ConversationSettingsScope?) -> [String] {
        ["plugin", "marketplace", "add", source, "--json"] + (scope.map { ["--scope", Self.scope($0)] } ?? [])
    }

    static func marketplaceRemove(_ name: String, scope: ConversationSettingsScope?) -> [String] {
        ["plugin", "marketplace", "remove", name, "--json"] + (scope.map { ["--scope", Self.scope($0)] } ?? [])
    }

    static func marketplaceUpdate(_ name: String) -> [String] { ["plugin", "marketplace", "update", name, "--json"] }

    private static func scopeArguments(_ scope: ConversationSettingsScope?) -> [String] {
        scope.map { ["-s", Self.scope($0)] } ?? []
    }

    // MARK: 結果

    enum Reply: Equatable {
        case done
        /// marketplace が決めたコマンドを動かす前に人に見せる（入れる・更新の 1 回目、または見た後にコマンドか目録が替わった）
        case shown(ConversationSettingsEditResult.ShownCommand)
        /// 断られた。CLI の文は持たず、理由の種類と終了コードだけを持つ
        case rejected(reason: String, status: Int32)
    }

    static func reply(_ outcome: Subprocess.Outcome) throws -> Reply {
        if outcome.timedOut || outcome.overflowed { throw ConversationError.failed("plugin の CLI が終わらなかった") }
        let lastLine = String(decoding: outcome.stdout, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        guard let object = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any] else {
            let message = String(decoding: outcome.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .rejected(reason: ClaudeSettingsEdits.reason(code: nil, message: message), status: outcome.status)
        }
        if object["outcome"] as? String == "ok" { return .done }
        let code = object["failureCode"] as? String
        if let shown = object["shownCommand"] as? [String: Any], let command = shown["command"] as? String, let sha256 = shown["sha256"] as? String {
            return .shown(.init(command: command, sha256: sha256))
        }
        switch code {
        // 切った plugin を切る・入れた plugin を入れる：そうなっているので成功にする
        case "already_in_goal_state": return .done
        case "not_installed": return .rejected(reason: "not_found", status: outcome.status)
        default: return .rejected(reason: ClaudeSettingsEdits.reason(code: nil, message: object["message"] as? String ?? ""), status: outcome.status)
        }
    }

    /// `plugin configure --json` の、値を保存してある設定の名前（値は秘密を含むので読まない）。読めなければ失敗にする
    /// （「設定なし」とみなすと、確かめずに外して設定を失う）
    static func configuredOptions(_ outcome: Subprocess.Outcome) throws -> [String] {
        guard !outcome.timedOut, !outcome.overflowed, outcome.status == 0,
            let object = (try? JSONSerialization.jsonObject(with: outcome.stdout)) as? [String: Any], let configured = object["configured"] as? [String]
        else { throw ConversationError.failed("plugin の保存した設定を読めない") }
        return configured
    }

    /// 確かめる対象（外す plugin と層、消える設定の名前）の digest。順に依らない
    static func digest(_ loss: ConversationSettingsEditResult.Confirmation.Loss, plugins: [ConversationSettingsEditResult.Confirmation.Target], options: [String])
        -> String
    {
        let object: [String: Any] = [
            "loss": loss.rawValue, "plugins": plugins.map { [$0.id, $0.scope ?? ""] }.sorted { $0.joined(separator: "\n") < $1.joined(separator: "\n") },
            "options": options.sorted(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func confirmation(
        _ loss: ConversationSettingsEditResult.Confirmation.Loss, plugins: [ConversationSettingsEditResult.Confirmation.Target], options: [String]
    ) -> ConversationSettingsEditResult.Confirmation {
        .init(loss: loss, plugins: plugins, options: options, digest: digest(loss, plugins: plugins, options: options))
    }

    // MARK: 一覧

    /// `plugin list --json`（`--available` なら `{installed, available}`、なければ配列）の入れた plugin
    static func installedPlugins(_ data: Data) -> [ConversationPlugins.Plugin] {
        let object = try? JSONSerialization.jsonObject(with: data)
        let items = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["installed"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let (name, marketplace) = split(id)
            return ConversationPlugins.Plugin(
                id: id, name: name, marketplace: marketplace, version: item["version"] as? String, scope: item["scope"] as? String, installed: true,
                enabled: item["enabled"] as? Bool, hasOptions: item["hasUserConfig"] as? Bool)
        }
    }

    /// 消す前に対象を決めるための、入れた plugin の一覧。形が違う（配列でない・項目が表でない・id か層が無い）ときは空とみなさず失敗にする
    /// （空とみなすと、データを残して外す前の処理と確認を飛ばして、CLI が marketplace と一緒にデータと設定を消す）
    static func installedPluginsForRemoval(_ data: Data) throws -> [ConversationPlugins.Plugin] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw ConversationError.failed("入れた plugin の一覧を読めない") }
        return try items.map { value in
            guard let item = value as? [String: Any], let id = item["id"] as? String, !id.isEmpty, let scope = item["scope"] as? String, !scope.isEmpty
            else { throw ConversationError.failed("入れた plugin の一覧を読めない") }
            let (name, marketplace) = split(id)
            return ConversationPlugins.Plugin(
                id: id, name: name, marketplace: marketplace, version: item["version"] as? String, scope: scope, installed: true, enabled: item["enabled"] as? Bool,
                hasOptions: item["hasUserConfig"] as? Bool)
        }
    }

    static func plugins(list: Data, marketplaces: Data, query: String?) -> ConversationPlugins {
        let object = (try? JSONSerialization.jsonObject(with: list)) as? [String: Any]
        let installed = installedPlugins(list)
        let installedIDs = Set(installed.map(\.id))
        let available = (object?["available"] as? [[String: Any]] ?? []).compactMap { item -> ConversationPlugins.Plugin? in
            guard let id = item["pluginId"] as? String, !installedIDs.contains(id) else { return nil }
            let (name, marketplace) = split(id)
            return ConversationPlugins.Plugin(
                id: id, name: item["name"] as? String ?? name, marketplace: item["marketplaceName"] as? String ?? marketplace,
                description: item["description"] as? String, version: item["version"] as? String, installed: false, source: sourceKind(item["source"]))
        }
        let filtered = ConversationPlugins.filtered(available, query: query)
        let markets = ((try? JSONSerialization.jsonObject(with: marketplaces)) as? [[String: Any]] ?? []).compactMap { item -> ConversationPlugins.Marketplace? in
            guard let name = item["name"] as? String else { return nil }
            return ConversationPlugins.Marketplace(name: name, source: (item["path"] ?? item["url"] ?? item["repo"]) as? String)
        }
        return ConversationPlugins(installed: installed, available: filtered.plugins, availableTotal: filtered.total, marketplaces: markets)
    }

    /// 目録の `source`。文字は marketplace の中のパス（local）、表は `source` の種類（github・url・git-subdir・npm・archive・command）
    private static func sourceKind(_ value: Any?) -> String? {
        if value is String { return "local" }
        return (value as? [String: Any])?["source"] as? String
    }

    /// 層の設定のファイル（marketplace の宣言の置き場。CLI の一覧には層が出ない）
    static func settingsFile(_ scope: ConversationSettingsScope, environment: [String: String], cwd: String) -> URL {
        switch scope {
        case .user: ClaudeConfigDirectory.url(environment: environment).appending(path: "settings.json")
        case .project: URL(fileURLWithPath: cwd, isDirectory: true).appending(path: ".claude/settings.json")
        case .local: URL(fileURLWithPath: cwd, isDirectory: true).appending(path: ".claude/settings.local.json")
        }
    }

    /// 層の設定のファイルが marketplace を宣言しているか（`extraKnownMarketplaces.<名前>`）。ファイルが無ければ宣言は無い。読めない中身は失敗
    static func declares(_ data: Data?, marketplace: String) throws -> Bool {
        guard let data else { return false }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ConversationError.failed("設定のファイルを読めない") }
        return (object["extraKnownMarketplaces"] as? [String: Any])?[marketplace] != nil
    }

    static func split(_ id: String) -> (name: String, marketplace: String) {
        guard let at = id.lastIndex(of: "@") else { return (id, "") }
        return (String(id[..<at]), String(id[id.index(after: at)...]))
    }
}
