import SwiftUI
import TaskboardKit

/// タスクの詳細の欄の「会話」の節と、上の帯の［状態］。開いている会話の環境（マシン・作業フォルダ・ブランチ）、engine の会話の値（会話ID・モデル・版・
/// 費用・トークン・コンテキスト）、利用枠、起こした側と委譲先、フォーク元とフォーク、コネクタ
struct ConversationInspector: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let feed: ConversationFeed
    /// 委譲先を並べるか（タスクの右の欄では札で見るので並べない。フォークは発言の［フォーク{n}件］から来るのでどちらにも出す）
    var showsDelegates = true

    /// フォークの節の id（発言の［フォーク{n}件］で、右の欄をここまで送る）
    static let forksAnchor = "forks"
    @State private var copied = false

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ConversationInspector")
        #endif
        let stats = conversation.currentStats
        VStack(alignment: .leading, spacing: Space.block) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.block, verticalSpacing: Space.row) {
                row("Mac") { Text(verbatim: model.machineName(conversation.machine)) }
                row("作業フォルダ") {
                    Text(verbatim: conversation.cwd).textRole(.mono).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                if let branch = conversation.diff?.branch {
                    row("ブランチ") { Text(verbatim: branch).textRole(.mono).lineLimit(1).truncationMode(.middle) }
                }
                row("会話ID", hidesLabel: true) { sessionID }
                row("モデル") {
                    // Codex のモデルは一覧の名前で出す（入力欄の下の欄と同じ名前）
                    if conversation.engine == .codex, let options = model.modelOptions(for: conversation) {
                        Text(verbatim: options.label(conversation.model))
                    } else {
                        Text(verbatim: ConversationStatsText.model(chosen: conversation.model, resolved: stats?.model, models: model.claudeModels(on: conversation.machine)))
                    }
                }
                if let version = ConversationStatsText.version(conversation.engine, stats?.engineVersion) {
                    row("版") { Text(verbatim: version) }
                }
                if let cost = stats?.costUSD {
                    row("費用") { Text(verbatim: ConversationStatsText.cost(cost)).monospacedDigit() }
                }
                if let tokens = stats?.tokens {
                    row("トークン") {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("入力\(ConversationStatsText.count(tokens.input))・出力\(ConversationStatsText.count(tokens.output))")
                            Text("キャッシュの読み込み\(ConversationStatsText.count(tokens.cacheRead))・書き込み\(ConversationStatsText.count(tokens.cacheWrite))")
                        }
                        .monospacedDigit()
                    }
                }
                row("コンテキスト") { context(stats) }
                if let usage = model.fleet.usage(for: conversation.machine), !windows(usage, now: Date()).isEmpty {
                    row("利用枠") {
                        LiveClock { now in usageRows(windows(usage, now: now)) }
                    }
                }
                if let parent {
                    row("委譲元") {
                        Button(action: parent.open) { Text(verbatim: parent.title).lineLimit(1).truncationMode(.tail) }
                            .buttonStyle(.borderless)
                            .hitTarget()
                    }
                }
                if let id = conversation.forkSource, let source = model.fleet.conversation(for: ConversationKey(machine: conversation.machine, id: id)) {
                    row("フォーク元") {
                        Button { model.navigate(to: .conversation(source.key), from: .link) } label: {
                            Text(verbatim: source.displayTitle).lineLimit(1).truncationMode(.tail)
                        }
                        .buttonStyle(.borderless)
                        .hitTarget()
                    }
                }
            }
            .font(.callout)
            if showsDelegates {
                delegates
            }
            forks
            if conversation.engine.supports(field: .mcp) {
                VStack(alignment: .leading, spacing: Space.row) {
                    Text("コネクタ").textRole(.caption)
                    connectors
                }
            }
        }
        // パネルは別のタスクを開いても作り直さないので、出す会話が替わったときにも読む
        .onChange(of: conversation.key, initial: true) {
            guard conversation.engine.supports(field: .mcp) else { return }
            if conversation.phase != .stopped || feed.phase == .fixture, feed.connectors.value == nil { feed.loadConnectors() }
        }
    }

    /// `hidesLabel` は、値の側が同じ名前を読み上げのラベルに持つとき（見出しと値を 1 つに読む）
    private func row<Value: View>(_ label: String, hidesLabel: Bool = false, @ViewBuilder value: () -> Value) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading).accessibilityHidden(hidesLabel)
            value().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionID: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            Text(verbatim: conversation.agentSessionID).textRole(.mono).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .accessibilityLabel("会話ID")
                .accessibilityValue(conversation.agentSessionID)
            Button(copied ? "コピーしました" : "会話IDをコピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                Pasteboard.copy(conversation.agentSessionID)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .hitTarget()
            .help("会話IDをコピー")
        }
    }

    @ViewBuilder
    private func context(_ stats: ConversationStats?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            if let percent = conversation.contextPercent {
                Text(UsageText.percent(Double(percent))).monospacedDigit().foregroundStyle(ContextUsage.color(Double(percent)))
            }
            if let used = stats?.contextTokens, let window = stats?.contextWindow {
                Text(verbatim: "\(UsageText.tokens(used) ?? "")／\(UsageText.tokens(window) ?? "")").monospacedDigit().foregroundStyle(.secondary)
            }
            if conversation.contextPercent == nil && stats?.contextTokens == nil {
                Text("未取得").foregroundStyle(.secondary)
            }
            Button("内訳を表示") { feed.sheet = .context }
                .buttonStyle(.borderless)
                .hitTarget()
        }
    }

    private func windows(_ usage: UsageSnapshot, now: Date) -> [UsageRowModel] {
        UsageText.rows(usage, engine: conversation.engine, account: conversation.account, now: now)
    }

    private func usageRows(_ windows: [UsageRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(windows) { window in
                HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                    Text(window.label)
                    Text(UsageText.percent(window.now)).monospacedDigit().foregroundStyle(UsageLevel(now: window.now, projected: nil).textColor)
                    if !window.reset.isEmpty {
                        Text("\(window.reset)にリセット").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 委譲先の会話のとき、起こした会話
    private var parent: (title: String, open: () -> Void)? {
        if let id = conversation.parentConversationID, let lead = model.fleet.conversation(for: ConversationKey(machine: conversation.machine, id: id)) {
            return (lead.displayTitle, { model.navigate(to: .conversation(lead.key), from: .link) })
        }
        return nil
    }

    /// この会話が起こした会話（サイドバーとタスクの帯に出ないので、ここから開く）
    @ViewBuilder
    private var delegates: some View {
        let delegates = model.fleet.delegates(of: conversation)
        if !delegates.isEmpty {
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("委譲先").textRole(.caption)
                ForEach(delegates) { child in
                    delegateRow(title: child.displayTitle, details: [StatusAppearance.of(child).label, String(localized: "会話")]) {
                        StatusGlyph(conversation: child)
                    } open: {
                        model.navigate(to: .conversation(child.key), from: .link)
                    }
                }
            }
        }
    }

    /// この会話からフォークした会話
    @ViewBuilder
    private var forks: some View {
        if case let forks = model.fleet.forks(of: conversation), !forks.isEmpty {
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("フォーク").textRole(.caption)
                ForEach(forks) { fork in
                    delegateRow(title: fork.displayTitle, details: [StatusAppearance.of(fork).label, String(localized: "会話")]) {
                        StatusGlyph(conversation: fork)
                    } open: {
                        model.navigate(to: .conversation(fork.key), from: .link)
                    }
                }
            }
            .id(Self.forksAnchor)
        }
    }

    private func delegateRow<Glyph: View>(title: String, details: [String], @ViewBuilder glyph: () -> Glyph, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                glyph().accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.callout).lineLimit(1).truncationMode(.tail)
                    MetaLine(items: details)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hitTarget()
        .accessibilityElement(children: .combine)
        .accessibilityHint("押すと開きます")
    }

    private var wakeButton: some View {
        Button("表示") { feed.load(waking: conversation) { feed.loadConnectors() } }
            .buttonStyle(.borderless)
            .font(.callout)
            .hitTarget()
    }

    @ViewBuilder
    private var connectors: some View {
        if conversation.phase == .stopped && feed.phase != .fixture && feed.connectors.value == nil {
            // 開いているだけでは起こさない。押したときに起こして読む
            switch feed.wake {
            case .waking:
                ProgressView().controlSize(.small)
            case .failed(let failure):
                VStack(alignment: .leading, spacing: Space.inline) {
                    Text(failure.text).textRole(.secondary)
                    wakeButton
                }
            case .idle:
                wakeButton
            }
        } else {
            switch feed.connectors {
            case .idle, .loading:
                ProgressView().controlSize(.small)
            case .failed(let failure):
                Text(failure.text).textRole(.secondary)
            case .loaded(let servers) where servers.isEmpty:
                Text("コネクタはありません").textRole(.secondary)
            case .loaded(let servers):
                // 全部を並べると数十行になるので、手当ての要る接続できないものだけを名前で出し、ほかは件数にする
                let groups = ConnectorGroups(servers)
                VStack(alignment: .leading, spacing: Space.inline) {
                    ForEach(groups.failed) { server in
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Image(systemName: ConversationChoices.connectorSymbol(server.status))
                                .foregroundStyle(ConversationChoices.connectorColor(server.status))
                                .accessibilityHidden(true)
                            Text(verbatim: server.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: Space.row)
                            Text(ConversationChoices.connectorLabel(server.status)).textRole(.caption)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                    MetaLine(items: groups.counts)
                    Button("コネクタを管理") { feed.sheet = .connectors }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .hitTarget()
                }
            }
        }
    }
}

/// コンテキストの区分ごとのトークン（`/context` と、［状態］の［内訳を表示］と、入力欄の下のコンテキストの欄）
struct ConversationContextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let feed: ConversationFeed

    var body: some View {
        SheetScaffold(title: String(localized: "コンテキストの内訳"), subtitle: conversation.displayTitle) {
            ConversationWakeGate(conversation: conversation, feed: feed) { content }
        } actions: {
            Button("再読み込み") { load() }.disabled(feed.contextBreakdown.isLoading || feed.wake.isWaking)
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        #if os(macOS)
        .frame(minHeight: ConversationMetrics.contextSheetHeight)
        #endif
        .onAppear { load() }
        // `/clear` などで engine の会話が替わったら、前の会話の内訳を出さずに取り直す
        .onChange(of: conversation.agentSessionID) {
            if conversation.phase != .stopped { feed.loadContextBreakdown() }
        }
    }

    private func load() {
        feed.load(waking: conversation) { feed.loadContextBreakdown() }
    }

    @ViewBuilder
    private var content: some View {
        switch feed.contextBreakdown {
        case .loaded(let breakdown) where breakdown.agentSessionID == conversation.agentSessionID:
            Section {
                LabeledContent("合計") {
                    Text("\(ConversationStatsText.count(breakdown.totalTokens))トークン（\(UsageText.percent(ConversationStatsText.share(breakdown.totalTokens, of: breakdown.maxTokens)))）")
                        .monospacedDigit()
                }
                LabeledContent("上限") { Text("\(ConversationStatsText.count(breakdown.maxTokens))トークン").monospacedDigit() }
                if let threshold = breakdown.autoCompactThreshold {
                    LabeledContent("自動圧縮を始める量") { Text("\(ConversationStatsText.count(threshold))トークン").monospacedDigit() }
                    if threshold > breakdown.totalTokens {
                        LabeledContent("自動圧縮までの残り") { Text("\(ConversationStatsText.count(threshold - breakdown.totalTokens))トークン").monospacedDigit() }
                    }
                }
            }
            categories("使用中", breakdown.categories.filter { $0.kind == .used })
            categories("使うときに読み込むもの", breakdown.categories.filter { $0.kind == .deferred })
            categories("空き", breakdown.categories.filter { [.buffer, .free, .other].contains($0.kind) })
        case .failed(let failure):
            Section { Text(failure.text).foregroundStyle(.secondary) }
        default:
            Section { ProgressView("読み込み中…").controlSize(.small) }
        }
    }

    @ViewBuilder
    private func categories(_ title: LocalizedStringKey, _ items: [ConversationContextBreakdown.Category]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, category in
                    LabeledContent(ConversationStatsText.categoryName(category.name)) {
                        Text(verbatim: ConversationStatsText.count(category.tokens)).monospacedDigit()
                    }
                }
            }
        }
    }
}

