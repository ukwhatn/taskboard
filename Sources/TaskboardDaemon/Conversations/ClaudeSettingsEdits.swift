import CryptoKit
import Foundation
import TaskboardKit

/// `edit_settings` を Claude Code の隠しのサブコマンド（VS Code の拡張が使う `claude edit-* --json`。stdin に 1 件の編集の JSON）に読み替え、
/// 終わり方と出力から結果を作る（2.1.304 で実測。入力の形は実行ファイルの zod の定義から読んだ）。
/// 動いている CLI は設定のファイルを自分で読み直す（hook・skill はすぐ、権限・メモリ・sandbox も 3 秒以内）ので、起こし直しは要らない
enum ClaudeSettingsEdits {
    struct Invocation: Equatable {
        var subcommand: String
        var input: Data
    }

    /// 起こす子の環境。Claude Code の中から起こされたと見ると書くのを断るので、その印を外す
    static func environment(_ base: [String: String]) -> [String: String] {
        base.filter { $0.key != "CLAUDE_CODE_CHILD_SESSION" && $0.key != "CLAUDECODE" }
    }

    /// `target` は hook を置き換え・外すときに、鍵で一覧から引いた行（呼ぶ側が今の一覧で引く）
    static func invocation(_ edit: ConversationSettingsEdit, target: HookTarget? = nil) throws -> Invocation {
        switch edit {
        case .permissionRule(let op, let behavior, let rules, let scope):
            switch op {
            case .add:
                return try make("edit-permission-rules", ["op": "add", "rules": rules, "behavior": behavior, "destination": scope.rawValue])
            case .remove:
                guard rules.count == 1, let rule = rules.first else { throw ConversationError.invalid("外す規則は 1 つずつ") }
                return try make("edit-permission-rules", ["op": "remove", "rule": rule, "behavior": behavior, "source": scope.rawValue])
            case .replace:
                throw ConversationError.invalid("権限の規則は置き換えられない（外してから足す）")
            }
        case .hook(let op, let scope, let event, let matcher, let hook, _):
            var fields: [String: Any] = ["op": op.rawValue, "source": scope.rawValue, "event": event, "matcher": matcher]
            if op != .remove {
                guard let hook else { throw ConversationError.invalid("hook の中身が要る") }
                fields["hook"] = body(hook)
            }
            if op != .add {
                guard let target else { throw ConversationError.invalid("書き換える hook が一覧に無い") }
                guard target.source == scope.rawValue else { throw ConversationError.invalid("hook の鍵と層が違う") }
                fields["target"] = ["event": target.event, "matcher": target.matcher, "hook": target.config]
                if op == .remove { fields["event"] = target.event }
            }
            return try make("edit-hook", fields)
        case .memory(let autoMemory, let autoDream):
            var fields: [String: Any] = [:]
            if let autoMemory { fields["autoMemoryEnabled"] = autoMemory }
            if let autoDream { fields["autoDreamEnabled"] = autoDream }
            guard !fields.isEmpty else { throw ConversationError.invalid("替える設定が無い") }
            return try make("edit-memory-settings", fields)
        case .skill(let name, _, let state):
            return try make("edit-skill-overrides", ["name": name, "state": state])
        case .sandbox(let mode, let allowUnsandboxedCommands):
            var fields: [String: Any] = [:]
            if let mode { fields["mode"] = mode }
            if let allowUnsandboxedCommands { fields["allowUnsandboxedCommands"] = allowUnsandboxedCommands }
            guard !fields.isEmpty else { throw ConversationError.invalid("替える設定が無い") }
            return try make("edit-sandbox-settings", fields)
        case .plugin, .marketplace:
            throw ConversationError.invalid("plugin と marketplace は claude plugin で書く")
        case .permissionSetting, .hookState, .mcpServer:
            throw ConversationError.controlUnsupported("edit_settings.\(edit.target.rawValue)", engine: .claude)
        }
    }

