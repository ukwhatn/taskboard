import Foundation
import TaskboardKit

extension AppModel {
    /// 会話を開く画面（`MachineState.home(of:)`）
    func conversationScope(for key: ConversationKey) -> SessionScope {
        guard let state = fleet.machineState(for: key.machine), let conversation = state.conversations[key] else { return .unassigned(key.machine) }
        return SessionScope(state.home(of: conversation), on: key.machine)
    }

    /// 止まっているセッションを同じ会話で起こし、戻した会話を開く
    func resumeSession(_ ref: TaskSessionRef, task: TaskKey) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                let result = try await source.resumeSession(task: task.number, SessionResumeRequest(agentSessionID: ref.sessionID))
                // 起動の画面で会話を起こしたときと同じく、届く前に開く先を決めておく（`.conversation` の行き先は届いた会話のタスクを引く）
                if let conversation = result.conversation { navigate(to: .task(task, focus: conversation.key), from: .app) }
            } catch {
                fail("セッションを再開できませんでした", error, in: window)
            }
        }
    }

    /// マシンの Claude Code のアカウントの名前（daemon の `claude-accounts.json`）。無ければ空で、アカウントの欄と項目を出さない
    func claudeAccounts(on machine: MachineID) -> [String] {
        fleet.usage(for: machine)?.claudeAccounts?.map(\.name) ?? []
    }

    /// Claude Code のアカウントを替える。会話は次に送ったときに新しいアカウントで起きる
    func switchAccount(_ request: SessionAccountRequest, on machine: MachineID) {
        guard let source = source(for: machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.switchAccount(request)
            } catch {
                fail("アカウントを切り替えられませんでした", error, in: window)
            }
        }
    }
}
