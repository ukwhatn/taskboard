import SwiftUI
import TaskboardKit

/// 読む画面のシートから設定を書く（`edit_settings`）口。書けたら true。失敗の文は `failed` に、書けたが今の会話に効かないときの案内は `noticed` に渡す
@MainActor
struct ConversationSettingsWriter {
    let feed: ConversationFeed
    let readout: ConversationReadout
    let engine: Conversation.Engine
    let failed: (String?) -> Void
    var noticed: (String?) -> Void = { _ in }
    /// daemon が書かずに人の確かめを求めた（plugin のコマンド・消える設定）。確かめたら `ConversationPluginReview.resent` を送り直す
    var reviewing: (ConversationPluginReview?) -> Void = { _ in }

    /// 書けたら true。確かめを求められたら `reviewing` に渡して false
    func write(_ edit: ConversationSettingsEdit, event: LocalizedStringResource) async -> Bool {
        failed(nil)
        noticed(nil)
        reviewing(nil)
        do {
            let result = try await feed.editSettings(edit, reload: readout)
            if let review = ConversationPluginReview(edit: edit, result: result, event: event) {
                reviewing(review)
                return false
            }
            noticed(ConversationSettingsText.notice(result))
            return true
        } catch {
            failed(ConversationSettingsText.failure(event, error, engine: engine)?.text)
            return false
        }
    }

    /// 同じ口で、失敗の文だけを別の場所に出す（フックの編集のシート）
    func failing(to failed: @escaping (String?) -> Void) -> ConversationSettingsWriter {
        ConversationSettingsWriter(feed: feed, readout: readout, engine: engine, failed: failed, noticed: noticed, reviewing: reviewing)
    }
}

/// 権限の規則の追加。種類・規則・保存先を選んで足す
struct PermissionRuleAdder: View {
    let writer: ConversationSettingsWriter
    let machineName: String
    @State private var behavior = "allow"
    @State private var rule = ""
    @State private var scope = ConversationSettingsScope.local
    @State private var saving = false

    var body: some View {
        Section {
            Picker("種類", selection: $behavior) {
                ForEach(["allow", "ask", "deny"], id: \.self) { Text(ConversationReadoutText.behavior($0)).tag($0) }
            }
            LabeledTextField(label: String(localized: "規則"), text: $rule, monospaced: true)
                .onSubmit { add() }
            ConversationScopePicker(scope: $scope)
            Button("規則を追加") { add() }
                .disabled(saving || rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("規則の追加")
        } footer: {
            Text("例：Bash(npm test:*)。ユーザーの設定は\(machineName)のすべての会話に効きます。")
        }
    }

    private func add() {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saving else { return }
        saving = true
        Task {
            if await writer.write(.permissionRule(op: .add, behavior: behavior, rules: [text], scope: scope), event: "規則を追加できませんでした") { rule = "" }
            saving = false
        }
    }
}

/// 権限の規則と hook の保存先
struct ConversationScopePicker: View {
    @Binding var scope: ConversationSettingsScope

    var body: some View {
        Picker("保存先", selection: $scope) {
            ForEach(ConversationSettingsScope.allCases, id: \.self) { Text(ConversationReadoutText.source($0.rawValue)).tag($0) }
        }
    }
}

/// sandbox の節（権限の規則のシートの中）。動き方と、sandbox で動かせないコマンドを外で動かすか
struct ConversationSandboxSection: View {
    let feed: ConversationFeed
    let writer: ConversationSettingsWriter
    @State private var mode = PendingValue<String>()
    @State private var unsandboxed = PendingValue<Bool>()

    var body: some View {
        Section {
            switch feed.sandbox {
            case .loaded(let sandbox):
                content(sandbox)
            case .failed(let failure):
                Text(failure.text).foregroundStyle(.secondary)
            default:
                ProgressView("読み込み中…").controlSize(.small)
            }
        } header: {
            Text("サンドボックス")
        } footer: {
            if case .loaded(let sandbox) = feed.sandbox, !sandbox.excludedCommands.isEmpty {
                Text("サンドボックスの外で動かすコマンド：\(sandbox.excludedCommands.joined(separator: "、"))")
            }
        }
        .onAppear { feed.loadSandbox() }
        .onChange(of: feed.sandbox.value) { _, sandbox in
            guard let sandbox else { return }
            if mode.shown(sandbox.mode) == sandbox.mode { mode.settle() }
            if unsandboxed.shown(sandbox.allowUnsandboxedCommands) == sandbox.allowUnsandboxedCommands { unsandboxed.settle() }
        }
    }

