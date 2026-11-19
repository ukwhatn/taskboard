import Foundation

/// 受信箱の 1 行。daemon には持たず、アプリが state から導く。
public struct InboxItem: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// 文書に付いた未回答の質問
        case question(Ask)
        /// セッションが立てたレビュー依頼
        case reviewRequest(ReviewRequest)
        /// セッションが頼んだ手作業（作業項目の手作業待ち）。［対応済みにする］で作業中に戻し、済んだことをセッションへ届ける
        case manualWork(WorkItem)
        /// 新しく publish された文書
        case document(Document)
        /// 自分の PR の CI・レビューの変化と、新しいレビュー依頼
        case pullRequest(PRNotice)
        /// 自分の番の PR（今の状態から作る）。理由は `.reviewRequested`（レビューを頼まれている）・`.ciFailed`（自分の PR の CI が落ちている）・
        /// `.changesRequested`（自分の PR に修正を頼まれている）のどれか
        case pullRequestTurn(PullRequestSummary, PRNotice.Kind)
        /// PR の取得が失敗している（rate limit・VPN 切れなど）
        case prSync(PRAccountStatus)
        /// 定期起動の回（起こした・失敗・スキップ）
        case scheduleRun(Schedule, ScheduleRun)
        /// オーケストレーターの最後の返事
        case orchestratorReply(OrchestratorReply)
        /// 着手済みで動いていないタスク（`BoardTask.stall`）。急ぎではないので通知しない
        case stalled(BoardTask, TaskStall)
        /// host の会話が答えを待っている問い（動いている間の問いと、defer で終えた問い）
        case conversationRequest(Conversation, ConversationRequest)
        /// 会話が概況に置いた、承認を待つ送る文面。タスクの概況の部品で本文を編集して［承認］する
        case panelDraft(OverviewPanel, PanelPart)
        /// 会話が文書の本文に置いた、承認を待つ送る文面。文書の本文の欄で本文を編集して［承認］する
        case docDraft(Document, DocDraft)
    }

    public enum Group: Hashable, Sendable {
        /// 自分が何かしないと先に進まないもの
        case waiting
        /// 読めば済むもの
        case notice
    }

    /// マシンをまたいで一意（`<machine>/<localID>`）。通知の identifier と、消したお知らせの記録に使う
    public var id: String { "\(machine.rawValue)/\(localID)" }
    /// マシンの中で一意な id（`ask/7` など）。前の版はこれを id にしていた
    public var localID: String
    public var kind: Kind
    public var group: Group
    public var machine: MachineID
    public var taskNumber: Int?
    public var title: String
    /// 補足（タスク、文書、送り主など）。画面は「・」で区切って並べる
    public var details: [String]
    public var at: Date

    public init(id localID: String, kind: Kind, group: Group, machine: MachineID, taskNumber: Int?, title: String, details: [String], at: Date) {
        self.localID = localID
        self.kind = kind
        self.group = group
        self.machine = machine
        self.taskNumber = taskNumber
        self.title = title
        self.details = details.filter { !$0.isEmpty }
        self.at = at
    }

    public var detail: String { details.joined(separator: "・") }

    public var taskKey: TaskKey? { taskNumber.map { TaskKey(machine: machine, number: $0) } }

    /// 受信箱の並び: 対応待ちが先、新しい順。同じ時刻は id（マシンを含む）の順にする（決めておかないと、更新のたびに行が入れ替わる）
    public static func inboxOrder(_ a: InboxItem, _ b: InboxItem) -> Bool {
        if a.group != b.group { return a.group == .waiting }
        if a.at != b.at { return a.at > b.at }
        return a.id < b.id
    }
}

extension MachineState {
    /// このマシンの受信箱。対応待ち（質問 / レビュー依頼 / 手作業の依頼 / 応答待ちのセッション / 自分の番の PR）と、
    /// お知らせ（直近の文書・PR の変化・取得の失敗・オーケストレーターの返事・定期起動、動いていないタスク）。新しい順。
    /// `noticeWindow` より古いものはお知らせに出さない（動いていないタスクは古いこと自体が中身なので窓を見ない）。
    /// 題と補足は画面と通知にそのまま出る文（docs/ui-copy.md）
    /// 中身が変わるか、時刻で中身が変わる（お知らせが窓から出る・日付が替わって動いていない日数が増える）までは、前に数えたものを返す
    public func inboxItems(now: Date = Date(), noticeWindow: TimeInterval = 24 * 3600) -> [InboxItem] {
        inboxEntry(now: now, noticeWindow: noticeWindow).items
    }

    func inboxEntry(now: Date, noticeWindow: TimeInterval = 24 * 3600) -> MachineDerived.Inbox {
        derived.inbox(window: noticeWindow, now: now) { inbox(at: now, noticeWindow: noticeWindow) }
    }

