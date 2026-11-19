import Foundation
import TaskboardKit

/// 会話のモデルと effort の選び方。Claude Code はマシンの一覧（読めていなければ Kit の控え）で、版つきの名前は「ほかのモデル」に畳む。
/// Codex はマシンの `model/list`（隠すモデルは出さない）。Codex の一覧がまだ無いマシン（読めていない・古い daemon・codex が無い）は nil にし、
/// 欄を出さずに daemon の既定に任せる
struct ConversationModelOptions {
    struct Option: Hashable {
        let value: String
        let label: String
    }

    let models: [Option]
    /// 畳んで出すモデル（Claude Code の版つきの名前）
    let otherModels: [Option]
    private let claude: ClaudeModels?
    /// Codex のモデルごとの effort の候補
    private let codexModels: [CodexMachineInfo.Model]?

    static func of(_ engine: Conversation.Engine, codex: CodexMachineInfo?, claude: ClaudeMachineInfo?) -> ConversationModelOptions? {
        switch engine {
        case .claude:
            let models = ClaudeModels(claude)
            return ConversationModelOptions(models: models.primary.map(option), otherModels: models.others.map(option), claude: models, codexModels: nil)
        case .codex:
            guard let listed = codex?.models?.filter({ !$0.hidden }), !listed.isEmpty else { return nil }
            return ConversationModelOptions(
                models: listed.map { Option(value: $0.id, label: $0.displayName) }, otherModels: [], claude: nil, codexModels: listed)
        case .unknown:
            return nil
        }
    }

    /// 値は `--model` に渡す名前（`ClaudeModels.argument`）
    static func option(_ model: ClaudeMachineInfo.Model) -> Option {
        Option(value: ClaudeModels.argument(model), label: model.displayName)
    }

    /// 欄に出す名前。nil は既定のモデル。一覧に無いモデルは名前のまま
    func label(_ model: String?) -> String {
        guard let model else { return String(localized: "デフォルトのモデル") }
        if let claude { return claude.label(model) }
        return models.first { $0.value == model }?.label ?? model
    }

    /// 一覧で印を付ける値。Claude Code は別名と `[1m]` などの書き方の違いをそろえる
    func selected(_ model: String?) -> String? {
        guard let model else { return nil }
        if let claude { return claude.argument(for: model) }
        return models.contains { $0.value == model } ? model : nil
    }

    /// effort の候補。選んでいるモデル（既定なら Claude Code は全部、Codex は既定のモデル）の段階。effort の無いモデルは空
    func efforts(for model: String?) -> [Option] {
        if let claude { return claude.efforts(for: model).map { Option(value: $0.rawValue, label: $0.label) } }
        let current = codexModels?.first { $0.id == model } ?? codexModels?.first(where: \.isDefault) ?? codexModels?.first
        return (current?.efforts ?? []).map { Option(value: $0, label: Effort(rawValue: $0)?.label ?? $0) }
    }
}

extension AppModel {
    /// 会話のモデルと effort の選び方（`ConversationModelOptions.of`）
    func modelOptions(for conversation: Conversation) -> ConversationModelOptions? {
        let engines = fleet.engines(on: conversation.machine)
        return ConversationModelOptions.of(conversation.engine, codex: engines.codex, claude: engines.claude)
    }

    /// そのマシンの Claude Code のモデルの一覧（まだ読めていなければ控え）
    func claudeModels(on machine: MachineID) -> ClaudeModels {
        ClaudeModels(fleet.engines(on: machine).claude)
    }

    /// Claude Code の欄が使うモデルの一覧を、まだ無ければ読む。daemon がまだ CLI から受けていなければ、次に欄を出したときに読み直す。
    /// 読めなければ（口の無い古い daemon）控えのまま
    func loadClaudeModels(_ machine: MachineID) async {
        guard fleet.machineState(for: machine)?.claude?.models == nil else { return }
        if scenario != nil {
            if let info = fixtureExtras.claude { fleet.setClaudeMachine(info, for: machine) }
            return
        }
        guard let source = fleet.terminalSource(for: machine), let info = try? await source.claudeMachine() else { return }
        fleet.setClaudeMachine(info, for: machine)
    }

    /// engine にはあるが、この画面では開けない欄（Codex でモデルの一覧が読めていない間のモデルと effort）。`/` は［端末で開く］に回す
    func unavailableFields(for conversation: Conversation) -> Set<ConversationControlField> {
        conversation.engine.supports(field: .model) && modelOptions(for: conversation) == nil ? [.model, .effort] : []
    }
}