    @ViewBuilder
    private func content(_ sandbox: ConversationSandbox) -> some View {
        if !sandbox.supported {
            Text("このMacではサンドボックスを使えません。").foregroundStyle(.secondary)
        } else {
            Picker("モード", selection: Binding.pending($mode, current: sandbox.mode) { value in
                await writer.write(.sandbox(mode: value, allowUnsandboxedCommands: nil), event: "サンドボックスの設定を保存できませんでした")
            }) {
                ForEach(["auto-allow", "regular", "disabled"], id: \.self) { value in
                    if value != "auto-allow" || sandbox.autoAllowAvailable { Text(ConversationSettingsText.sandboxMode(value)).tag(value) }
                }
            }
            .disabled(sandbox.locked)
            Toggle("サンドボックスで動かせないコマンドを外で動かす", isOn: Binding.pending($unsandboxed, current: sandbox.allowUnsandboxedCommands) { value in
                await writer.write(.sandbox(mode: nil, allowUnsandboxedCommands: value), event: "サンドボックスの設定を保存できませんでした")
            })
            .disabled(sandbox.locked)
            if sandbox.locked { Text("組織の設定で固定されています。").textRole(.caption) }
            if sandbox.missingDependencies { Label("必要なソフトウェアがインストールされていないため、サンドボックスを使えません。", systemImage: "exclamationmark.triangle").textRole(.caption) }
        }
    }
}

/// 自動のメモリとその整理の切り替え（メモリのシートの中。ユーザーの設定に書く）
struct ConversationMemoryToggles: View {
    let memory: ConversationMemory
    let writer: ConversationSettingsWriter
    let machineName: String
    @State private var autoMemory = PendingValue<Bool>()
    @State private var autoDream = PendingValue<Bool>()

    var body: some View {
        if memory.autoMemory != nil || memory.autoDream != nil {
            Section {
                if let toggle = memory.autoMemory {
                    Toggle("自動のメモリ", isOn: Binding.pending($autoMemory, current: toggle.enabled) { value in
                        await writer.write(.memory(autoMemory: value, autoDream: nil), event: "メモリの設定を保存できませんでした")
                    })
                    .disabled(!toggle.toggleable)
                }
                if let toggle = memory.autoDream {
                    Toggle("メモリの整理", isOn: Binding.pending($autoDream, current: toggle.enabled) { value in
                        await writer.write(.memory(autoMemory: nil, autoDream: value), event: "メモリの設定を保存できませんでした")
                    })
                    .disabled(!toggle.toggleable)
                }
            } footer: {
                Text("ユーザーの設定に保存し、\(machineName)のすべての会話に効きます。")
            }
            .onChange(of: memory) { _, memory in
                if let toggle = memory.autoMemory, autoMemory.shown(toggle.enabled) == toggle.enabled { autoMemory.settle() }
                if let toggle = memory.autoDream, autoDream.shown(toggle.enabled) == toggle.enabled { autoDream.settle() }
            }
        }
    }
}

/// skill の状態の選択（スキルのシートの行）。Claude は作業フォルダの自分だけの設定に 4 つの状態を、
/// Codex はユーザーの設定に有効と無効を書く（同じ名前の skill があるので、読む画面の `path` で指す）
struct ConversationSkillStatePicker: View {
    let skill: ConversationSkills.Skill
    let writer: ConversationSettingsWriter
    @State private var state = PendingValue<String>()

    private var states: [String] {
        writer.engine == .codex ? ["on", "off"] : ["on", "name-only", "user-invocable-only", "off"]
    }

