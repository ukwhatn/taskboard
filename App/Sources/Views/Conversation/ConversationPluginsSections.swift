import SwiftUI
import TaskboardKit

/// plugin と marketplace の書き込みで、daemon が書かずに人の確かめを求めたもの
struct ConversationPluginReview {
    enum Kind {
        /// marketplace が決めたコマンドを動かして入れる
        case command(ConversationSettingsEditResult.ShownCommand)
        /// 書くと元に戻せないもの（データ・保存した設定）が消える
        case confirmation(ConversationSettingsEditResult.Confirmation)
    }

    let edit: ConversationSettingsEdit
    let kind: Kind
    let event: LocalizedStringResource

    init?(edit: ConversationSettingsEdit, result: ConversationSettingsEditResult, event: LocalizedStringResource) {
        if let command = result.shownCommand {
            kind = .command(command)
        } else if let confirmation = result.confirmation {
            kind = .confirmation(confirmation)
        } else {
            return nil
        }
        self.edit = edit
        self.event = event
    }

    /// 人が確かめた後に送り直す要求
    var resent: ConversationSettingsEdit {
        switch kind {
        case .command(let command): edit.accepting(command: command.sha256)
        case .confirmation(let confirmation): edit.confirming(digest: confirmation.digest)
        }
    }
}

/// ［プラグイン］のシートの中身（`/plugin`）。入れた plugin、入れられる plugin、marketplace
struct ConversationPluginsSections: View {
    let plugins: ConversationPlugins
    let feed: ConversationFeed
    let writer: ConversationSettingsWriter
    let machineName: String
    let canEdit: Bool
    @Binding var review: ConversationPluginReview?
    @State private var query: String
    @State private var scope = ConversationSettingsScope.user
    @State private var source = ""
    @State private var saving = false

    init(
        plugins: ConversationPlugins, feed: ConversationFeed, writer: ConversationSettingsWriter, machineName: String, canEdit: Bool,
        review: Binding<ConversationPluginReview?>
    ) {
        self.plugins = plugins
        self.feed = feed
        self.writer = writer
        self.machineName = machineName
        self.canEdit = canEdit
        _review = review
        _query = State(initialValue: feed.pluginQuery)
    }

    private var engine: Conversation.Engine { writer.engine }

    var body: some View {
        if let review { reviewSection(review).id("review") }
        installed
        available
        marketplaces
    }

    // MARK: 入れた plugin

    private var installed: some View {
        Section("インストールしたプラグイン") {
            if plugins.installed.isEmpty {
                Text("インストールしたプラグインはありません").foregroundStyle(.secondary)
            }
            ForEach(plugins.installed, id: \.self) { plugin in
                VStack(alignment: .leading, spacing: Space.inline) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Text(verbatim: plugin.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.row)
                        if canEdit, let enabled = plugin.enabled {
                            ConversationPluginToggle(plugin: plugin, enabled: enabled, writer: writer)
                        } else if plugin.enabled == false {
                            Text("無効").textRole(.caption)
                        }
                    }
                    description(plugin)
                    MetaLine(items: meta(plugin))
                    if canEdit {
                        HStack(spacing: Space.row) {
                            Button("アップデート") { write(.plugin(op: .update, id: plugin.id, scope: scope(of: plugin)), event: "プラグインをアップデートできませんでした") }
                            Button("アンインストール", role: .destructive) {
                                write(.plugin(op: .uninstall, id: plugin.id, scope: scope(of: plugin)), event: "プラグインをアンインストールできませんでした")
                            }
                            // codex は外してもデータの置き場を消さない
                            if engine == .claude {
                                Button("データごとアンインストール", role: .destructive) {
                                    write(.plugin(op: .purge, id: plugin.id, scope: scope(of: plugin)), event: "プラグインをアンインストールできませんでした")
                                }
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(saving)
                    }
                }
            }
        }
    }

    // MARK: 入れられる plugin

