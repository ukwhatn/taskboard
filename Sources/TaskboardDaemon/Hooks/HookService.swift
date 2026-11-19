import Foundation
import Logging
import TaskboardKit

/// Claude Code の hook（SessionStart / Stop）と MCP の `task_id` 省略が頼る、セッション ↔ タスクの解決。
public struct HookService: Sendable {
    let store: Store
    let state: DaemonState
    let github: GitHubSync
    /// cwd 一致に使わないディレクトリ（daemon が動く Mac のホーム）
    let home: String
    /// 見直しを頼んだ待ち。同じ待ちについて、ターンのたびにモデルを起こさないため
    let remindedWaits = RemindedWaits()
    /// 回答・レビューの印と、タスクの lead
    let feedback: FeedbackService?
    private let logger = Logger(label: "uk.whatn.taskboardd.hooks")

    public init(store: Store, state: DaemonState, github: GitHubSync, home: String = NSHomeDirectory(), feedback: FeedbackService? = nil) {
        self.store = store
        self.state = state
        self.github = github
        self.home = home
        self.feedback = feedback
    }

    /// オーケストレーターの会話の Claude Code（SessionStart は会話の記録が state に届いた後に来る）
    func isOrchestrator(agentSessionID: String) async -> Bool {
        await state.allConversations().contains { $0.agentSessionID == agentSessionID && $0.purpose == .orchestrator }
    }

    /// SessionStart: 既に結ばれていればそれ、無ければ同じ cwd（home を除く）のタスクに結ぶ。どちらも無ければ結ばない（起票はしない）。
    /// 結べたときは案件も返す（hook が列の id と名前を案内に載せる）
    public func link(_ request: SessionLinkRequest) async throws -> TaskResolution {
        let resolution = try await resolveLink(request)
        guard let task = resolution.task else { return resolution }
        return TaskResolution(task: task, method: resolution.method, board: await state.allBoards().first { $0.id == task.boardID })
    }

    private func resolveLink(_ request: SessionLinkRequest) async throws -> TaskResolution {
        if let number = request.taskNumber {
            // host の会話の ID なら会話ごと移り、ほかのタスクから外れる
            let task = try store.linkSession(
                task: number, agent: request.agent, sessionID: request.agentSessionID, cwd: request.cwd, label: request.label)
            return TaskResolution(task: task, method: "explicit")
        }
        if let task = try store.task(linkedToSession: request.agentSessionID) {
            return TaskResolution(task: task, method: "existing")
        }
        // オーケストレーターはタスクの作業ではない。home で動くので、cwd が home のタスクがあると cwd 一致で結ばれてしまう
        if await isOrchestrator(agentSessionID: request.agentSessionID) {
            return TaskResolution(task: nil, method: "none")
        }
        // home は特定のタスクの作業場所ではない。移行で cwd が home のタスクができ、普段使いの herdr で home で起こした会話がみなそこに結ばれた
        if !isHome(request.cwd), let task = try store.task(matchingCwd: request.cwd) {
            let linked = try store.linkSession(
                task: task.number, agent: request.agent, sessionID: request.agentSessionID, cwd: request.cwd, label: request.label)
            return TaskResolution(task: linked, method: "cwd")
        }
        return TaskResolution(task: nil, method: "none")
    }

    private func isHome(_ cwd: String) -> Bool {
        (cwd as NSString).standardizingPath == (home as NSString).standardizingPath
    }

    /// session_id からタスクを引く
    public func resolve(agentSessionID sessionID: String?) async throws -> TaskResolution {
        guard let sessionID else { return TaskResolution(task: nil, method: "none") }
        if let task = try store.task(linkedToSession: sessionID) {
            return TaskResolution(task: task, method: "existing")
        }
        return TaskResolution(task: nil, method: "none")
    }

