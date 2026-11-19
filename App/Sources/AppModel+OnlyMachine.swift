import Foundation
import TaskboardKit

extension AppModel {
    /// ⌃⌘1。解除すると、すぐ元の表示に戻る
    func toggleOnlyMachine() {
        onlyMachineEnabled.toggle()
    }

    /// 残すマシン。選んでいなければ「この Mac」、無ければサイドバーの先頭（iPad・iPhone は「この Mac」を持たない）
    var onlyMachineID: String {
        get {
            if let chosen = chosenOnlyMachineID, fleet.allMachines[chosen] != nil { return chosen }
            if fleet.allMachines["local"] != nil { return "local" }
            return onlyMachineCandidates.first?.id ?? chosenOnlyMachineID ?? "local"
        }
        set { chosenOnlyMachineID = newValue }
    }

    /// ツールバーに出す「◯◯のみ」。1 台だけ表示でなければ nil
    var onlyMachineLabel: String? {
        guard onlyMachineEnabled else { return nil }
        return String(localized: "\(machineName(fleetID: onlyMachineID, state: fleet.allMachines[onlyMachineID]))のみ")
    }

    /// 1 台だけ表示で残せるマシン（設定の選択肢）。並びはサイドバーと同じ
    var onlyMachineCandidates: [(id: String, name: String)] {
        let ids = SidebarOrder.arrange(fleet.allMachines.keys.sorted(), by: machineOrder)
        return ids.map { ($0, machineName(fleetID: $0, state: fleet.allMachines[$0])) }
    }

    /// 設定でマシンを非表示にする・戻す（接続は切らない）
    func setMachineHidden(_ fleetID: String, _ hidden: Bool) {
        if hidden { hiddenMachines.insert(fleetID) } else { hiddenMachines.remove(fleetID) }
    }

    /// `Fleet` に残すマシンを渡し、隠したマシンを指している選択・積んだ画面・確認を外す。1 台だけ表示と非表示の切り替えのほか、
    /// 接続先の追加と削除の後にも呼ぶ（残すマシンの接続先が消えると、残すマシンが替わる）
    func applyOnlyMachine() {
        // fixtures（snapshot test・デモ）は接続設定の id を持たないので当てない
        fleet.onlyMachine = onlyMachineEnabled && scenario == nil ? onlyMachineID : nil
        fleet.hiddenMachines = scenario == nil ? hiddenMachines : []
        guard onlyMachineEnabled || !hiddenMachines.isEmpty else { return }
        let visible = Set(fleet.machines.values.compactMap { $0.machine?.id })
        func hidden(_ machine: MachineID) -> Bool { !visible.contains(machine) }
        if let key = selectedTask, hidden(key.machine) { closeTask() }
        if let key = cursorTask, hidden(key.machine) { cursorTask = nil }
        if let item = phoneTaskItem, hidden(item.machine) { phoneTaskItem = nil }
        if let focus = sessionFocus, hidden(focus.scope.machine) { sessionFocus = nil }
        switch sidebar {
        case .board(let machine, _), .orchestrator(let machine), .unassigned(let machine):
            if hidden(machine) { sidebar = .overview }
        case .overview, .settings: break
        }
        if let url = selectedPR, fleet.pullRequest(url: url) == nil { selectedPR = nil }
    }
}