    private func inbox(at now: Date, noticeWindow: TimeInterval) -> MachineDerived.Inbox {
        guard let machineID = machine?.id else { return MachineDerived.Inbox(items: [], computedAt: now, validUntil: .distantFuture) }
        var items: [InboxItem] = []
        // 中身が時刻で変わる最初の時刻。動いていない日数は日付で数えるので次の日付の頭、お知らせは窓から出る時刻。今の時刻を使った項目があれば今
        var validUntil = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        func expires(_ at: Date) { validUntil = min(validUntil, at.addingTimeInterval(noticeWindow)) }
        func taskTitle(_ number: Int) -> String {
            tasks[TaskKey(machine: machineID, number: number)].map { "#\($0.number) \($0.title)" } ?? "#\(number)"
        }
        for ask in asks.values where ask.status == .open {
            let doc = documents[DocKey(machine: machineID, id: ask.docID)]
            let first = ask.questions.first?.question ?? ""
            let more = ask.questions.count > 1 ? String(localized: "（\(ask.questions.count)問）") : ""
            items.append(
                InboxItem(
                    id: "ask/\(ask.askID)", kind: .question(ask), group: .waiting, machine: machineID, taskNumber: ask.taskNumber,
                    title: first + more, details: [taskTitle(ask.taskNumber), doc?.displayTitle].compactMap { $0 }, at: ask.createdAt))
        }
        for request in reviewRequests.values {
            let docs = documents.values.filter { $0.taskNumber == request.taskNumber }.count
            items.append(
                InboxItem(
                    id: "review/\(request.taskNumber)", kind: .reviewRequest(request), group: .waiting, machine: machineID,
                    taskNumber: request.taskNumber, title: request.note.isEmpty ? String(localized: "文書のレビュー依頼") : request.note,
                    details: [taskTitle(request.taskNumber)] + (docs > 0 ? [String(localized: "文書\(docs)件")] : []), at: request.requestedAt))
        }
        for item in workItems.values where item.isManualWait {
            // 終わったタスクの待ちは古い記録なので依頼にしない
            guard let task = tasks[TaskKey(machine: machineID, number: item.taskNumber)], !isTerminal(task) else { continue }
            let request = item.blockerText.isEmpty ? nil : item.blockerText
            items.append(
                InboxItem(
                    id: "manual/\(item.itemID)", kind: .manualWork(item), group: .waiting, machine: machineID, taskNumber: item.taskNumber,
                    title: request ?? item.title, details: [taskTitle(item.taskNumber), request.map { _ in item.title }].compactMap { $0 },
                    at: item.updatedAt))
        }
        for conversation in conversations.values {
            for request in conversation.requests {
                let questions = request.waiting.questions ?? []
                let more = questions.count > 1 ? String(localized: "（\(questions.count)問）") : ""
                items.append(
                    InboxItem(
                        id: "conversation/\(conversation.id)/\(request.id)", kind: .conversationRequest(conversation, request), group: .waiting,
                        machine: machineID, taskNumber: conversation.taskNumber,
                        title: conversation.title ?? String(localized: "Claude Codeが応答を待っています"),
                        details: [questions.first.map { $0.question + more } ?? request.elicitation?.message, conversation.taskNumber.map(taskTitle)]
                            .compactMap { $0 },
                        at: request.waiting.since))
            }
        }
        for panel in panels.values {
            guard let task = tasks[panel.id], !isTerminal(task) else { continue }
            for part in panel.openDrafts {
                guard case .draft(let draft) = part.spec.content else { continue }
                items.append(
                    InboxItem(
                        id: "draft/\(panel.taskNumber)/\(part.id)", kind: .panelDraft(panel, part), group: .waiting, machine: machineID,
                        taskNumber: panel.taskNumber, title: draft.title.isEmpty ? String(localized: "送る文面の承認") : draft.title,
                        details: [String(localized: "宛先：\(draft.to)"), taskTitle(panel.taskNumber)], at: part.updatedAt))
            }
        }
        for doc in documents.values {
            guard let task = tasks[TaskKey(machine: machineID, number: doc.taskNumber)], !isTerminal(task) else { continue }
            for draft in doc.openDrafts {
                items.append(
                    InboxItem(
                        id: "docdraft/\(doc.docID)/\(draft.id)", kind: .docDraft(doc, draft), group: .waiting, machine: machineID,
                        taskNumber: doc.taskNumber, title: draft.draft.title.isEmpty ? String(localized: "送る文面の承認") : draft.draft.title,
                        details: [String(localized: "宛先：\(draft.draft.to)"), taskTitle(doc.taskNumber), doc.displayTitle], at: draft.updatedAt))
            }
        }
        let taskByURL = Dictionary(
            tasks.values.flatMap { task in task.pullRequestLinks.map { ($0.url, task.number) } }, uniquingKeysWith: { a, _ in a })
        // 自分の PR と bot（Dependabot など）からのレビュー依頼は、タスクにリンクしたものだけを依頼にする（リンクしないものは、お知らせと PR の一覧に出す）。
        // 人からのレビュー依頼は、リンクが無くても依頼にする
        var turnURLs = Set<String>()
        for pr in prs?.pullRequests ?? [] {
            guard let reason = pr.turn else { continue }
            let number = taskByURL[pr.url]
            guard (reason == .reviewRequested && pr.authorIsBot != true) || number != nil else { continue }
            turnURLs.insert(pr.url)
            items.append(
                InboxItem(
                    id: "prturn/\(pr.url)", kind: .pullRequestTurn(pr, reason), group: .waiting, machine: machineID, taskNumber: number,
                    title: pr.title, details: [pr.shortLabel, number.map(taskTitle)].compactMap { $0 }, at: pr.updatedAt))
        }
        let openAskDocs = Set(asks.values.filter { $0.status == .open }.map(\.docID))
        // 質問・送る文面の依頼を出した文書は、お知らせに重ねない
        for doc in documents.values where now.timeIntervalSince(doc.updatedAt) < noticeWindow && !openAskDocs.contains(doc.docID) && doc.openDrafts.isEmpty {
            expires(doc.updatedAt)
            items.append(
                InboxItem(
                    id: "doc/\(doc.docID)/\(doc.latestRev)", kind: .document(doc), group: .notice, machine: machineID, taskNumber: doc.taskNumber,
                    title: doc.displayTitle + (doc.latestRev > 1 ? String(localized: "（第\(doc.latestRev)版）") : ""), details: [taskTitle(doc.taskNumber)], at: doc.updatedAt))
        }
        if let prs {
            // 依頼に今の状態で出した PR の CI 失敗・修正依頼・レビュー依頼は、お知らせには重ねない
            for notice in prs.notices where now.timeIntervalSince(notice.at) < noticeWindow && !(PRNotice.turnKinds.contains(notice.kind) && turnURLs.contains(notice.url)) {
                let number = taskByURL[notice.url]
                expires(notice.at)
                items.append(
                    InboxItem(
                        id: "pr/\(notice.id)", kind: .pullRequest(notice), group: .notice, machine: machineID, taskNumber: number,
                        title: notice.title, details: [notice.label, notice.detail, number.map(taskTitle) ?? ""], at: notice.at))
            }
            for account in prs.accounts {
                guard let message = account.failureMessage else { continue }
                if account.fetchedAt == nil { validUntil = now }
                items.append(
                    InboxItem(
                        id: "prsync/\(account.id)", kind: .prSync(account), group: .notice, machine: machineID, taskNumber: nil,
                        title: message, details: ["\(account.account)@\(account.host)"], at: account.fetchedAt ?? now))
            }
        }
        if let reply = orchestrator?.lastReply, now.timeIntervalSince(reply.at) < noticeWindow {
            expires(reply.at)
            let lines = reply.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            items.append(
                InboxItem(
                    id: "orchestrator/\(Int(reply.at.timeIntervalSince1970 * 1000))", kind: .orchestratorReply(reply), group: .notice,
                    machine: machineID, taskNumber: nil, title: lines.first ?? String(localized: "オーケストレーターの応答"),
                    details: [String(localized: "オーケストレーター")] + lines.dropFirst().prefix(1), at: reply.at))
        }
        let workByTask = Dictionary(grouping: workItems.values, by: \.taskNumber)
        for task in tasks.values {
            guard let stall = task.stall(workItems: workByTask[task.number] ?? [], terminal: isTerminal(task), now: now) else { continue }
            let column = boards[task.boardID]?.columns.first { $0.id == task.columnID }?.label
            items.append(
                InboxItem(
                    id: "stall/\(task.number)", kind: .stalled(task, stall), group: .notice, machine: machineID, taskNumber: task.number,
                    title: taskTitle(task.number), details: [column, stall.label].compactMap { $0 }, at: stall.since))
        }
        for schedule in schedules.values {
            guard let run = schedule.lastRun, now.timeIntervalSince(run.createdAt) < noticeWindow else { continue }
            expires(run.createdAt)
            let title: String
            if run.skipped != nil {
                title = String(localized: "定期起動「\(schedule.name)」をスキップしました")
            } else if run.stage == .failed {
                title = String(localized: "定期起動「\(schedule.name)」を起動できませんでした")
            } else {
                title = String(localized: "定期起動「\(schedule.name)」を実行しました")
            }
            items.append(
                InboxItem(
                    id: "sched/\(schedule.scheduleID)/\(run.id)/\(run.stage?.rawValue ?? "")", kind: .scheduleRun(schedule, run), group: .notice,
                    machine: machineID, taskNumber: schedule.taskNumber, title: title,
                    details: [run.skipped, schedule.taskNumber.map(taskTitle)].compactMap { $0 }, at: run.createdAt))
        }
        return MachineDerived.Inbox(items: items.sorted(by: InboxItem.inboxOrder), computedAt: now, validUntil: validUntil)
    }
}
