import Foundation
import TaskboardKit

/// オーケストレーターの送り先の選択（Mac の指示のシート）
extension AppModel {
    /// 指示の送り先に選べるマシン（接続しているマシン）。サイドバーの順。
    /// 書き込めるか（`terminalSource`）では絞らない。daemon に接続したマシンはすべて書き込め、fixtures でも選ぶ画面を確かめられる（送ると「表示用のデータ」の失敗になる）
    var orchestratorCandidates: [MachineID] {
        orderedMachines.filter(\.state.connected).compactMap { $0.state.machine?.id }
    }

    /// 送り先を選ぶ。以後は画面を移っても変わらない
    func selectOrchestratorTarget(_ machine: MachineID) {
        orchestratorTarget = machine
    }
}

/// 1 マシンのオーケストレーターの様子。サイドバーの行・オーケストレーターの画面・指示のシート・設定の［セッション］が、状態の文と操作をここから引く
struct OrchestratorRow: Equatable, Identifiable {
    let machine: MachineID
    let machineName: String
    /// 動いているオーケストレーターの会話（`AppModel.orchestratorConversation(on:)`）
    let conversation: Conversation?
    /// 常駐が入っているか
    let resident: Bool
    /// 常駐の見張りが起こせなかった（`OrchestratorInfo.lastError`）
    var launchFailed = false

    var id: MachineID { machine }

    var statusLabel: String {
        if let conversation { return StatusAppearance.of(conversation).label }
        return resident ? String(localized: "未起動") : String(localized: "常駐オフ・未起動")
    }

    /// 常駐の見張りが起こせなかったときの帯の文。daemon の文は出さない
    var launchFailure: String? {
        launchFailed ? String(localized: "常駐のオーケストレーターを起動できませんでした。［起動］を押してください。") : nil
    }

    var running: Bool { conversation != nil }

    /// 行の右に出す文字。題はどのマシンでも同じなので、1 台でもマシンの名前を出す
    var badge: String {
        resident ? machineName : String(localized: "\(machineName)・常駐オフ")
    }

    var canStart: Bool { !running }
    /// 常駐が入っている間は daemon が断る（止めてもすぐ起こし直すため）
    var canStop: Bool { running && !resident }
}

extension AppModel {
    /// 画面に出すオーケストレーターの会話。止まっていれば、利用枠の上限の後・ネットワークが戻った後に続きを送る予定があるときだけ
    func orchestratorConversation(on machine: MachineID) -> Conversation? {
        fleet.orchestratorConversation(on: machine).flatMap { $0.phase != .stopped || $0.limitResumeAt != nil || $0.networkResume == true ? $0 : nil }
    }

    /// 接続しているマシンごとのオーケストレーター。サイドバーの順
    var orchestratorRows: [OrchestratorRow] {
        orderedMachines.filter(\.state.connected).compactMap { orchestratorRow(fleetID: $0.id, state: $0.state) }
    }

    /// 1 マシンのオーケストレーター。隠したマシンと、接続していないマシンも引ける（設定と画面のため）
    func orchestratorRow(on machine: MachineID) -> OrchestratorRow? {
        guard let (fleetID, state) = fleet.allMachines.first(where: { $0.value.machine?.id == machine }) else { return nil }
        return orchestratorRow(fleetID: fleetID, state: state)
    }

    private func orchestratorRow(fleetID: String, state: MachineState) -> OrchestratorRow? {
        guard let id = state.machine?.id else { return nil }
        return OrchestratorRow(
            machine: id, machineName: machineName(fleetID: fleetID, state: state), conversation: orchestratorConversation(on: id),
            // 古い daemon で分からなければ入っているものとして扱う（「常駐オフ」と出さない）
            resident: state.orchestrator?.enabled ?? state.settings?.orchestrator.enabled ?? true,
            launchFailed: state.orchestrator?.lastError != nil)
    }

}

extension AppModel {
    /// 指示のシート（`OrchestratorSheet`）は Mac だけ。iPhone・iPad はオーケストレーターのチャットで話しかける
    static var showsOrchestratorSheet: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// 今の会話を破棄して新しく起こす（daemon が止めて、`--resume` なしで起動する。居なければ起動と同じ）。確認は呼び手が済ませる（`OrchestratorRestartDialog`）
    func restartOrchestrator(on machine: MachineID) {
        let window = beginAction()
        Task {
            do {
                _ = try await requireSource(machine).restartOrchestrator()
            } catch {
                fail("オーケストレーターを再起動できませんでした", error, in: window)
            }
        }
    }
}

extension AppModel {
    /// 指示の送り先。選んだマシン（`orchestratorTarget`）があればそれ。無ければ見ているボード（かタスク）のマシン、それも無ければ最初のマシン。
    /// 選んだマシンが接続から消えていれば、選んでいないのと同じに扱う
    var orchestratorMachine: MachineID? {
        if let target = orchestratorTarget, fleet.machineState(for: target) != nil { return target }
        if let task = selectedTask { return task.machine }
        if case .board(let machine, _) = sidebar { return machine }
        if case .orchestrator(let machine) = sidebar { return machine }
        return orderedBoardsAcrossMachines.first?.machine ?? fleet.machines.values.compactMap { $0.machine?.id }.sorted { $0.rawValue < $1.rawValue }.first
    }

    /// orchestrator が居ないマシンで起こす。cwd は daemon の Mac のホーム、モデルは Opus / medium
    func startOrchestrator(on machine: MachineID) {
        guard let source = source(for: machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.startOrchestrator(LaunchRequest(cwd: "", kind: .claude, agentArgs: LaunchChoice.standard.args, prompt: ""))
            } catch {
                fail("オーケストレーターを起動できませんでした", error, in: window)
            }
        }
    }

    /// ⌘K の「オーケストレーターに指示…」。送り先は見ているボード（かタスク）のマシン
    func presentOrchestratorPrompt() {
        guard let machine = orchestratorMachine else { return }
        orchestratorSheet = OrchestratorTarget(machine: machine)
    }
}