    private var available: some View {
        Section {
            LabeledTextField(label: String(localized: "絞り込み"), text: $query)
            if engine == .claude, canEdit { ConversationScopePicker(scope: $scope) }
            if plugins.available.isEmpty {
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("インストールできるプラグインはありません")
                    } else {
                        Text("条件に合うプラグインはありません")
                    }
                }
                .foregroundStyle(.secondary)
            }
            ForEach(plugins.available, id: \.self) { plugin in
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    VStack(alignment: .leading, spacing: Space.inline) {
                        Text(verbatim: plugin.name).lineLimit(1).truncationMode(.middle)
                        description(plugin)
                        MetaLine(items: meta(plugin))
                    }
                    Spacer(minLength: Space.row)
                    if canEdit {
                        Button("インストール") {
                            write(.plugin(op: .install, id: plugin.id, scope: engine == .claude ? scope : nil), event: "プラグインをインストールできませんでした")
                        }
                        .buttonStyle(.borderless)
                        .disabled(saving)
                    }
                }
            }
        } header: {
            Text("インストールできるプラグイン")
        } footer: {
            VStack(alignment: .leading, spacing: Space.inline) {
                if plugins.availableTotal > plugins.available.count {
                    Text("\(plugins.availableTotal)件のうち\(plugins.available.count)件を表示しています。絞り込むと、ほかのプラグインも表示できます。")
                }
                if canEdit, engine == .codex {
                    Text("ユーザーの設定（config.toml）に保存し、\(machineName)のすべてのCodexに効きます。")
                } else if canEdit {
                    Text("ユーザーの設定は\(machineName)のすべての会話に効きます。")
                }
            }
        }
        .task(id: query) {
            // 打つたびに引かない。絞った結果は daemon が返す
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, feed.pluginQuery != query else { return }
            feed.pluginQuery = query
            feed.loadReadout(.plugins)
        }
    }

    // MARK: marketplace

    private var marketplaces: some View {
        Section {
            if plugins.marketplaces.isEmpty {
                Text("マーケットプレイスはありません").foregroundStyle(.secondary)
            }
            ForEach(plugins.marketplaces, id: \.self) { marketplace in
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    VStack(alignment: .leading, spacing: Space.inline) {
                        Text(verbatim: marketplace.name).lineLimit(1).truncationMode(.middle)
                        if let source = marketplace.source {
                            Text(verbatim: source).textRole(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: Space.row)
                    if canEdit {
                        HStack(spacing: Space.row) {
                            Button("アップデート") {
                                write(.marketplace(op: .update, name: marketplace.name), event: "マーケットプレイスをアップデートできませんでした")
                            }
                            Button("削除", role: .destructive) {
                                write(.marketplace(op: .remove, name: marketplace.name), event: "マーケットプレイスを削除できませんでした")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(saving)
                    }
                }
            }
            if canEdit {
                LabeledTextField(label: String(localized: "取得元"), text: $source, monospaced: true)
                    .onSubmit { addMarketplace() }
                Button("マーケットプレイスを追加") { addMarketplace() }
                    .disabled(saving || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("マーケットプレイス")
        } footer: {
            if canEdit { Text("例：owner/repo、URL、フォルダのパス") }
        }
    }

    // MARK: 確かめ

    @ViewBuilder
    private func reviewSection(_ review: ConversationPluginReview) -> some View {
        Section {
            switch review.kind {
            case .command(let command):
                Text("「\(ConversationPluginsText.target(review.edit))」は、マーケットプレイスが指定した次のコマンドを実行します。")
                Text(verbatim: command.command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .confirmation(let confirmation):
                Text(ConversationPluginsText.confirmation(review.edit, confirmation))
            }
            HStack(spacing: Space.row) {
                Spacer()
                Button("キャンセル") { self.review = nil }
                Button(ConversationPluginsText.confirmButton(review), role: review.isDestructive ? .destructive : nil) {
                    self.review = nil
                    write(review.resent, event: review.event)
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            }
        } header: {
            Text(ConversationPluginsText.reviewTitle(review))
        }
    }

    // MARK: 部品

    @ViewBuilder
    private func description(_ plugin: ConversationPlugins.Plugin) -> some View {
        if let description = plugin.description, !description.isEmpty {
            Text(verbatim: description).textRole(.caption).lineLimit(2)
        }
    }

    private func meta(_ plugin: ConversationPlugins.Plugin) -> [String] {
        [plugin.marketplace] + (plugin.version.map { [$0] } ?? []) + (plugin.scope.map { [ConversationReadoutText.source($0)] } ?? [])
    }

    private func scope(of plugin: ConversationPlugins.Plugin) -> ConversationSettingsScope? {
        ConversationPluginsText.scope(of: plugin, engine: engine)
    }

    private func addMarketplace() {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !saving else { return }
        saving = true
        Task {
            if await writer.write(.marketplace(op: .add, source: text), event: "マーケットプレイスを追加できませんでした") { source = "" }
            saving = false
        }
    }

    private func write(_ edit: ConversationSettingsEdit, event: LocalizedStringResource) {
        guard !saving else { return }
        saving = true
        Task {
            _ = await writer.write(edit, event: event)
            saving = false
        }
    }
}

/// 入れた plugin の有効と無効
private struct ConversationPluginToggle: View {
    let plugin: ConversationPlugins.Plugin
    let enabled: Bool
    let writer: ConversationSettingsWriter
    @State private var state = PendingValue<Bool>()

    var body: some View {
        Toggle("有効", isOn: Binding.pending($state, current: enabled) { value in
            let scope = ConversationPluginsText.scope(of: plugin, engine: writer.engine)
            return await writer.write(.plugin(op: value ? .enable : .disable, id: plugin.id, scope: scope), event: "プラグインの設定を保存できませんでした")
        })
        .labelsHidden()
        .onChange(of: enabled) { _, current in
            if state.shown(current) == current { state.settle() }
        }
    }
}

extension ConversationPluginReview {
    var isDestructive: Bool {
        if case .confirmation = kind { true } else { false }
    }
}

/// ［プラグイン］のシートの確かめの文
enum ConversationPluginsText {
    /// 入れた層（user・project・local）で書く。codex はユーザーの設定だけで、層を送らない
    static func scope(of plugin: ConversationPlugins.Plugin, engine: Conversation.Engine) -> ConversationSettingsScope? {
        guard engine == .claude else { return nil }
        return plugin.scope.flatMap { ConversationSettingsScope(rawValue: $0) ?? ConversationSettingsScope(rawValue: "\($0)Settings") }
    }

    static func target(_ edit: ConversationSettingsEdit) -> String {
        switch edit {
        case .plugin(_, let id, _, _, _, _): id
        case .marketplace(_, let source, let name, _, _, _): name ?? source ?? ""
        default: ""
        }
    }

    static func reviewTitle(_ review: ConversationPluginReview) -> String {
        switch (review.kind, review.edit) {
        case (.command, .plugin(.update, _, _, _, _, _)): String(localized: "コマンドでのアップデート")
        case (.command, _): String(localized: "コマンドでのインストール")
        case (.confirmation, .marketplace): String(localized: "マーケットプレイスの削除")
        case (.confirmation, _): String(localized: "プラグインのアンインストール")
        }
    }

    static func confirmButton(_ review: ConversationPluginReview) -> String {
        switch (review.kind, review.edit) {
        case (.command, .plugin(.update, _, _, _, _, _)): String(localized: "このコマンドでアップデート")
        case (.command, _): String(localized: "このコマンドでインストール")
        case (.confirmation, .marketplace): String(localized: "削除")
        case (.confirmation, .plugin(.purge, _, _, _, _, _)): String(localized: "データごとアンインストール")
        case (.confirmation, _): String(localized: "アンインストール")
        }
    }

    /// 何が消えるかを名前で出す（設定の値は daemon が返さない）
    static func confirmation(_ edit: ConversationSettingsEdit, _ confirmation: ConversationSettingsEditResult.Confirmation) -> String {
        let name = target(edit)
        var lines: [String] = []
        switch edit {
        case .marketplace:
            lines.append(String(localized: "「\(name)」を削除しますか？"))
            let plugins = confirmation.plugins.map(\.id)
            if !plugins.isEmpty { lines.append(String(localized: "次のプラグインもアンインストールされます：\(plugins.joined(separator: "、"))")) }
        case .plugin(.purge, _, _, _, _, _):
            lines.append(String(localized: "「\(name)」をデータごとアンインストールしますか？　この操作は元に戻せません。"))
        default:
            lines.append(String(localized: "「\(name)」をアンインストールしますか？"))
        }
        if !confirmation.options.isEmpty {
            lines.append(String(localized: "保存した設定（\(confirmation.options.joined(separator: "、"))）が消え、インストールし直しても戻りません。"))
        }
        return lines.joined(separator: "\n")
    }
}
