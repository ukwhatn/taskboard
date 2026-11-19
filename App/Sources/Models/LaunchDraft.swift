import SwiftUI
import TaskboardKit

/// 起動先と起動プロンプトの下書き。起票シートと、既存タスクの「起動」シート、定期起動のシートで同じものを使う。
/// worktree は持たない（セッションが自分で切る。要求の `worktree` は MCP の session_start だけが使う）
struct LaunchDraft: Identifiable, Hashable {
    var id = UUID()
    var machine: MachineID
    /// 空なら daemon が動く Mac のホーム
    var cwd = ""
    var choice = LaunchChoice.standard
    var prompt = ""
    /// 手で変えた後は列を変えてもテンプレートで上書きしない
    var promptEdited = false
    /// Claude Code のアカウント（`ClaudeAccount.login` はマシンのログイン）。nil なら daemon が案件の割り当てと枠から決める
    var account: String?

    init(machine: MachineID, cwd: String = "", prompt: String = "") {
        self.machine = machine
        self.cwd = cwd
        self.prompt = prompt
    }

    var kind: AgentKind { choice.kind }
    var agentArgs: [String] { choice.args }

    /// 保存済みの引数を選び直す。形に合わなければカスタムの引数のまま持つ
    mutating func select(kind: AgentKind, args: [String]) {
        choice = LaunchChoice(kind: kind, args: args)
    }

    /// 会話で起動するときの要求。Claude Code は事前起動（`prewarmTarget`）と同じ条件で組む（daemon は条件が同じときだけ先に起こしたプロセスを引き取る）。
    /// Codex は engine を載せ、モデルと effort は codex の名前のまま渡す。Claude Code は engine を省く（engine を知らない古い daemon にも届く形）
    func conversationStart(taskNumber: Int?) -> ConversationStartRequest {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .codex {
            return ConversationStartRequest(
                cwd: cwd.trimmingCharacters(in: .whitespaces), taskNumber: taskNumber, model: choice.codexModel, effort: choice.codexEffort,
                prompt: prompt.isEmpty ? nil : prompt, engine: .codex)
        }
        let warm = prewarmRequest
        return ConversationStartRequest(
            cwd: warm.cwd, taskNumber: taskNumber, model: warm.model, effort: warm.effort, permissionMode: warm.permissionMode,
            prompt: prompt.isEmpty ? nil : prompt, account: account)
    }

    /// Claude Code を選んでいる間だけ、事前起動の宛先。Codex は nil（daemon も Codex を事前起動しない）
    var prewarmTarget: ConversationPrewarmTarget? {
        kind == .claude ? ConversationPrewarmTarget(machine: machine, request: prewarmRequest) : nil
    }

    private var prewarmRequest: ConversationPrewarmRequest {
        ConversationPrewarmRequest(cwd: cwd.trimmingCharacters(in: .whitespaces), model: choice.model, effort: choice.effort?.rawValue)
    }

    func request(requestID: String = "launch-" + UUID().uuidString.lowercased(), taskNumber: Int? = nil) -> LaunchRequest {
        LaunchRequest(
            requestID: requestID, cwd: cwd.trimmingCharacters(in: .whitespaces), kind: kind, agentArgs: agentArgs, prompt: prompt,
            claudeAccount: kind == .claude ? account : nil)
    }

    /// 案件の起動の既定（daemon）を入れる。既定が無ければ、この案件で前回選んだもの。作業ディレクトリは、既定が空なら最後に使った値
    mutating func apply(defaults: LaunchDefaults?, board: String) {
        if let defaults {
            select(kind: defaults.kind, args: defaults.agentArgs)
        } else if let remembered = Self.rememberedChoice(board: board) {
            choice = remembered
        }
        let fixed = defaults?.cwd.trimmingCharacters(in: .whitespaces) ?? ""
        if cwd.isEmpty { cwd = fixed.isEmpty ? Self.rememberedCwd(board: board) : fixed }
    }

    /// 案件の既定と列のテンプレートを入れた、起動のシートの初期値。`cwd` は紐づくセッションの値など、既定より優先するもの
    static func initial(machine: MachineID, board: Board?, boardID: String, columnID: String, cwd: String = "") -> LaunchDraft {
        var draft = LaunchDraft(machine: machine, cwd: cwd)
        draft.apply(defaults: board?.launchDefaults, board: boardID)
        draft.applyTemplate(for: columnID, in: board)
        return draft
    }

    /// 列（か案件）の既定テンプレートを入れる。手で変えた後は触らない
    mutating func applyTemplate(for columnID: String, in board: Board?) {
        guard !promptEdited, let board else { return }
        prompt = PromptTemplate.template(for: columnID, in: board)
    }

    /// 案件ごとに最後に使った cwd（同じ repo で起動することが多いので）
    static func rememberedCwd(board: String) -> String {
        AppDefaults.store.string(forKey: AppPreferences.launchKey(.cwd, board: board)) ?? ""
    }

    static func rememberedChoice(board: String) -> LaunchChoice? {
        guard let kind = AppDefaults.store.string(forKey: AppPreferences.launchKey(.kind, board: board)).flatMap(AgentKind.init(rawValue:)),
            let args = AppDefaults.store.stringArray(forKey: AppPreferences.launchKey(.args, board: board))
        else { return nil }
        return LaunchChoice(kind: kind, args: args)
    }

    /// 起動したときの作業ディレクトリと選び方を、次の起動の初期値に覚える
    func remember(board: String) {
        AppDefaults.store.set(cwd, forKey: AppPreferences.launchKey(.cwd, board: board))
        AppDefaults.store.set(kind.rawValue, forKey: AppPreferences.launchKey(.kind, board: board))
        AppDefaults.store.set(agentArgs, forKey: AppPreferences.launchKey(.args, board: board))
    }
}