    /// Stop: 紐づくタスクが無ければブランチの open PR から起票して結び、あればその PR がどのタスクにも無いときだけ足す。PR の状態で列を進める
    public func stop(_ request: HookStopRequest) async throws -> HookStopResponse {
        let reminder = try await remind(request)
        var response = try await syncPullRequests(request)
        response.reminder = reminder
        return response
    }

    /// host の会話の Stop の callback。CLI は callback に返すまでターンを閉じないので、gh を呼ぶ PR のリンクと列の同期は返した後に回す
    public func stopConversation(_ request: HookStopRequest) async throws -> String? {
        let reminder = try await remind(request)
        let logger = logger
        Task {
            do {
                for message in try await syncPullRequests(request).messages {
                    logger.info("stop hook", metadata: ["session": .string(request.agentSessionID), "message": .string(message)])
                }
            } catch {
                logger.warning("stop hook sync failed", metadata: ["session": .string(request.agentSessionID), "error": "\(error)"])
            }
        }
        return reminder
    }

    /// UserPromptSubmit: 結ばれたタスクの題に合わせた会話の題を返す。印は、未受領の回答・レビューが無ければここで消す
    /// （残すと、ツールのたびに PostToolUse の hook が taskboard を起こし続ける）
    public func prompt(_ request: HookPromptRequest) async throws -> HookPromptResponse {
        guard let task = try store.task(linkedToSession: request.agentSessionID) else { return HookPromptResponse(sessionTitle: nil) }
        if let markers = feedback?.markers, try store.peekUndeliveredFeedback(task: task.number).bundle.isEmpty {
            markers.clear(sessions: [request.agentSessionID])
        }
        return HookPromptResponse(sessionTitle: SessionGuidance.retitle(current: request.sessionTitle, task: task))
    }

    /// 結ばれたタスクの待ちの見直し。DB だけで決まる
    private func remind(_ request: HookStopRequest) async throws -> String? {
        guard let task = try store.task(linkedToSession: request.agentSessionID) else { return nil }
        // 概況の部品の古さはこのターン数で数える
        try store.notePanelTurn(task: task.number)
        return try await waitReminder(task: task.number, request)
    }

    private func syncPullRequests(_ request: HookStopRequest) async throws -> HookStopResponse {
        var messages: [String] = []
        var task = try store.task(linkedToSession: request.agentSessionID)
        if let linked = task, let pr = await github.openPullRequest(cwd: request.cwd),
            try store.linkIfUnlinked(task: linked.number, url: pr.url) == .linked(task: linked.number)
        {
            messages.append(Copy.text("agent.hook.hookService.task", ["number": "\(pr.number)", "number2": "\(linked.number)"]))
            task = try store.task(number: linked.number) ?? linked
        } else if task == nil, let pr = await github.openPullRequest(cwd: request.cwd) {
            if let existing = try store.task(linkedToURL: pr.url) {
                task = existing
            } else if let board = try store.defaultBoard() {
                let wanted = pr.isDraft ? "working" : "review"
                let column = board.columns.contains { $0.id == wanted } ? wanted : (board.firstWorkColumn?.id ?? board.columns[0].id)
                let created = try store.createTask(
                    TaskCreateRequest(
                        boardID: board.id, columnID: column, title: pr.title,
                        note: Copy.text("agent.hook.hookService.created"), links: [pr.url]))
                messages.append(Copy.text("agent.hook.hookService.created.2", ["number": "\(pr.number)", "number2": "\(created.number)", "column": "\(column)"]))
                task = created
            }
            if let found = task {
                let linked = try store.linkSession(
                    task: found.number, agent: request.agent, sessionID: request.agentSessionID, cwd: request.cwd, label: "")
                task = linked
            }
        }
        guard let current = task else { return HookStopResponse(task: nil, messages: messages) }
        if let moved = try await github.syncNow(task: current) {
            messages.append(Copy.text("agent.hook.hookService.reminder", ["number": "\(moved.number)", "columnID": "\(moved.columnID)"]))
            return HookStopResponse(task: moved, messages: messages)
        }
        return HookStopResponse(task: current, messages: messages)
    }

