import SwiftUI
import TaskboardKit

/// 起動先（マシン・作業ディレクトリ・エージェント・モデル・effort）と起動プロンプト。Form の中に置き、自分で Section を 2 つ出す
struct LaunchFields: View {
    @Binding var draft: LaunchDraft
    /// 起動先の区分の見出し
    var header: String? = "起動"
    /// マシンの行。定期起動のシートは上の区分でマシンを選ぶので出さない
    var showsMachine = true
    /// プロンプトをタスクの値で展開済みなら false（置換子の説明を出さない）
    var showsPlaceholders = true
    /// 起票では起動プロンプトを畳む（題だけ書いて起動するとき、テンプレートのまま送る）
    var collapsesPrompt = false
    /// 今すぐ起こすシート（起動のシートと起票のシート）。Claude Code の会話を先に起こしておく。定期起動のシートは起こさない
    var startsNow = false
    @State private var promptExpanded = false
    /// 起動先の区分に渡す下書きの Binding。`$draft` から作った Binding を持つ view は、比べ（`LaunchTargetSection` の Equatable）を通らずに描き直される
    private var editing: Binding<LaunchDraft> { Binding(get: { draft }, set: { draft = $0 }) }

    var body: some View {
        LaunchTargetSection(draft: editing, header: header, showsMachine: showsMachine, startsNow: startsNow)
        Section {
            if collapsesPrompt {
                DisclosureGroup(isExpanded: $promptExpanded) {
                    promptEditor
                } label: {
                    Text(draft.prompt.isEmpty ? "起動プロンプトなし" : "起動プロンプト")
                }
            } else {
                promptEditor
            }
        } header: {
            if !collapsesPrompt { Text("起動プロンプト") }
        } footer: {
            if showsPlaceholders && draft.prompt.contains("{{") && (!collapsesPrompt || promptExpanded) {
                Text(verbatim: PromptTemplate.placeholders.joined(separator: "・"))
                    + Text("は、起動するときにタスクの番号・タイトル・列・メモ・リンクに置き換わります。")
            }
        }
    }

    private var promptEditor: some View {
        MultilineTextField(label: String(localized: "起動プロンプト"), text: $draft.prompt, lines: 4...12, font: .calloutMonospaced, style: .automatic, literal: true)
            .onChange(of: draft.prompt) { old, new in
                // テンプレート差し替え時の変化は「手で変えた」に数えない（applyTemplate が直後に同じ値を入れる）。
                // 済んでいれば書かない（書くと 1 字打つたびに下書きがもう 1 回変わり、シートごと組み直される）
                if !draft.promptEdited, !old.isEmpty || !new.isEmpty { draft.promptEdited = true }
            }
    }
}

/// 起動先（マシン・作業ディレクトリ・エージェント・実行方法）の区分。起動プロンプトを打っても描き直さないよう、見せる値（`shown`）で比べる
private struct LaunchTargetSection: View, Equatable {
    @Environment(AppModel.self) private var model
    @Binding var draft: LaunchDraft
    let header: String?
    let showsMachine: Bool
    let startsNow: Bool
    /// 起動プロンプトを除いた下書き
    private let shown: LaunchDraft

    init(draft: Binding<LaunchDraft>, header: String?, showsMachine: Bool, startsNow: Bool) {
        _draft = draft
        self.header = header
        self.showsMachine = showsMachine
        self.startsNow = startsNow
        var shown = draft.wrappedValue
        shown.prompt = ""
        shown.promptEdited = false
        self.shown = shown
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.shown == b.shown && a.header == b.header && a.showsMachine == b.showsMachine && a.startsNow == b.startsNow
    }

