import Foundation
import TaskboardKit

/// 起票と起動、定期起動の作成先のマシン、作業ディレクトリの候補
extension AppModel {
    /// 書き込める（起動・定期起動を作れる）マシン。サイドバーで並べた順
    var writableMachines: [MachineID] {
        orderedMachines.compactMap { $0.state.machine?.id }.filter(canWrite)
    }

    /// 作業ディレクトリの候補を取り直す。fixtures はデータの中の値。取れなければ前の値を残す（候補が無くても入力はできる）
    func refreshWorkingDirectories(on machine: MachineID) async {
        guard let source = fleet.terminalSource(for: machine) else {
            if let fixture = fixtureExtras.workdirs { workingDirectories[machine] = fixture }
            return
        }
        if let fetched = try? await source.workingDirectories() { workingDirectories[machine] = fetched }
    }

    /// 打ちかけのパスの続きになるディレクトリ。fixtures と、補完の無い古い daemon では空（候補が出ないだけで入力はできる）
    func completeWorkingDirectory(_ prefix: String, on machine: MachineID) async -> [String] {
        guard let source = fleet.terminalSource(for: machine) else { return [] }
        return (try? await source.completeWorkingDirectory(prefix)) ?? []
    }

    /// ブックマークに足す・外す。失敗したら画面の下の帯で知らせる（書いた作業ディレクトリは消えない）
    func toggleBookmark(_ path: String, on machine: MachineID) {
        let window = activeWindow
        let path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, let source = source(for: machine) else { return }
        let existing = workingDirectories[machine]?.bookmarks.first { $0.path == path }
        Task {
            do {
                if let existing {
                    try await source.deleteWorkdirBookmark(id: existing.id)
                } else {
                    _ = try await source.addWorkdirBookmark(path: path)
                }
                await refreshWorkingDirectories(on: machine)
            } catch {
                fail(existing == nil ? "ブックマークに追加できませんでした" : "ブックマークから外せませんでした", error, in: window)
            }
        }
    }
}

extension AppModel {
    /// 起動のシート・起票のシート・debug の口から、タスクの会話を起こす。会話はタスクの中で開く先にする（Mac と iPad はパネルの帯、iPhone はタスクの画面に積む）。
    /// 書き込めない接続先の失敗は投げるだけで、帯には出さない（シートが自分の欄に出す）
    func launchSession(task: BoardTask, _ draft: LaunchDraft) async throws -> Conversation {
        beginAction()
        guard let source = fleet.conversationSource(for: task.machine) else { throw ActionError.notWritable(fleet.writeAccess(task.machine)) }
        let conversation = try await source.startConversation(draft.conversationStart(taskNumber: task.number))
        focus(conversation.key, in: .task(task.id))
        return conversation
    }
}
