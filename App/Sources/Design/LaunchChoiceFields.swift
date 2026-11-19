import SwiftUI
import TaskboardKit

/// エージェント、モデル、effort を選ぶ欄。Form の中に置く。エージェントと effort は横並び、Claude Code のモデルはマシンの一覧で数が変わるのでメニュー
/// （docs/ui-system.md「選択の形」）にし、版つきの名前は「ほかのモデル」の区分に置く。effort はモデルが受ける段階だけを出す。
/// 引数がこの形に合わないもの（MCP から作った定期起動など）は、モデルを「カスタムの引数」にして引数を出し、選び直すまで引数を変えない
struct LaunchChoiceFields: View {
    @Environment(AppModel.self) private var model
    @Binding var choice: LaunchChoice
    /// モデルの一覧を引くマシン
    let machine: MachineID
    /// 選べるエージェント。1 つならエージェントの行を出さない（オーケストレーターは Claude Code だけ）
    var agents: [AgentKind] = AgentKind.allCases

    var body: some View {
        if agents.count > 1 {
            LabeledSegmentedPicker("エージェント", selection: Binding(get: { choice.kind }, set: { choice.select(kind: $0) })) {
                ForEach(agents, id: \.self) { Text($0.label).tag($0) }
            }
        }
        if choice.kind == .claude {
            let models = model.claudeModels(on: machine)
            modelPicker(models)
                .task(id: machine) { await model.loadClaudeModels(machine) }
            let efforts = models.efforts(for: choice.model)
            if !efforts.isEmpty {
                LabeledSegmentedPicker("エフォート", selection: Binding(get: { choice.isCustom ? nil : choice.effort }, set: { if let effort = $0 { choice.select(effort: effort) } })) {
                    ForEach(efforts) { Text($0.label).tag(Effort?.some($0)) }
                }
            }
        }
        if let custom = choice.custom {
            LabeledContent("カスタムの引数") {
                Text(verbatim: custom.joined(separator: " ")).textRole(.mono).textSelection(.enabled)
            }
        }
    }

    /// メニューの値。カスタムの引数はメニューから選べず、今の状態を示すためだけに置く
    private enum ModelSelection: Hashable {
        case custom
        case model(String?)
    }

    /// 値は `--model` に渡す名前。一覧に無いモデル（前に選んだ古いモデル）は「ほかのモデル」の終わりに名前のまま出す
    private func modelPicker(_ models: ClaudeModels) -> some View {
        let current = choice.model.map { models.argument(for: $0) ?? $0 }
        let unlisted = current.flatMap { models.model(named: $0) == nil ? $0 : nil }
        let selection = Binding<ModelSelection>(
            get: { choice.isCustom ? .custom : .model(current) },
            set: { if case .model(let value) = $0 { select(value, in: models) } })
        return Picker("モデル", selection: selection) {
            if choice.isCustom { Text("カスタムの引数").tag(ModelSelection.custom) }
            Text("デフォルトのモデル").tag(ModelSelection.model(nil))
            ForEach(models.primary) { Text(verbatim: $0.displayName).tag(ModelSelection.model(ClaudeModels.argument($0))) }
            if !models.others.isEmpty || unlisted != nil {
                Section("ほかのモデル") {
                    ForEach(models.others) { Text(verbatim: $0.displayName).tag(ModelSelection.model(ClaudeModels.argument($0))) }
                    if let unlisted { Text(verbatim: unlisted).tag(ModelSelection.model(unlisted)) }
                }
            }
        }
        .pickerStyle(.menu)
    }

    /// 選んだモデルが受けない effort は外す（effort の無いモデルでは `--effort` を渡さない）
    private func select(_ value: String?, in models: ClaudeModels) {
        choice.select(model: value)
        if let effort = choice.effort, !models.efforts(for: value).contains(effort) { choice.effort = nil }
    }
}