    var body: some View {
        Section {
            if showsMachine {
                LabeledContent("Mac") { MachineName(machine: draft.machine) }
            }
            WorkdirField(machine: draft.machine, path: $draft.cwd)
            LaunchChoiceFields(choice: $draft.choice, machine: draft.machine)
            if draft.kind == .claude, case let accounts = model.claudeAccounts(on: draft.machine), !accounts.isEmpty {
                Picker("アカウント", selection: $draft.account) {
                    Text("自動").tag(String?.none)
                    Text(ClaudeAccountLabel.login).tag(String?.some(ClaudeAccount.login))
                    ForEach(accounts, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
            }
            // 定期起動では codex の引数（--model・-c model_reasoning_effort=）にして渡す
            if draft.kind == .codex, let options = codexOptions {
                codexFields(options)
            }
        } header: {
            if let header { Text(header) }
        }
        .task(id: draft.kind == .codex ? draft.machine : nil) {
            if draft.kind == .codex { await model.loadCodexModels(draft.machine) }
        }
        // 欄を打っている途中で何度も呼ばないよう、条件が変わってから少し待つ（変わると前の待ちは取り消される）
        .task(id: startsNow ? draft.prewarmTarget : nil) {
            guard startsNow, draft.prewarmTarget != nil else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await model.prewarmConversation(draft.prewarmTarget)
        }
    }

    /// Codex の会話のモデルの一覧（隠すモデルは出さない）。一覧が無いマシンでは欄を出さず、daemon の既定に任せる
    private var codexOptions: ConversationModelOptions? {
        ConversationModelOptions.of(.codex, codex: model.fleet.machineState(for: draft.machine)?.codex, claude: nil)
    }

    /// モデルの数はマシンの codex で変わるのでメニューにする（docs/ui-system.md「選択の形」）。effort は選んだモデルの段階
    @ViewBuilder
    private func codexFields(_ options: ConversationModelOptions) -> some View {
        let codexModel = Binding(get: { draft.choice.codexModel }, set: { draft.choice.select(codexModel: $0) })
        let codexEffort = Binding(get: { draft.choice.codexEffort }, set: { draft.choice.select(codexEffort: $0) })
        Picker("モデル", selection: codexModel) {
            Text("デフォルトのモデル").tag(String?.none)
            ForEach(options.models, id: \.value) { Text(verbatim: $0.label).tag(String?.some($0.value)) }
        }
        .pickerStyle(.menu)
        .onChange(of: draft.choice.codexModel) {
            if let effort = draft.choice.codexEffort, !options.efforts(for: draft.choice.codexModel).contains(where: { $0.value == effort }) {
                draft.choice.select(codexEffort: nil)
            }
        }
        Picker("エフォート", selection: codexEffort) {
            Text("デフォルト").tag(String?.none)
            ForEach(options.efforts(for: draft.choice.codexModel), id: \.value) { Text(verbatim: $0.label).tag(String?.some($0.value)) }
        }
        .pickerStyle(.menu)
    }
}

/// 既存のタスクに新しいセッションを起動するシート。
struct LaunchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: BoardTask
    @State var draft: LaunchDraft
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        SheetScaffold(title: String(localized: "セッションの起動"), subtitle: "#\(task.number) \(task.title)", error: error, onCancel: { dismiss() }) {
            LaunchFields(draft: $draft, header: nil, showsPlaceholders: false, startsNow: true)
        } actions: {
            if submitting { ProgressView().controlSize(.small) }
            // ↩ を既定のボタンにしない（起動プロンプトの欄で ↩ を押すと起動していた）。⌘↩ で押す
            Button("起動") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(submitting)
        }
        .commandReturn(enabled: !submitting) { submit() }
        .onAppear {
            let board = model.fleet.board(id: task.boardID, on: task.machine)
            draft.applyTemplate(for: task.columnID, in: board)
            // このタスクの値で展開して見せる（daemon の展開は、置換子が残っていなければ何もしない）
            draft.prompt = PromptTemplate.render(draft.prompt, task: task, board: board)
        }
    }

    private func submit() {
        submitting = true
        error = nil
        Task {
            do {
                _ = try await model.launchSession(task: task, draft)
                draft.remember(board: task.boardID)
                dismiss()
            } catch {
                self.error = UserFacingError("起動できませんでした", error: error)?.text
                submitting = false
            }
        }
    }
}