    var body: some View {
        Picker("状態", selection: Binding.pending($state, current: skill.state) { value in
            let path = writer.engine == .codex ? skill.path : nil
            return await writer.write(.skill(name: skill.name, path: path, state: value), event: "スキルの状態を保存できませんでした")
        }) {
            ForEach(states, id: \.self) { Text(ConversationReadoutText.skillState($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .onChange(of: skill.state) { _, current in
            if state.shown(current) == current { state.settle() }
        }
    }
}

/// Codex の権限の設定の書き込み（権限の規則のシートの中）。ユーザーの設定（config.toml）の値を選び、「未設定」で鍵を消す
struct CodexPermissionSettingsSection: View {
    /// 書ける鍵。`values` が nil なら文字で入れる
    struct Key {
        let key: String
        let label: LocalizedStringResource
        let values: [String]?
    }

    static let keys = [
        // config.toml の approval_policy は untrusted を受けない
        Key(key: "approval_policy", label: "承認の方針", values: ["on-request", "never"]),
        Key(key: "approvals_reviewer", label: "承認する人", values: ["user", "auto_review"]),
        Key(key: "sandbox_mode", label: "サンドボックス", values: ["read-only", "workspace-write", "danger-full-access"]),
        Key(key: "default_permissions", label: "権限のプロファイル", values: nil),
        Key(key: "sandbox_workspace_write.network_access", label: "ネットワークへの接続", values: ["true", "false"]),
        Key(key: "sandbox_workspace_write.exclude_tmpdir_env_var", label: "$TMPDIRを書き込み先から外す", values: ["true", "false"]),
        Key(key: "sandbox_workspace_write.exclude_slash_tmp", label: "/tmpを書き込み先から外す", values: ["true", "false"]),
    ]

    let settings: [ConversationPermissionRules.Setting]
    let writer: ConversationSettingsWriter
    let machineName: String

    var body: some View {
        Section {
            ForEach(Self.keys, id: \.key) { key in
                CodexPermissionSettingRow(key: key, current: settings.first { $0.key == key.key && $0.source == "user" }?.value ?? "", writer: writer)
            }
        } header: {
            Text("権限の設定の変更")
        } footer: {
            Text("ユーザーの設定（config.toml）に保存し、\(machineName)のすべてのCodexに効きます。")
        }
    }
}

/// 権限の設定の 1 つの鍵。`current` は空なら未設定
private struct CodexPermissionSettingRow: View {
    let key: CodexPermissionSettingsSection.Key
    let current: String
    let writer: ConversationSettingsWriter
    @State private var pending = PendingValue<String>()
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            if let values = key.values {
                Picker(String(localized: key.label), selection: Binding.pending($pending, current: current) { await save($0) }) {
                    Text("未設定").tag("")
                    ForEach(values.contains(current) || current.isEmpty ? values : values + [current], id: \.self) { Text(verbatim: $0).tag($0) }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    LabeledTextField(label: String(localized: key.label), text: $text, prompt: ":workspace", monospaced: true)
                        .onSubmit { submit() }
                    Button("保存") { submit() }
                        .disabled(text.trimmingCharacters(in: .whitespaces) == current)
                }
            }
            Text(verbatim: key.key).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .onAppear { text = current }
        .onChange(of: current) { _, current in
            if pending.shown(current) == current { pending.settle() }
            text = current
        }
    }

    private func save(_ value: String) async -> Bool {
        await writer.write(.permissionSetting(key: key.key, value: value.isEmpty ? nil : value), event: "権限の設定を保存できませんでした")
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard value != current else { return }
        Task { _ = await save(value) }
    }
}

/// フックの追加と編集のシート
struct ConversationHookEditor: View {
    /// 編集の元（読む画面の行）。nil なら追加
    struct Draft: Identifiable {
        let id = UUID()
        var event = "PreToolUse"
        var matcher = ""
        var type = "command"
        var content = ""
        var timeout = ""
        var statusMessage: String?
        var scope = ConversationSettingsScope.local
        var editKey: String?

        /// Codex はユーザーの設定にだけ書く
        init(engine: Conversation.Engine) {
            if engine == .codex { scope = .user }
        }

        init(_ hook: ConversationHooks.Hook, engine: Conversation.Engine) {
            event = hook.event
            matcher = hook.matcher
            type = hook.type
            content = hook.command
            timeout = hook.timeoutSeconds.map(String.init) ?? ""
            statusMessage = hook.statusMessage
            scope = engine == .codex ? .user : ConversationSettingsScope(rawValue: hook.source) ?? .local
            editKey = hook.editKey
        }

        var body: ConversationSettingsEdit.HookBody {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return ConversationSettingsEdit.HookBody(
                type: type, command: type == "command" ? text : nil, prompt: type == "prompt" || type == "agent" ? text : nil, url: type == "http" ? text : nil,
                timeout: Int(timeout.trimmingCharacters(in: .whitespaces)), statusMessage: statusMessage)
        }
    }

    /// 足せる出来事。Codex は知らない名前を黙って受けて無視するので、codex の一覧（`HookEventName`）にあるものだけを出す
    static func events(_ engine: Conversation.Engine) -> [String] {
        switch engine {
        case .codex:
            [
                "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "SessionStart", "SessionEnd", "UserPromptSubmit", "SubagentStart",
                "SubagentStop", "Stop", "Interrupt",
            ]
        case .claude, .unknown: ["PreToolUse", "PostToolUse", "UserPromptSubmit", "Notification", "Stop", "SubagentStop", "SessionStart", "SessionEnd", "PreCompact"]
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    let writer: ConversationSettingsWriter
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        let events = Self.events(writer.engine)
        SheetScaffold(title: draft.editKey == nil ? String(localized: "フックの追加") : String(localized: "フックの編集"), error: failure) {
            Section {
                Picker("イベント", selection: $draft.event) {
                    ForEach(events.contains(draft.event) ? events : events + [draft.event], id: \.self) { Text(verbatim: $0).tag($0) }
                }
                LabeledTextField(label: String(localized: "対象"), text: $draft.matcher, monospaced: true)
            } footer: {
                Text("対象はツールの名前など。空にするとすべてに当てます。")
            }
            Section {
                // Codex の hook はコマンドだけ
                if writer.engine != .codex {
                    Picker("種類", selection: $draft.type) {
                        ForEach(["command", "prompt", "http", "agent"], id: \.self) { Text(ConversationSettingsText.hookType($0)).tag($0) }
                    }
                }
                LabeledTextField(label: ConversationSettingsText.hookContent(draft.type), text: $draft.content, monospaced: draft.type != "prompt" && draft.type != "agent")
                LabeledTextField(label: String(localized: "タイムアウト（秒）"), text: $draft.timeout)
                if draft.editKey == nil, writer.engine != .codex { ConversationScopePicker(scope: $draft.scope) }
            }
        } actions: {
            Button("キャンセル") { dismiss() }
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        saving = true
        let writer = writer.failing { failure = $0 }
        let edit = ConversationSettingsEdit.hook(
            op: draft.editKey == nil ? .add : .replace, scope: draft.scope, event: draft.event, matcher: draft.matcher.trimmingCharacters(in: .whitespaces),
            hook: draft.body, editKey: draft.editKey)
        Task {
            if await writer.write(edit, event: "フックを保存できませんでした") { dismiss() }
            saving = false
        }
    }
}

/// 設定の書き込みの文
enum ConversationSettingsText {
    /// 断られた理由（daemon の `session_command_failed` の `reason`）から原因と対処を組む
    static func failure(_ event: LocalizedStringResource, _ error: any Error, engine: Conversation.Engine = .claude) -> UserFacingError? {
        guard case SessionSourceError.rejected(let rejection) = error, rejection.code == .sessionCommandFailed, let reason = rejection.params["reason"] else {
            return UserFacingError(event, error: error)
        }
        return switch reason {
        case "duplicate": UserFacingError(event, cause: String(localized: "同じものがすでにあります"))
        case "not_found": UserFacingError(event, cause: String(localized: "対象が見つかりません"), remedy: String(localized: "再読み込みしてから、やり直してください"))
        case "ambiguous": UserFacingError(event, cause: String(localized: "同じ内容のものが複数あります"), remedy: String(localized: "設定ファイルの重複を消してから、やり直してください"))
        // Codex が書けるのはユーザーの config.toml だけで、ほかのファイルと層のものは locked で断る
        case "locked" where engine == .codex: UserFacingError(event, cause: String(localized: "ユーザーの設定（config.toml）にないものは変更できません"))
        case "locked": UserFacingError(event, cause: String(localized: "組織の設定で固定されています"))
        case "conflict":
            UserFacingError(event, cause: String(localized: "設定のファイルがほかで書き換えられています"), remedy: String(localized: "再読み込みしてから、やり直してください"))
        case "file_error": UserFacingError(event, cause: String(localized: "設定のファイルを書き込めません"), remedy: String(localized: "ファイルの権限と書き方を確認してください"))
        case "invalid": UserFacingError(event, cause: String(localized: "入力の形式が正しくありません"), remedy: String(localized: "書き方を確認してください"))
        default: UserFacingError(event, remedy: UserFacingError.retry)
        }
    }

    /// 書けたが今の会話に効かないときの案内。効くなら nil
    static func notice(_ result: ConversationSettingsEditResult) -> String? {
        if let apps = result.appsNeedingAuth, !apps.isEmpty {
            return String(localized: "プラグインをインストールしました。使う前に、次のアプリへのログインが必要です：\(apps.joined(separator: "、"))")
        }
        return switch result.overriddenBy {
        case "permission_mode"?:
            String(localized: "設定を保存しました。アプリの会話では会話の権限のモードが優先されるため、この値は効きません。ターミナルで起動したCodexには効きます。")
        case let layer?:
            String(localized: "設定を保存しました。\(ConversationReadoutText.settingSource(layer))で上書きされているため、この会話には効きません。")
        case nil where result.needsRestart:
            String(localized: "設定を保存しました。この会話には、会話を終了して再開すると効きます。")
        case nil:
            nil
        }
    }

    static func sandboxMode(_ mode: String) -> String {
        switch mode {
        case "auto-allow": String(localized: "サンドボックスで動かし、自動で許可")
        case "regular": String(localized: "サンドボックスで動かし、権限の規則に従う")
        case "disabled": String(localized: "使わない")
        default: mode
        }
    }

    static func hookType(_ type: String) -> String {
        switch type {
        case "command": String(localized: "コマンド")
        case "prompt": String(localized: "プロンプト")
        case "http": String(localized: "HTTP")
        case "agent": String(localized: "エージェント")
        default: type
        }
    }

    static func hookContent(_ type: String) -> String {
        switch type {
        case "http": String(localized: "URL")
        case "prompt", "agent": String(localized: "プロンプト")
        default: String(localized: "コマンド")
        }
    }
}