    private static func make(_ subcommand: String, _ fields: [String: Any]) throws -> Invocation {
        Invocation(subcommand: subcommand, input: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    }

    private static func body(_ hook: ConversationSettingsEdit.HookBody) -> [String: Any] {
        var body: [String: Any] = ["type": hook.type]
        if let command = hook.command { body["command"] = command }
        if let prompt = hook.prompt { body["prompt"] = prompt }
        if let url = hook.url { body["url"] = url }
        if let timeout = hook.timeout { body["timeout"] = timeout }
        if let statusMessage = hook.statusMessage { body["statusMessage"] = statusMessage }
        return body
    }

    // MARK: hook の鍵

    /// hook の一覧の書き換えられる行（`get_hooks_listing` の `editable`）。置き換え・外すとき、CLI は中身の一致で hook を探すので、
    /// 一覧に出た中身（`editable.config`。timeout などの欄も含む）をそのまま渡す
    struct HookTarget {
        var event: String
        var source: String
        var matcher: String
        var config: [String: Any]
    }

    /// 一覧の行を指す鍵。中身（http の hook のヘッダなど）をアプリに出さないよう、中身のハッシュにする
    static func hookKey(event: String, source: String, matcher: String, config: [String: Any]) -> String? {
        let object: [String: Any] = ["event": event, "source": source, "matcher": matcher, "config": config]
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 一覧（`get_hooks_listing` の応答）の書き換えられる行
    static func hookTargets(listing payload: String?) -> [(key: String, target: HookTarget)] {
        guard let payload, let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
            let items = object["hooks"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let event = item["event"] as? String, let editable = item["editable"] as? [String: Any], let config = editable["config"] as? [String: Any]
            else { return nil }
            let target = HookTarget(event: event, source: item["source"] as? String ?? "", matcher: editable["matcher"] as? String ?? "", config: config)
            return hookKey(event: target.event, source: target.source, matcher: target.matcher, config: config).map { ($0, target) }
        }
    }

    // MARK: 結果

    enum Answer: Equatable {
        /// 書けた。`warnings` は CLI が返した注意の数（文は書いた値を引用しうるので、応答にもログにも出さない）
        case written(ConversationSettingsEditResult, warnings: Int)
        /// 断られた。CLI の文は書いた値（規則・hook のコマンドの秘密）を引用しうるので持たず、理由の種類と終了コードだけを持つ
        case rejected(reason: String, status: Int32)
    }

    /// 書き込みの子の終わり方から結果を作る。終わらなかった・出力が多すぎたときは失敗
    static func answer(_ outcome: Subprocess.Outcome) throws -> Answer {
        if outcome.timedOut || outcome.overflowed { throw ConversationError.failed("設定を書く CLI が終わらなかった") }
        let out = String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = out.split(separator: "\n").last.map(String.init) ?? ""
        let object = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any]
        if outcome.status == 0, object?["ok"] as? Bool == true {
            return .written(ConversationSettingsEditResult(stored: object?["stored"] as? [String]), warnings: (object?["warnings"] as? [Any])?.count ?? 0)
        }
        let message = (object?["error"] as? String)
            ?? [out, String(decoding: outcome.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n")
        return .rejected(reason: reason(code: object?["code"] as? String, message: message), status: outcome.status)
    }

    /// 断りの理由の種類。hook は code、ほかは CLI の文で分ける
    static func reason(code: String?, message: String) -> String {
        switch code {
        case "duplicate", "twin_by_headers": return "duplicate"
        case "target_missing": return "not_found"
        case "target_ambiguous": return "ambiguous"
        case "source_disabled": return "locked"
        case "file_unloadable", "legacy", "not_a_list": return "file_error"
        case "bad_request": return "invalid"
        default: break
        }
        let text = message.lowercased()
        let table: [(String, [String])] = [
            ("duplicate", ["is already in", "already configured"]),
            ("not_found", ["rule not found", "no longer in", "not found"]),
            ("locked", ["managed settings", "higher-priority", "cannot be changed here", "not loaded here", "is disabled for this session", "inside a claude code session"]),
            ("file_error", ["has errors and could not be loaded", "edit that file directly", "edit the file by hand"]),
            ("invalid", ["not a ", "must be", "must not be", "invalid"]),
        ]
        return table.first { _, needles in needles.contains { text.contains($0) } }?.0 ?? "other"
    }
}
