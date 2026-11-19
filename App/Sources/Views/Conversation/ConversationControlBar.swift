import SwiftUI
import TaskboardKit

/// 会話の制御のうち、この会話で出すものと今の値。入力欄の下の欄（`ConversationControlBar`）と iPhone の＋のメニュー（`ConversationPhoneMenu`）が同じものを出す。
/// engine に無い制御は出さない。Codex のモデルと effort は、マシンのモデルの一覧が読めたときだけ出す。effort の段階の無いモデルでは effort を出さない
struct ConversationControls {
    let options: ConversationModelOptions?
    /// モデルの名前（候補が読めたときだけ）
    let model: String?
    /// effort（段階のあるモデルだけ。未設定は「デフォルト」）
    let effort: String?
    let permission: String?
    let connectors: Bool
    /// コンテキストを出す。使用率は分かるときだけ
    let context: Bool
    let contextPercent: Int?
    /// 動いているバックグラウンドのタスクの数（0 なら出さない）
    let backgroundTasks: Int

    @MainActor
    init(_ conversation: Conversation, model app: AppModel) {
        let engine = conversation.engine
        options = app.modelOptions(for: conversation)
        model = options?.label(conversation.model)
        effort = options.flatMap { $0.efforts(for: conversation.model).isEmpty ? nil : conversation.effort ?? String(localized: "デフォルト") }
        permission = engine.supports(.setPermissionMode) ? ConversationChoices.permissionLabel(conversation.permissionMode) : nil
        connectors = engine.supports(field: .mcp)
        context = engine.supports(field: .context)
        contextPercent = conversation.contextPercent
        backgroundTasks = conversation.runningBackgroundTasks ?? 0
    }

    /// マシンのモデルの一覧を読む（欄を出す画面の `.task` から）
    @MainActor
    static func loadModels(for conversation: Conversation, model: AppModel) async {
        switch conversation.engine {
        case .codex: await model.loadCodexModels(conversation.machine)
        case .claude: await model.loadClaudeModels(conversation.machine)
        case .unknown: break
        }
    }
}

