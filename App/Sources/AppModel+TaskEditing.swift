import Foundation
import TaskboardKit

/// タスクの編集のシート。セッションの帯の［セッションを紐づける…］から開く。題・メモ・リンクはシートでなくその場で直す（`TaskHeader`・`TaskDetails`）
enum TaskEditSheet: String, Identifiable {
    case sessions
    var id: String { rawValue }
}

/// 人がアプリからタスクを直す（題・メモ・リンク・紐づくセッション）。エージェントが MCP でできることと同じ範囲
extension AppModel {
    // MARK: 題とメモ

    /// 保存する題。前後の空白を落とし、空になれば nil（起票の題と同じ検査）
    static func normalizedTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// その場の編集を確定したときに保存する題。空白だけなら保存せず元の題に戻し、元の題と同じなら送らない
    static func titleChange(_ draft: String, from current: String) -> String? {
        guard let title = normalizedTitle(draft), title != current else { return nil }
        return title
    }

    func saveTitle(_ title: String, of task: BoardTask) async throws {
        guard let title = Self.normalizedTitle(title) else { return }
        _ = try await requireSource(task.machine).updateTask(number: task.number, TaskUpdateRequest(title: title))
    }

    func saveNote(_ note: String, of task: BoardTask) async throws {
        _ = try await requireSource(task.machine).updateTask(number: task.number, TaskUpdateRequest(note: note))
    }

    // MARK: リンク

    /// 足す URL。欄の行を起票のリンクの欄と同じく空白と改行で分け、空の行・このタスクにもうある URL・重ねて書いた URL を除く（並びは書いた順）
    static func newLinks(_ rows: [String], existing: [TaskLink]) -> [String] {
        var seen = Set(existing.map(\.url))
        return rows.flatMap { $0.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init) }
            .filter { seen.insert($0).inserted }
    }

    /// 種類（PR・Issue・Jira・その他）は daemon が URL から決める
    func addLinks(_ urls: [String], to task: BoardTask) async throws {
        guard !urls.isEmpty else { return }
        _ = try await requireSource(task.machine).updateTask(number: task.number, TaskUpdateRequest(addLinks: urls))
    }

    func removeLink(_ link: TaskLink, from task: BoardTask) {
        guard let source = source(for: task.machine) else { return }
        let window = beginAction()
        Task {
            do {
                _ = try await source.updateTask(number: task.number, TaskUpdateRequest(removeLinkIDs: [link.id]))
            } catch {
                fail("リンクを外せませんでした", error, in: window)
            }
        }
    }

    // MARK: 会話

    /// 紐づけられる会話: 同じマシンのタスクなしの会話（委譲先・終了したもの・オーケストレーターを除く）。新しく作った順
    func linkCandidates(for task: BoardTask) -> [Conversation] {
        guard let state = fleet.machineState(for: task.machine) else { return [] }
        return state.members(of: .unassigned).map(\.conversation)
            .filter { !$0.isClosed && !state.isDelegate($0) && Self.linkRequest($0, task: task.number) != nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// タスクに紐づける要求。会話は会話 ID で会話ごと移る。オーケストレーターはタスクの作業ではないので nil
    static func linkRequest(_ conversation: Conversation, task number: Int) -> SessionLinkRequest? {
        guard conversation.purpose != .orchestrator, !conversation.agentSessionID.isEmpty else { return nil }
        return SessionLinkRequest(
            paneID: nil, agent: conversation.engine.rawValue, agentSessionID: conversation.agentSessionID, cwd: conversation.cwd, taskNumber: number)
    }

    func link(_ conversation: Conversation, to task: BoardTask) async throws {
        guard let request = Self.linkRequest(conversation, task: task.number) else { return }
        _ = try await requireSource(task.machine).linkSession(request)
    }
}