    /// 待ちにした後に始まったターンで作業したのに、待ちのままの作業項目。待ちが解けていれば動かすよう頼む。
    /// 解けたかは daemon には分からない（人の返事・CI・レビューはターンの中で起きる）ので、作業したターンの終わりに 1 回だけ確かめさせる。
    /// owner が自分の項目を頼む。lead（委譲先でない会話）には owner の空いた項目も頼む（委譲先が担当する待ちは頼まない）
    func waitReminder(task number: Int, _ request: HookStopRequest) async throws -> String? {
        guard let started = request.turnStartedAt, request.turnUsedTools == true else { return nil }
        // 手作業待ちは利用者が［対応済みにする］で解くので、会話の作業からは解けたかが分からない
        let waits = try store.workItems(task: number).filter { $0.state == .wait && $0.blockerKind != .manual && $0.updatedAt < started }
        guard !waits.isEmpty else { return nil }
        let lead = await isLead(task: number, request)
        let names = await ownerNames(request)
        let stale = waits.filter { item in item.owner.isEmpty ? lead : names.contains { $0.hasPrefix(item.owner) } }
        let fresh = await remindedWaits.claim(stale)
        guard !fresh.isEmpty else { return nil }
        return Self.waitReminderText(task: number, items: fresh)
    }

    /// 作業項目の owner に書かれうる、このセッションの名前（Claude の会話 ID・host の会話の id）
    private func ownerNames(_ request: HookStopRequest) async -> [String] {
        var names = [request.agentSessionID]
        if let id = await conversationID(owning: request.agentSessionID) { names.append(id) }
        return names.filter { !$0.isEmpty }
    }

    /// lead が決まらない（タスクが state に無い）ときは、誰にも頼まないより頼む方をとる
    private func isLead(task number: Int, _ request: HookStopRequest) async -> Bool {
        let lead: TaskDeliveryTarget? = if let feedback { await feedback.lead(task: number) } else {
            await TaskDeliveryTarget.lead(task: number, state: state, conversations: nil)
        }
        switch lead {
        case nil: return true
        case .stoppedTerminal(let id): return id == request.agentSessionID
        case .conversation(let id): return await conversationID(owning: request.agentSessionID) == id
        }
    }

    /// feedback が無い（テストの）ときは、state の会話の今の ID だけで引く
    private func conversationID(owning agentSessionID: String) async -> String? {
        if let feedback, let id = await feedback.conversationID(owning: agentSessionID) { return id }
        return await state.allConversations().first { $0.agentSessionID == agentSessionID }?.id
    }

    static func waitReminderText(task: Int, items: [WorkItem]) -> String {
        let lines = items.map { item in
            let blocker = [item.blockerKind?.rawValue, item.blockerText.isEmpty ? nil : item.blockerText].compactMap { $0 }.joined(separator: ": ")
            return "- [\(item.itemID)] \(item.title)" + (blocker.isEmpty ? "" : "（\(blocker)）")
        }
        return Copy.text("agent.hook.hookService.blocker", ["task": "\(task)"])
            + lines.joined(separator: "\n")
            + Copy.text("agent.hook.hookService.blocker.2")
    }
}

/// 見直しを頼んだ待ち（作業項目と、待ちにした時刻）。daemon を起こし直すと忘れ、同じ待ちをもう 1 回だけ頼むことがある
actor RemindedWaits {
    private var seen: Set<String> = []

    /// まだ頼んでいない待ちを返し、頼んだことにする。待ちを付け直す（updatedAt が変わる）と別の待ちとして数える
    func claim(_ items: [WorkItem]) -> [WorkItem] {
        items.filter { seen.insert("\($0.itemID)@\($0.updatedAt.timeIntervalSince1970)").inserted }
    }
}