/// 入力欄の下の欄。モデル・effort・権限（止まっていても選べる。次に起こすときに使う）、コネクタ、コンテキストの使用率。
/// コネクタとコンテキストの内訳はシートで、ほかは小さな欄（ポップオーバー）で開く。`/model` などで選んだときも同じものを開く（`ConversationFeed.open`）。
/// iPhone は出さず、同じ項目を入力欄の＋のメニューに置く
struct ConversationControlBar: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let feed: ConversationFeed
    let fail: (UserFacingError) -> Void

    var body: some View {
        FlowRow(spacing: Space.row, lineSpacing: Space.inline) { fields(ConversationControls(conversation, model: model)) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: conversation.machine) { await ConversationControls.loadModels(for: conversation, model: model) }
    }

    @ViewBuilder
    private func fields(_ controls: ConversationControls) -> some View {
        if let name = controls.model {
            chip(.model, systemImage: "cpu", text: name, options: controls.options)
        }
        if let effort = controls.effort {
            chip(.effort, systemImage: "gauge.with.dots.needle.50percent", text: String(localized: "エフォート：\(effort)"), options: controls.options)
        }
        if let permission = controls.permission {
            chip(.permission, systemImage: "lock.shield", text: permission, options: controls.options)
        }
        if controls.connectors {
            chipButton(title: String(localized: "コネクタ"), systemImage: "puzzlepiece.extension", text: String(localized: "コネクタ")) { feed.sheet = .connectors }
        }
        if controls.context {
            chipButton(
                title: String(localized: "コンテキスト"), systemImage: "chart.pie",
                text: controls.contextPercent.map { String(localized: "コンテキスト\(UsageText.percent(Double($0)))") } ?? String(localized: "コンテキスト")
            ) { feed.sheet = .context }
            .foregroundStyle(ContextUsage.color(controls.contextPercent.map(Double.init)))
        }
        // 末尾に置く（出入りでほかの欄を動かさない）
        if controls.backgroundTasks > 0 {
            chipButton(title: String(localized: "バックグラウンドのタスク"), text: String(localized: "バックグラウンド\(controls.backgroundTasks)件")) {
                feed.sheet = .tasks
            } icon: {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private func chip(_ field: ConversationField, systemImage: String, text: String, options: ConversationModelOptions?) -> some View {
        chipButton(title: ConversationChoices.title(field), systemImage: systemImage, text: text) { feed.openField = field }
            .popover(isPresented: Binding(get: { feed.openField == field }, set: { if !$0, feed.openField == field { feed.openField = nil } })) {
                ConversationFieldPanel(field: field, conversation: conversation, feed: feed, options: options, fail: fail)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func chipButton(title: String, systemImage: String, text: String, action: @escaping () -> Void) -> some View {
        chipButton(title: title, text: text, action: action) { Image(systemName: systemImage) }
    }

    private func chipButton(title: String, text: String, action: @escaping () -> Void, @ViewBuilder icon: () -> some View) -> some View {
        Button(action: action) {
            Label { Text(text) } icon: { icon() }.lineLimit(1)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .hitTarget()
        .help(title)
        .accessibilityLabel(title == text ? text : "\(title)、\(text)")
    }
}

/// 欄の中身。選ぶ欄は選んだら閉じる
struct ConversationFieldPanel: View {
    let field: ConversationField
    let conversation: Conversation
    let feed: ConversationFeed
    /// モデルと effort の候補。nil の engine ではモデルと effort の欄を開かない（`ConversationControlBar`）
    let options: ConversationModelOptions?
    let fail: (UserFacingError) -> Void

    var body: some View {
        Group {
            switch field {
            case .model:
                ConversationChoiceList(
                    title: ConversationChoices.title(field), options: (options?.models ?? []).map { ($0.value, $0.label) },
                    others: (options?.otherModels ?? []).map { ($0.value, $0.label) }, selected: options?.selected(conversation.model)
                ) { choose(.setModel, $0) }
            case .effort:
                ConversationChoiceList(
                    title: ConversationChoices.title(field), options: (options?.efforts(for: conversation.model) ?? []).map { ($0.value, $0.label) },
                    selected: conversation.effort
                ) { choose(.setEffort, $0) }
            case .permission:
                ConversationChoiceList(
                    title: ConversationChoices.title(field), options: ConversationChoices.permissionModes(current: conversation.permissionMode).map { ($0, ConversationChoices.permissionLabel($0)) },
                    selected: conversation.permissionMode ?? ConversationInput.defaultPermissionMode
                ) { choose(.setPermissionMode, $0) }
            }
        }
        .padding(Space.card)
        .frame(minWidth: ConversationMetrics.fieldWidth.lowerBound, maxWidth: ConversationMetrics.fieldWidth.upperBound, alignment: .leading)
    }

    private func choose(_ kind: ConversationControlRequest.Kind, _ value: String) {
        feed.openField = nil
        Task {
            do {
                try await feed.control(ConversationControlRequest(kind: kind, value: value))
            } catch {
                if let failure = UserFacingError("\(ConversationChoices.title(field))を変更できませんでした", error: error) { fail(failure) }
            }
        }
    }
}

/// 1 つを選ぶ一覧。選んでいる行に印。`others` は「ほかのモデル」に畳んで出し、選んでいるものがその中にあれば開いておく
struct ConversationChoiceList: View {
    typealias Option = (value: String, label: String)
    let title: String
    let options: [Option]
    let others: [Option]
    let selected: String?
    let choose: (String) -> Void
    @State private var showsOthers: Bool

    init(title: String, options: [Option], others: [Option] = [], selected: String?, choose: @escaping (String) -> Void) {
        self.title = title
        self.options = options
        self.others = others
        self.selected = selected
        self.choose = choose
        _showsOthers = State(initialValue: others.contains { $0.value == selected })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            Text(title).textRole(.sectionTitle)
            rows(options)
            if !others.isEmpty {
                DisclosureGroup("ほかのモデル", isExpanded: $showsOthers) {
                    VStack(alignment: .leading, spacing: Space.inline) { rows(others) }
                }
            }
        }
    }

    private func rows(_ options: [Option]) -> some View {
        ForEach(options, id: \.value) { option in
            Button {
                choose(option.value)
            } label: {
                HStack(spacing: Space.row) {
                    Image(systemName: "checkmark").opacity(option.value == selected ? 1 : 0).accessibilityHidden(true)
                    Text(option.label)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hitTarget()
            .accessibilityAddTraits(option.value == selected ? .isSelected : [])
        }
    }
}

/// 欄の名前と、値の画面の文
enum ConversationChoices {
    static func title(_ field: ConversationField) -> String {
        switch field {
        case .model: String(localized: "モデル")
        case .effort: String(localized: "エフォート")
        case .permission: String(localized: "権限")
        }
    }

    /// 欄で並べる権限のモード。ほかのモード（CLI の dontAsk など）になっていれば、それも並べる
    static func permissionModes(current: String?) -> [String] {
        let order = ConversationInput.permissionModes
        guard let current, !order.contains(current) else { return order }
        return order + [current]
    }

    static func permissionLabel(_ mode: String?) -> String {
        switch mode ?? ConversationInput.defaultPermissionMode {
        case "default": String(localized: "毎回確認")
        case "acceptEdits": String(localized: "編集は自動で許可")
        case "plan": String(localized: "計画モード")
        case "bypassPermissions": String(localized: "確認なし")
        case "auto": String(localized: "自動で判定")
        case "dontAsk": String(localized: "確認せずに拒否")
        case "manual": String(localized: "手動")
        case let other: other
        }
    }

    static func connectorLabel(_ status: String) -> String {
        switch status {
        case "connected": String(localized: "接続済み")
        case "failed": String(localized: "接続できません")
        case "needs-auth": String(localized: "認証待ち")
        case "pending": String(localized: "接続しています…")
        case "disabled": String(localized: "無効")
        case let other: other
        }
    }

    static func connectorSymbol(_ status: String) -> String {
        switch status {
        case "connected": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "needs-auth": "key.fill"
        case "pending": "circle.dotted"
        default: "minus.circle"
        }
    }

    static func connectorColor(_ status: String) -> Color {
        switch status {
        case "connected": .green
        case "failed": .red
        case "needs-auth": .orange
        default: .secondary
        }
    }
}
