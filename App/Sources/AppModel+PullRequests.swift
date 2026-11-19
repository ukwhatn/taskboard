import Foundation
import TaskboardKit

/// PR の一覧と中身、PR を持つタスクと作業項目
extension AppModel {
    /// 中身を取るマシンは、一覧に出ていればそれを取ったマシン、次にタスクのマシン、次に繋がっているどれか。候補のマシンに順に聞き、最初に取れた中身を返す。マシンごとに gh のアカウントの振り分けが違い、
    /// 権限の無いアカウントで聞いたマシンは PR を「見つからない」と返す（RECERQA の PR を、振り分けの無いこの Mac が取れなかった）
    func pullRequestDetail(url: String, preferring machine: MachineID? = nil) async throws -> PullRequestDetail {
        var seen = Set<MachineID>()
        let candidates = (fleet.machinesFetching(url: url) + [machine].compactMap { $0 } + fleet.machines.values.compactMap { $0.machine?.id })
            .filter { seen.insert($0).inserted }
        var firstError: (any Error)?
        for id in candidates {
            guard let source = fleet.terminalSource(for: id) else { continue }
            do {
                return try await source.pullRequestDetail(url: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? ActionError.notWritable(candidates.first.map(fleet.writeAccess) ?? .unknown)
    }

    /// 全マシンで取り直す
    func refreshPullRequests() async {
        await withTaskGroup(of: Void.self) { group in
            for state in fleet.machines.values {
                guard let id = state.machine?.id, let source = fleet.terminalSource(for: id) else { continue }
                group.addTask { _ = try? await source.refreshPullRequests() }
            }
        }
    }

    /// PR の URL を持つタスク（全マシン）。リンクにその PR を持つタスクと、その PR を成果物にした作業項目のタスク
    func tasks(linkedTo url: String) -> [BoardTask] {
        let viaWork = Set(workItems(delivering: url).map { TaskKey(machine: $0.machine, number: $0.taskNumber) })
        return fleet.machines.values.flatMap { $0.tasks.values }
            .filter { task in viaWork.contains(task.id) || task.links.contains { $0.url == url } }
            .sorted { $0.number < $1.number }
    }

    func workItems(delivering url: String) -> [WorkItem] {
        fleet.machines.values.flatMap { $0.workItems.values }
            .filter { $0.deliverableKind == .pr && $0.deliverableRef == url }
            .sorted { $0.itemID < $1.itemID }
    }

    /// タスクの見出しの PR のチップ。詳細の欄の PR の節でその PR を出す
    func show(pr url: String) {
        selectedPR = url
        prFocusRequest += 1
    }
}
