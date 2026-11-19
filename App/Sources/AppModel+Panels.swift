import Foundation
import TaskboardKit

/// 会話が登録した概況の操作（送る文面の［承認］と、表・図の行の行き先）
extension AppModel {
    /// 送る文面の［承認］。承認と本文は daemon が登録した会話へ届ける（送るのは会話）
    func approvePanelDraft(task: BoardTask, part: String, body: String) {
        let window = beginAction()
        Task {
            do {
                _ = try await requireSource(task.machine).approvePanelDraft(task: task.number, part: part, body: body)
            } catch {
                fail("文面を承認できませんでした", error, in: window)
            }
        }
    }

    /// 表の行・図の項目の行き先。タスクと文書はアプリの中、taskboard:// はアプリの中、ほかの URL はブラウザで開く
    func openPanelTarget(_ target: PanelTarget, machine: MachineID) {
        if let number = target.task {
            navigate(to: .task(TaskKey(machine: machine, number: number)), from: .app)
        } else if let doc = target.doc {
            navigate(to: .doc(DocKey(machine: machine, id: doc)), from: .app)
        } else if let text = target.url, let url = URL(string: text) {
            if TaskboardLink(url: url) != nil { open(url, from: .app) } else { ExternalLinks.open(url) }
        }
    }
}
