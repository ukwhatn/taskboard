import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// 読む画面のシート（`/export`・`/permissions`・`/hooks`・`/memory`・`/skills`・`/plugin`）。CLI の TUI の画面の代わり。
/// engine が書ける設定（`supports(edit:)`）は、その場で足す・外す・切り替える（`edit_settings`）
struct ConversationReadoutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model: AppModel?
    let readout: ConversationReadout
    let conversation: Conversation
    let feed: ConversationFeed
    @State private var exported: TextFile?
    @State private var failure: String?
    /// 書けたが今の会話に効かないときの案内
    @State private var notice: String?
    @State private var hookDraft: ConversationHookEditor.Draft?
    @State private var deletingHook: ConversationHooks.Hook?
    @State private var pluginReview: ConversationPluginReview?

    /// `notice` と `pluginReview` は snapshot 用（出しておく案内と確かめ）
    init(
        readout: ConversationReadout, conversation: Conversation, feed: ConversationFeed, notice: String? = nil, pluginReview: ConversationPluginReview? = nil
    ) {
        self.readout = readout
        self.conversation = conversation
        self.feed = feed
        _notice = State(initialValue: notice)
        _pluginReview = State(initialValue: pluginReview)
    }

    private var writer: ConversationSettingsWriter {
        ConversationSettingsWriter(
            feed: feed, readout: readout, engine: conversation.engine, failed: { failure = $0 }, noticed: { notice = $0 }, reviewing: { pluginReview = $0 })
    }

    private var machineName: String { model?.machineName(conversation.machine) ?? String(localized: "このMac") }

    private func canEdit(_ target: ConversationSettingsEdit.Target) -> Bool {
        conversation.engine.supports(edit: target) && conversation.phase != .stopped
    }

    var body: some View {
        SheetScaffold(title: ConversationReadoutText.title(readout), subtitle: conversation.displayTitle, error: failure, notice: notice) {
            ConversationWakeGate(conversation: conversation, feed: feed) {
                switch feed.readout {
                case .loaded(let value) where value.readout == readout: content(value)
                case .failed(let failure): Section { Text(failure.text).foregroundStyle(.secondary) }
                default: Section { ProgressView("読み込み中…").controlSize(.small) }
                }
            }
        } actions: {
            if case .loaded(.export(let export)) = feed.readout, readout == .export {
                Button("コピー") { Pasteboard.copy(export.text) }
                #if os(macOS)
                Button("書き出す…") { exported = TextFile(text: export.text) }
                #else
                ShareLink(item: export.text) { Text("共有") }
                #endif
            }
            if readout != .export {
                Button("再読み込み") { load() }.disabled(feed.readout.isLoading || feed.wake.isWaking)
            }
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        #if os(macOS)
        .frame(minHeight: ConversationMetrics.contextSheetHeight)
        #endif
        .onAppear { load() }
        .fileExporter(
            isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } }), document: exported, contentType: .plainText,
            defaultFilename: feed.readout.value.flatMap { if case .export(let export) = $0 { export.defaultFilename } else { nil } }
        ) { _ in exported = nil }
        .sheet(item: $hookDraft) { draft in ConversationHookEditor(draft: draft, writer: writer) }
        .confirmationDialog(
            "フックの削除", isPresented: Binding(get: { deletingHook != nil }, set: { if !$0 { deletingHook = nil } }), presenting: deletingHook
        ) { hook in
            Button("削除", role: .destructive) { remove(hook) }
            Button("キャンセル", role: .cancel) {}
        } message: { hook in
            Text("「\(hook.command)」を削除しますか？　この操作は元に戻せません。")
        }
    }

    private func load() {
        feed.load(waking: conversation) { feed.loadReadout(readout) }
    }

    private func remove(_ rule: ConversationPermissionRules.Rule) {
        guard let scope = ConversationSettingsScope(rawValue: rule.source) else { return }
        Task { _ = await writer.write(.permissionRule(op: .remove, behavior: rule.behavior, rules: [rule.rule], scope: scope), event: "規則を削除できませんでした") }
    }

    /// フックの編集と削除。Codex が書き換えるのはユーザーの config.toml の hook だけ（hooks.json とほかの層は断る）
    private func canReplace(_ hook: ConversationHooks.Hook) -> Bool {
        guard hook.editKey != nil, canEdit(.hook) else { return false }
        guard conversation.engine == .codex else { return true }
        return hook.source == "user" && hook.managed != true && hook.sourcePath?.hasSuffix("/config.toml") == true
    }

    private func setState(_ hook: ConversationHooks.Hook, enabled: Bool? = nil, trusted: Bool? = nil) {
        guard let key = hook.editKey else { return }
        Task { _ = await writer.write(.hookState(editKey: key, enabled: enabled, trusted: trusted), event: "フックの設定を保存できませんでした") }
    }

    private func remove(_ hook: ConversationHooks.Hook) {
        guard let scope = ConversationSettingsScope(rawValue: hook.source), let key = hook.editKey else { return }
        Task {
            _ = await writer.write(.hook(op: .remove, scope: scope, event: hook.event, matcher: hook.matcher, hook: nil, editKey: key), event: "フックを削除できませんでした")
        }
    }

    @ViewBuilder
    private func content(_ value: ConversationReadoutValue) -> some View {
        switch value {
        case .export(let export):
            Section {
                LabeledContent("ファイル名") { Text(verbatim: export.defaultFilename).lineLimit(1).truncationMode(.middle) }
            }
            Section("内容") {
                Text(verbatim: ConversationReadoutText.excerpt(export.text))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .permissions(let state):
            permissions(state)
        case .hooks(let state):
            hooks(state)
        case .memory(let state):
            Section {
                ForEach(Array(state.files.enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: Space.inline) {
                        Text(ConversationReadoutText.memoryKind(file.kind))
                        Text(verbatim: file.path).textRole(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        if !file.exists { Text("まだありません").textRole(.caption) }
                    }
                }
            }
            if canEdit(.memory) { ConversationMemoryToggles(memory: state, writer: writer, machineName: machineName) }
        case .skills(let state):
            if state.skills.isEmpty {
                Section { Text("スキルはありません").foregroundStyle(.secondary) }
            } else {
                Section {
                    ForEach(Array(state.skills.enumerated()), id: \.offset) { _, skill in
                        VStack(alignment: .leading, spacing: Space.inline) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                                Text(verbatim: skill.displayName).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: Space.row)
                                if canEdit(.skill) {
                                    ConversationSkillStatePicker(skill: skill, writer: writer)
                                } else {
                                    Text(ConversationReadoutText.skillState(skill.state)).textRole(.caption)
                                }
                            }
                            let description = skill.description.isEmpty ? (skill.shortDescription ?? "") : skill.description
                            if !description.isEmpty { Text(verbatim: description).textRole(.caption).lineLimit(2) }
                            MetaLine(
                                items: [ConversationReadoutText.source(skill.source)] + (skill.plugin.map { [$0] } ?? [])
                                    + (skill.tokens.map { [String(localized: "\($0)トークン")] } ?? []))
                        }
                    }
                }
            }
            problems(state.problems)
        case .plugins(let state):
            ConversationPluginsSections(
                plugins: state, feed: feed, writer: writer, machineName: machineName, canEdit: canEdit(.plugin) && canEdit(.marketplace),
                review: $pluginReview)
        }
    }

    /// codex が読めなかった設定のファイル。理由の文（codex の英語）は出さない
    @ViewBuilder
    private func problems(_ problems: [ConversationReadoutProblem]?) -> some View {
        if let problems, !problems.isEmpty {
            Section {
                ForEach(problems, id: \.path) { problem in
                    Text(verbatim: problem.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
            } header: {
                Text("読み込めなかったファイル")
            } footer: {
                Text("ファイルの書き方を確認してください。")
            }
            .id("problems")
        }
    }

    @ViewBuilder
    private func permissions(_ state: ConversationPermissionRules) -> some View {
        let settings = state.settings ?? []
        if state.rules.isEmpty, settings.isEmpty {
            Section { Text("権限の規則はありません").foregroundStyle(.secondary) }
        }
        if !settings.isEmpty {
            Section("権限の設定") {
                ForEach(Array(settings.enumerated()), id: \.offset) { _, setting in
                    VStack(alignment: .leading, spacing: Space.inline) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Text(verbatim: setting.key).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
                            Spacer(minLength: Space.row)
                            Text(verbatim: setting.value).font(.callout.monospaced()).lineLimit(2).textSelection(.enabled)
                        }
                        MetaLine(items: [ConversationReadoutText.settingSource(setting.source)])
                    }
                }
            }
        }
        ForEach(["allow", "ask", "deny"], id: \.self) { behavior in
            let rules = state.rules.filter { $0.behavior == behavior }
            if !rules.isEmpty {
                Section(ConversationReadoutText.behavior(behavior)) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            VStack(alignment: .leading, spacing: Space.inline) {
                                Text(verbatim: rule.rule).font(.callout.monospaced()).lineLimit(3).textSelection(.enabled)
                                MetaLine(items: [ConversationReadoutText.source(rule.source)])
                            }
                            Spacer(minLength: Space.row)
                            if rule.editable == true, canEdit(.permissionRule) {
                                Button("規則を削除", systemImage: "trash") { remove(rule) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help("規則を削除")
                            }
                        }
                    }
                }
            }
        }
        if !state.directories.isEmpty {
            Section("追加した作業フォルダ") {
                ForEach(Array(state.directories.enumerated()), id: \.offset) { _, directory in
                    VStack(alignment: .leading, spacing: Space.inline) {
                        Text(verbatim: directory.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        MetaLine(items: [ConversationReadoutText.source(directory.source)])
                    }
                }
            }
        }
        if canEdit(.permissionSetting) { CodexPermissionSettingsSection(settings: settings, writer: writer, machineName: machineName).id("edit-settings") }
        if canEdit(.permissionRule) { PermissionRuleAdder(writer: writer, machineName: machineName).id("add-rule") }
        if canEdit(.sandbox) { ConversationSandboxSection(feed: feed, writer: writer).id("sandbox") }
    }

    @ViewBuilder
    private func hooks(_ state: ConversationHooks) -> some View {
        if state.hooks.isEmpty {
            Section { Text("フックはありません").foregroundStyle(.secondary) }
        }
        let events = state.hooks.map(\.event).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        ForEach(events, id: \.self) { event in
            Section {
                ForEach(Array(state.hooks.filter { $0.event == event }.enumerated()), id: \.offset) { _, hook in
                    VStack(alignment: .leading, spacing: Space.inline) {
                        Text(verbatim: hook.command).font(.callout.monospaced()).lineLimit(3).textSelection(.enabled)
                        MetaLine(
                            items: [hook.matcher.isEmpty ? String(localized: "すべて") : hook.matcher, ConversationReadoutText.source(hook.source)]
                                + (hook.plugin.map { [$0] } ?? []))
                        if let state = ConversationReadoutText.hookState(hook) {
                            Label(state, systemImage: "exclamationmark.triangle").textRole(.caption)
                        }
                        let stateEditable = hook.editKey != nil && hook.managed != true && canEdit(.hookState)
                        if canReplace(hook) || stateEditable {
                            HStack(spacing: Space.row) {
                                if canReplace(hook) {
                                    Button("編集") { hookDraft = ConversationHookEditor.Draft(hook, engine: conversation.engine) }
                                    Button("削除", role: .destructive) { deletingHook = hook }
                                }
                                if stateEditable {
                                    if hook.enabled == false {
                                        Button("有効にする") { setState(hook, enabled: true) }
                                    } else {
                                        Button("無効にする") { setState(hook, enabled: false) }
                                    }
                                    if hook.trust == "trusted" {
                                        Button("信頼を外す") { setState(hook, trusted: false) }
                                    } else if hook.trust != nil {
                                        Button("信頼する") { setState(hook, trusted: true) }
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                        }
                    }
                }
            } header: {
                Text(verbatim: event)
            }
        }
        problems(state.problems)
        if canEdit(.hook) {
            Section {
                Button("フックを追加") { hookDraft = ConversationHookEditor.Draft(engine: conversation.engine) }
            }
            .id("add-hook")
        }
    }
}

/// 書き出した会話の文（`fileExporter` に渡す）
struct TextFile: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

/// 読む画面の文字
enum ConversationReadoutText {
    /// シートに出す書き出しの長さ。全文は［コピー］と書き出しで渡す
    static let excerptLimit = 20_000

    static func title(_ readout: ConversationReadout) -> String {
        switch readout {
        case .export: String(localized: "会話の書き出し")
        case .permissions: String(localized: "権限の規則")
        case .hooks: String(localized: "フック")
        case .memory: String(localized: "メモリ")
        case .skills: String(localized: "スキル")
        case .plugins: String(localized: "プラグイン")
        }
    }

    static func loginTitle(_ engine: Conversation.Engine) -> String {
        switch engine {
        case .codex: String(localized: "Codexのログイン")
        case .claude, .unknown: String(localized: "Claudeのログイン")
        }
    }

    static func loadFailure(_ readout: ConversationReadout) -> LocalizedStringResource {
        switch readout {
        case .export: "会話を書き出せませんでした"
        case .permissions: "権限の規則を読み込めませんでした"
        case .hooks: "フックを読み込めませんでした"
        case .memory: "メモリを読み込めませんでした"
        case .skills: "スキルを読み込めませんでした"
        case .plugins: "プラグインを読み込めませんでした"
        }
    }

    static func excerpt(_ text: String) -> String {
        text.count > excerptLimit ? String(text.prefix(excerptLimit)) + "…" : text
    }

    static func behavior(_ behavior: String) -> String {
        switch behavior {
        case "allow": String(localized: "許可")
        case "deny": String(localized: "拒否")
        default: String(localized: "毎回確認")
        }
    }

    /// 規則・フック・作業フォルダ・スキルの出どころ。知らない名前はそのまま出す
    static func source(_ source: String) -> String {
        switch source {
        case "userSettings", "user": String(localized: "ユーザーの設定")
        case "projectSettings", "project": String(localized: "プロジェクトの設定")
        case "localSettings", "local": String(localized: "ローカルの設定")
        case "policySettings", "policy", "managed": String(localized: "組織の設定")
        case "flagSettings", "cliArg": String(localized: "起動の引数")
        case "session", "sessionHook": String(localized: "この会話だけ")
        case "pluginHook", "plugin": String(localized: "プラグイン")
        case "command": String(localized: "コマンド")
        case "built-in", "bundled", "system": String(localized: "組み込み")
        case "repo": String(localized: "リポジトリ")
        case "admin", "mdm": String(localized: "組織の設定")
        default: source
        }
    }

    /// codex の設定の層（config.toml の origins）。session は今の会話に効いている値
    static func settingSource(_ source: String) -> String {
        switch source {
        case "session": String(localized: "今の会話に効いている値")
        case "system": String(localized: "Mac全体の設定")
        default: Self.source(source)
        }
    }

    /// フックが動かない理由（codex の無効と信頼）。動くなら nil
    static func hookState(_ hook: ConversationHooks.Hook) -> String? {
        if hook.enabled == false { return String(localized: "無効のため動きません") }
        switch hook.trust {
        case "untrusted": return String(localized: "信頼していないため動きません")
        case "modified": return String(localized: "信頼した後に変更されたため動きません")
        default: return nil
        }
    }

    static func memoryKind(_ kind: String) -> String {
        switch kind {
        case "user": String(localized: "ユーザーの指示")
        case "project": String(localized: "プロジェクトの指示")
        case "project-alt": String(localized: "プロジェクトの指示（.claude）")
        case "local": String(localized: "ローカルの指示")
        default: String(localized: "そのほかの指示")
        }
    }

    static func skillState(_ state: String) -> String {
        switch state {
        case "on": String(localized: "有効")
        case "off": String(localized: "無効")
        case "name-only": String(localized: "名前だけ")
        case "user-invocable-only": String(localized: "呼び出したときだけ")
        default: state
        }
    }

    static func taskType(_ type: String?) -> String {
        switch type {
        case "local_bash": String(localized: "シェル")
        case "local_agent": String(localized: "サブエージェント")
        case "monitor": String(localized: "監視")
        default: String(localized: "タスク")
        }
    }

    static func folderTitle(_ action: ConversationFolderAction) -> String {
        switch action {
        case .add: String(localized: "作業フォルダの追加")
        case .change: String(localized: "作業フォルダの移動")
        }
    }

    /// `/add-dir` を断られたとき。Claude Code が受けるのは今の作業フォルダの下だけ
    /// 接続の失敗はその理由を、Claude Code の断りは追加できるフォルダの案内を出す
    static func addRefusal(_ error: any Error) -> String {
        let event: LocalizedStringResource = "作業フォルダを追加できませんでした"
        switch error {
        case is URLError, AppModel.ActionError.notWritable, SessionSourceError.disconnected, SessionSourceError.unauthorized, SessionSourceError.forbidden:
            return UserFacingError(event, error: error)?.text ?? String(localized: event)
        default:
            return String(localized: "作業フォルダを追加できませんでした。追加できるのは今の作業フォルダの下のフォルダだけです。")
        }
    }

    /// `/cd` の答えが移動でないとき。nil なら移動した
    static func changeRefusal(_ change: ConversationCwdChange) -> String? {
        switch change.outcome {
        case .moved: return nil
        case .needsTrust:
            return String(localized: "作業フォルダを移動できませんでした。このフォルダはまだ信頼されていません。ターミナルでこのフォルダに移ってClaude Codeを起動し、信頼してください。")
        case .rejected:
            switch change.reason {
            case "not_found": return String(localized: "作業フォルダを移動できませんでした。フォルダが見つかりません。パスを確かめてください。")
            case "not_a_directory": return String(localized: "作業フォルダを移動できませんでした。フォルダでないものが指定されています。フォルダのパスを入力してください。")
            case "blocked_by_rule": return String(localized: "作業フォルダを移動できませんでした。権限の規則でこのフォルダへの移動が禁止されています。")
            case "busy": return String(localized: "作業フォルダを移動できませんでした。応答の生成中です。応答が終わってから移動してください。")
            default: return String(localized: "作業フォルダを移動できませんでした。時間をおいて、やり直してください。")
            }
        case .unknown:
            return String(localized: "作業フォルダを移動できませんでした。時間をおいて、やり直してください。")
        }
    }
}