/// 会話の値の文字
enum ConversationStatsText {
    private static let locale = Locale(identifier: "ja_JP")

    /// 1セント未満は4桁で出す（短い会話の $0.0094 を $0.01 に丸めない）
    static func cost(_ usd: Double) -> String {
        String(format: usd > 0 && usd < 0.01 ? "$%.4f" : "$%.2f", usd)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// 0〜100。上限が 0 なら 0
    static func share(_ value: Int, of total: Int) -> Double {
        total > 0 ? Double(value) / Double(total) * 100 : 0
    }

    /// 選んだモデルの名前。既定のときは、engine が解決した名前を添える。選んだものと違うモデルで動いていれば、それも添える
    static func model(chosen: String?, resolved: String?, models: ClaudeModels) -> String {
        guard let chosen else { return resolved.map { String(localized: "デフォルト（\($0)）") } ?? String(localized: "デフォルトのモデル") }
        let label = models.label(chosen)
        guard let resolved, resolved != chosen else { return label }
        if let picked = models.model(named: chosen), picked == models.model(named: resolved) { return label }
        return "\(label)（\(resolved)）"
    }

    static func version(_ engine: Conversation.Engine, _ version: String?) -> String? {
        guard let version else { return nil }
        switch engine {
        case .claude: return "Claude Code \(version)"
        case .codex: return "Codex \(version)"
        case .unknown: return version
        }
    }

    /// Claude Code が付けた区分の名前。知らない名前はそのまま出す
    static func categoryName(_ name: String) -> String {
        let base = name.hasSuffix(" (deferred)") ? String(name.dropLast(" (deferred)".count)) : name
        switch base {
        case "System prompt": return String(localized: "システムプロンプト")
        case "System tools": return String(localized: "システムのツール")
        case "MCP tools": return String(localized: "コネクタのツール")
        case "Custom agents": return String(localized: "カスタムエージェント")
        case "Memory files": return String(localized: "メモリのファイル")
        case "Skills": return String(localized: "スキル")
        case "Messages": return String(localized: "メッセージ")
        case "Autocompact buffer": return String(localized: "自動圧縮の予備")
        case "Compact buffer": return String(localized: "圧縮の予備")
        case "Free space": return String(localized: "空き")
        default: return name
        }
    }
}
