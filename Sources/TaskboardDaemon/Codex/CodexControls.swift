import Foundation
import TaskboardKit

/// codex app-server の応答から、会話の読む画面とその場の操作の応答（Kit の型）を作る（0.162.1 で実測）。
/// `config/read` は MCP の server のヘッダなどの秘密も返すので、権限の鍵だけを写す
enum CodexControls {
    /// 応答の行の `result`
    static func result(_ line: CodexRPCLine) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: line.data)) as? [String: Any])?["result"] as? [String: Any]
    }

    // MARK: 裏のタスク

    /// `thread/backgroundTerminals/list` の 1 頁。タスクの id は `processId`（`terminate` に渡す）。`itemIDs` は processId → 出力の item
    static func backgroundTerminals(_ result: [String: Any]?) -> (tasks: [ConversationBackgroundTasks.Task], itemIDs: [String: String], next: String?)? {
        guard let items = result?["data"] as? [[String: Any]] else { return nil }
        var itemIDs: [String: String] = [:]
        let tasks = items.compactMap { item -> ConversationBackgroundTasks.Task? in
            guard let process = item["processId"] as? String, !process.isEmpty else { return nil }
            if let itemID = item["itemId"] as? String { itemIDs[process] = itemID }
            return ConversationBackgroundTasks.Task(
                id: process, type: backgroundTerminalType, description: item["command"] as? String, cwd: item["cwd"] as? String,
                pid: (item["osPid"] as? NSNumber)?.intValue, cpuPercent: (item["cpuPercent"] as? NSNumber)?.doubleValue,
                memoryKB: (item["rssKb"] as? NSNumber)?.intValue)
        }
        return (tasks, itemIDs, result?["nextCursor"] as? String)
    }

    static let backgroundTerminalType = "background_terminal"

    /// 裏のターミナルの出力の末尾。daemon が `item/commandExecution/outputDelta` を item ごとに貯める。
    /// codex は起動直後の出力をツールの結果にだけ載せて知らせないことがあり（実測）、頭が揃っているかは分からないので、いつも切れているとして返す
    struct OutputTail: Equatable, Sendable {
        static let limit = 8192

        private(set) var text = ""
        private(set) var totalBytes = 0

        mutating func append(_ delta: String) {
            totalBytes += delta.utf8.count
            text += delta
            guard text.utf8.count > Self.limit else { return }
            // 末尾の limit バイトに収まる所から、文字の切れ目で残す
            var kept = text.utf8.count
            var start = text.startIndex
            while kept > Self.limit, start < text.endIndex {
                kept -= text[start].utf8.count
                start = text.index(after: start)
            }
            text = String(text[start...])
        }

        var output: ConversationTaskOutput {
            ConversationTaskOutput(output: text, totalBytes: totalBytes, truncated: true)
        }
    }

    // MARK: 読むだけのシート

    /// `hooks/list` の今の作業フォルダの分。出来事の名前は Claude Code と同じ形（`sessionStart` → `SessionStart`）にする。
    /// 鍵と hash（`key`・`currentHash`）は書き換えと信頼に使う `editKey` に詰め、並び順（`displayOrder`）は配列の順で表す。管理者の hook に `editKey` は付けない
    /// `userConfig` はユーザーの `config.toml` のパス（`config/read` の user の層）。置き換え・外すのはそのファイルの hook だけ（`CodexSettingsEdits.hook`）。
    /// 分からなければ `editable` は nil
    static func hooks(_ result: [String: Any]?, userConfig: String? = nil) -> ConversationHooks? {
        guard let entries = result?["data"] as? [[String: Any]] else { return nil }
        var hooks: [ConversationHooks.Hook] = []
        var problems: [ConversationReadoutProblem] = []
        var warnings: [String] = []
        for entry in entries {
            problems += Self.problems(entry["errors"])
            warnings += entry["warnings"] as? [String] ?? []
            for item in entry["hooks"] as? [[String: Any]] ?? [] {
                guard let event = item["eventName"] as? String, !event.isEmpty else { continue }
                let type = item["handlerType"] as? String ?? ""
                let command: String
                switch type {
                case "command": command = item["command"] as? String ?? ""
                case "mcpTool": command = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: "/")
                default: command = ""
                }
                hooks.append(
                    ConversationHooks.Hook(
                        event: event.prefix(1).uppercased() + event.dropFirst(), matcher: item["matcher"] as? String ?? "", source: item["source"] as? String ?? "",
                        plugin: item["pluginId"] as? String, type: type, command: command, enabled: item["enabled"] as? Bool, trust: item["trustStatus"] as? String,
                        sourcePath: item["sourcePath"] as? String, timeoutSeconds: (item["timeoutSec"] as? NSNumber)?.intValue, isAsync: item["async"] as? Bool,
                        statusMessage: item["statusMessage"] as? String, managed: item["isManaged"] as? Bool,
                        editKey: CodexSettingsEdits.hookItem(item).flatMap { $0.managed ? nil : $0.editKey },
                        editable: userConfig.map { item["isManaged"] as? Bool != true && item["sourcePath"] as? String == $0 }))
            }
        }
        return ConversationHooks(hooks: hooks, problems: problems, warnings: warnings)
    }

    /// `skills/list` の今の作業フォルダの分。出どころは `scope`（user・repo・system・admin）、状態は有効なら on・無効なら off
    static func skills(_ result: [String: Any]?) -> ConversationSkills? {
        guard let entries = result?["data"] as? [[String: Any]] else { return nil }
        var skills: [ConversationSkills.Skill] = []
        var problems: [ConversationReadoutProblem] = []
        for entry in entries {
            problems += Self.problems(entry["errors"])
            for item in entry["skills"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let interface = item["interface"] as? [String: Any]
                skills.append(
                    ConversationSkills.Skill(
                        name: name, displayName: interface?["displayName"] as? String ?? name, description: item["description"] as? String ?? "",
                        source: item["scope"] as? String ?? "", state: item["enabled"] as? Bool == false ? "off" : "on", path: item["path"] as? String,
                        plugin: item["pluginId"] as? String,
                        shortDescription: interface?["shortDescription"] as? String ?? item["shortDescription"] as? String))
            }
        }
        return ConversationSkills(skills: skills, problems: problems)
    }

    private static func problems(_ value: Any?) -> [ConversationReadoutProblem] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let path = item["path"] as? String else { return nil }
            return ConversationReadoutProblem(path: path, message: item["message"] as? String ?? "")
        }
    }

    /// thread を開いたときに読み込んだ指示のファイル（`instructionSources`。AGENTS.md など）。codex の置き場（`codexHome`）の下は user
    static func memory(sources: [String], codexHome: String?) -> ConversationMemory {
        let home = codexHome.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return ConversationMemory(
            files: sources.map { path in
                ConversationMemory.File(kind: home.map { path.hasPrefix($0) } == true ? "user" : "project", path: path, exists: true)
            })
    }

    /// 権限のシート。今の会話に効いている値（thread を開いた応答と `thread/settings/updated`）を session として先に置き、
    /// 次に `config/read` の設定の値を層の名前つきで置く。codex に Claude Code の形の規則は無いので `rules` は空
    static func permissionRules(config result: [String: Any]?, session: CodexThreadSettings, cwd: String) -> ConversationPermissionRules? {
        guard let config = result?["config"] as? [String: Any] else { return nil }
        let origins = result?["origins"] as? [String: Any] ?? [:]
        func source(_ key: String) -> String {
            ((origins[key] as? [String: Any])?["name"] as? [String: Any])?["type"] as? String ?? "config"
        }
        var settings = session.settings
        var directories = session.workspaceRoots.map { ConversationPermissionRules.Directory(path: $0, source: "session") }
            + session.writableRoots.map { ConversationPermissionRules.Directory(path: $0, source: "session") }
        for key in ["approval_policy", "approvals_reviewer", "sandbox_mode", "default_permissions"] {
            if let value = text(config[key]) { settings.append(.init(key: key, value: value, source: source(key))) }
        }
        if let write = config["sandbox_workspace_write"] as? [String: Any] {
            for name in ["network_access", "exclude_tmpdir_env_var", "exclude_slash_tmp"] {
                let key = "sandbox_workspace_write.\(name)"
                if let value = text(write[name]) { settings.append(.init(key: key, value: value, source: source(key))) }
            }
            for (index, root) in (write["writable_roots"] as? [String] ?? []).enumerated() {
                let key = "sandbox_workspace_write.writable_roots"
                directories.append(.init(path: root, source: origins["\(key).\(index)"] != nil ? source("\(key).\(index)") : source(key)))
            }
        }
        // フォルダの信頼は、作業フォルダかその上で一番近いものが効く
        if let projects = config["projects"] as? [String: Any] {
            let paths = Set([cwd, (cwd as NSString).resolvingSymlinksInPath, realpath(cwd)].compactMap { $0 })
            let match = projects.keys.filter { project in paths.contains { $0 == project || $0.hasPrefix(project.hasSuffix("/") ? project : project + "/") } }
                .max { $0.count < $1.count }
            if let match, let level = (projects[match] as? [String: Any]).flatMap({ text($0["trust_level"]) }) {
                let key = "projects.\(match).trust_level"
                settings.append(.init(key: key, value: level, source: source(key)))
            }
        }
        return ConversationPermissionRules(rules: [], directories: directories, settings: settings)
    }

    private static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 設定の値の文字。文字・数・真偽はそのまま、表（`approval_policy` の granular など）は詰めた JSON。null は nil
    static func text(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let string as String: return string
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        case let other?:
            guard JSONSerialization.isValidJSONObject(other), let data = try? JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: MCP の server

    /// `mcp_status`：設定（`config/read` の `mcp_servers` と `origins`）の server と、thread の実行中の状態（`mcpServerStatus/list`）を合わせる。
    /// 設定の env・headers・url の値と、server の失敗の文は写さない
    static func mcpStatus(config result: [String: Any]?, statuses: [[String: Any]]) -> ConversationMcpStatus {
        let servers = (result?["config"] as? [String: Any])?["mcp_servers"] as? [String: Any] ?? [:]
        let origins = result?["origins"] as? [String: Any] ?? [:]
        // `layers` は優先の高い順（同じ鍵は project が user に勝ち、並びも project・user の順だった。実測）
        let rank = Dictionary(
            ((result?["layers"] as? [[String: Any]]) ?? []).enumerated().compactMap { index, layer in
                ((layer["name"] as? [String: Any])?["type"] as? String).map { ($0, index) }
            }, uniquingKeysWith: { first, _ in first })
        func type(_ key: String) -> String? { ((origins[key] as? [String: Any])?["name"] as? [String: Any])?["type"] as? String }
        /// 有効・無効の鍵の出どころ。書いていなければ、その server の鍵の出どころのうち最も優先される層
        func layer(_ name: String) -> String? {
            let prefix = "mcp_servers.\(name)."
            if let enabled = type(prefix + "enabled") { return enabled }
            return origins.keys.filter { $0.hasPrefix(prefix) }.compactMap(type).min { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
        }
        let byName = Dictionary(statuses.compactMap { item in (item["name"] as? String).map { ($0, item) } }, uniquingKeysWith: { first, _ in first })
        let names = statuses.compactMap { $0["name"] as? String } + servers.keys.sorted().filter { byName[$0] == nil }
        return ConversationMcpStatus(
            mcpServers: names.map { name in
                let config = servers[name] as? [String: Any]
                let status = byName[name]
                let info = status?["serverInfo"] as? [String: Any]
                let enabled = config.map { $0["enabled"] as? Bool ?? true }
                return ConversationMcpServer(
                    name: name, status: enabled == false ? "disabled" : connection(status?["runtimeStatus"] as? String), scope: layer(name),
                    serverName: info?["name"] as? String, serverVersion: info?["version"] as? String,
                    toolCount: (status?["tools"] as? [String: Any])?.count, transport: config.map { $0["url"] != nil ? "http" : "stdio" }, enabled: enabled)
            })
    }

    /// codex の繋がりの状態を、Claude の `mcp_status` の言葉（connected・failed・needs-auth・pending・disabled）に写す
    private static func connection(_ status: String?) -> String {
        switch status {
        case "connected": "connected"
        case "failed", "cancelled": "failed"
        case "authenticationRequired": "needs-auth"
        case "disabled": "disabled"
        default: "pending"
        }
    }

    // MARK: 作業フォルダとログイン

    /// `/cd` の行き先を確かめる（codex の `thread/settings/update` はパスを確かめない）。`~` を開き、実体のパスにする。
    /// フォルダでなければ `rejected` の答え
    enum Directory: Equatable {
        case found(String)
        case refused(ConversationCwdChange)
    }

    static func directory(_ path: String, home: String) -> Directory {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) else {
            return .refused(ConversationCwdChange(outcome: .rejected, reason: "not_found"))
        }
        guard isDirectory.boolValue else { return .refused(ConversationCwdChange(outcome: .rejected, reason: "not_a_directory")) }
        return .found(realpath(expanded) ?? expanded)
    }

    /// `account/login/start`（`chatgptDeviceCode`）の答え。開くページが https でないか、コードが無ければ nil。
    /// device code はどの端末で開いても同じページなので、2 つのページは同じ URL にする
    static func login(_ result: [String: Any]?) -> (login: ConversationLogin, loginID: String)? {
        guard let result, result["type"] as? String == "chatgptDeviceCode", let loginID = result["loginId"] as? String, !loginID.isEmpty,
            let url = (result["verificationUrl"] as? String).flatMap(OAuthLinks.openable), url.scheme == "https",
            let code = result["userCode"] as? String, !code.isEmpty, code.count <= 64, !code.contains(where: \.isWhitespace)
        else { return nil }
        return (ConversationLogin(manualURL: url.absoluteString, automaticURL: url.absoluteString, userCode: code), loginID)
    }

    // MARK: 書き出し

    /// thread の item（古い順）を、Claude Code の書き出しと同じ記号の文にする。考えている途中（reasoning）と知らない種類は入れない
    static func export(_ items: [CodexItem]) -> String {
        var blocks: [String] = []
        func block(_ head: String, _ body: String, mark: String = "⏺") {
            var lines = body.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            let first = lines.first ?? ""
            blocks.append(([mark + " " + head + first] + lines.dropFirst().map { "  " + $0 }).joined(separator: "\n"))
        }
        func result(_ text: String?) {
            guard let text, !text.isEmpty, var last = blocks.popLast() else { return }
            var lines = text.components(separatedBy: "\n")
            if lines.last == "" { lines.removeLast() }
            last += "\n" + lines.enumerated().map { ($0.offset == 0 ? "  ⎿  " : "     ") + $0.element }.joined(separator: "\n")
            blocks.append(last)
        }
        for item in items {
            switch item {
            case .userMessage(_, _, let text, let images):
                let attached = images > 0 ? (text.isEmpty ? "" : "\n") + Array(repeating: "[Image]", count: images).joined(separator: " ") : ""
                block("", text + attached, mark: ">")
            case .agentMessage(_, let text), .plan(_, let text):
                block("", text)
            case .command(_, let command, let output, _, _):
                block("Bash(", CodexConversation.unwrapShell(command) + ")")
                result(output)
            case .fileChange(_, let changes, _):
                for change in changes {
                    block("\(change.kind == "add" ? "Write" : change.kind == "delete" ? "Delete" : "Update")(", change.path + ")")
                    result(change.diff)
                }
            case .mcpToolCall(_, let server, let tool, let arguments, _, let output, let error):
                block("\(server) - \(tool)(", arguments + ")")
                result(error ?? output)
            case .webSearch(_, let query):
                block("Web Search(", query + ")")
            case .agent(_, let tool, let prompt, _):
                block("Agent(", (prompt ?? tool) + ")")
            case .subagent(_, "started", let thread, let path):
                block("Agent(", (path ?? thread) + ")")
            case .subagent:
                break
            case .imageView(_, let path):
                block("Read(", path + ")")
            case .dynamicTool(_, let name, let arguments, _, let output, _):
                block("\(name)(", arguments + ")")
                result(output)
            case .imageGeneration(_, let prompt, _, let savedPath, _, _):
                block("ImageGeneration(", (prompt ?? "") + ")")
                result(savedPath)
            case .review(_, let entered, let review):
                if entered { block("Code review(", review + ")") }
            case .reasoning, .other:
                break
            }
        }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    /// 書き出しのファイル名（時刻と最初の指示。Claude Code の `/export` と同じ形）
    static func exportFilename(firstPrompt: String?, at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let line = firstPrompt?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var slug = ""
        for character in line.lowercased() {
            if character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
            if slug.count >= 50 { break }
        }
        while slug.last == "-" { slug.removeLast() }
        return formatter.string(from: date) + "-" + (slug.isEmpty ? "conversation" : slug) + ".txt"
    }
}

/// 今の会話に効いている権限の値とメモリ（thread を開いた応答と `thread/settings/updated` から）。daemon が起き直すまでの間だけ持つ
struct CodexThreadSettings: Equatable, Sendable {
    var approvalPolicy: String?
    var approvalsReviewer: String?
    /// config.toml の `sandbox_mode` と同じ名前（read-only・workspace-write・danger-full-access・external-sandbox）
    var sandbox: String?
    var networkAccess: String?
    var excludeTmpdirEnvVar: String?
    var excludeSlashTmp: String?
    var writableRoots: [String] = []
    var workspaceRoots: [String] = []
    var permissionProfile: String?
    /// thread を開いたときに読み込んだ指示のファイル。開いた応答を見ていなければ nil
    var instructionSources: [String]?

    /// thread を開いた応答（`thread/start`・`thread/resume`）
    mutating func applyOpened(_ result: [String: Any]) {
        apply(result, sandboxKey: "sandbox")
        if let roots = result["runtimeWorkspaceRoots"] as? [String] { workspaceRoots = roots }
        if let sources = result["instructionSources"] as? [String] { instructionSources = sources }
    }

    /// `thread/settings/updated` の `threadSettings`
    mutating func applyUpdated(_ settings: [String: Any]) {
        apply(settings, sandboxKey: "sandboxPolicy")
    }

    private mutating func apply(_ object: [String: Any], sandboxKey: String) {
        if let value = CodexControls.text(object["approvalPolicy"]) { approvalPolicy = value }
        if let value = object["approvalsReviewer"] as? String { approvalsReviewer = value }
        if object.keys.contains("activePermissionProfile") { permissionProfile = (object["activePermissionProfile"] as? [String: Any])?["id"] as? String }
        guard let sandbox = object[sandboxKey] as? [String: Any], let type = sandbox["type"] as? String else { return }
        self.sandbox = Self.sandboxNames[type] ?? type
        networkAccess = CodexControls.text(sandbox["networkAccess"])
        excludeTmpdirEnvVar = CodexControls.text(sandbox["excludeTmpdirEnvVar"])
        excludeSlashTmp = CodexControls.text(sandbox["excludeSlashTmp"])
        writableRoots = sandbox["writableRoots"] as? [String] ?? []
    }

    private static let sandboxNames = [
        "readOnly": "read-only", "workspaceWrite": "workspace-write", "dangerFullAccess": "danger-full-access", "externalSandbox": "external-sandbox",
    ]

    /// 権限のシートの session の行（config.toml の鍵の名前で）
    var settings: [ConversationPermissionRules.Setting] {
        [
            ("approval_policy", approvalPolicy), ("approvals_reviewer", approvalsReviewer), ("sandbox_mode", sandbox),
            ("sandbox_workspace_write.network_access", networkAccess), ("sandbox_workspace_write.exclude_tmpdir_env_var", excludeTmpdirEnvVar),
            ("sandbox_workspace_write.exclude_slash_tmp", excludeSlashTmp), ("default_permissions", permissionProfile),
        ].compactMap { key, value in value.map { ConversationPermissionRules.Setting(key: key, value: $0, source: "session") } }
    }
}
