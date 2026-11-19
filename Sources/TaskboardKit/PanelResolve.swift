import Foundation

// MARK: - 作業項目のまとまり

/// 計画の 1 まとまり（「M3」）。項目は作業中、未着手、済みの順
public struct WorkPlanGroup: Codable, Hashable, Sendable, Identifiable {
    /// まとまりの名前。まとまりに入れていない項目は空
    public var name: String
    public var items: [WorkItem]
    /// 見送りを除いた数と、済みの数
    public var total: Int
    public var done: Int
    /// 今のまとまり（並びで最初の、済んでいないまとまり）。画面はこれだけを開く
    public var isCurrent: Bool

    public var id: String { name }
    public var isFinished: Bool { total > 0 && done == total }
    public var fractionLabel: String { "\(done) / \(total)" }

    public init(name: String, items: [WorkItem], total: Int, done: Int, isCurrent: Bool) {
        self.name = name
        self.items = items
        self.total = total
        self.done = done
        self.isCurrent = isCurrent
    }
}

public enum WorkPlan {
    /// まとまりごとに分ける。まとまりの並びは計画順で最初に出た位置、項目は作業中・待ち・着手できる・未着手・済み・見送りの順（同じなら計画順）。
    /// `only` を渡せば、そのまとまりだけを並べた順で返す
    public static func groups(_ items: [WorkItem], only: [String] = []) -> [WorkPlanGroup] {
        let ordered = items.sorted { ($0.position, $0.itemID) < ($1.position, $1.itemID) }
        let effective = WorkItem.effectiveStates(of: ordered)
        var names: [String] = []
        for item in ordered where !names.contains(item.group) { names.append(item.group) }
        if !only.isEmpty { names = only.filter(names.contains) }
        let rank: (WorkItem) -> Int = { item in
            switch effective[item.itemID] ?? .todo {
            case .doing: 0
            case .wait: 1
            case .ready: 2
            case .todo: 3
            case .done: 4
            case .drop: 5
            }
        }
        var groups = names.map { name -> WorkPlanGroup in
            let members = ordered.filter { $0.group == name }
            let sorted = members.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
            let total = members.filter { effective[$0.itemID] != .drop }.count
            let done = members.filter { effective[$0.itemID] == .done }.count
            return WorkPlanGroup(name: name, items: sorted, total: total, done: done, isCurrent: false)
        }
        if let current = groups.firstIndex(where: { !$0.isFinished }) { groups[current].isCurrent = true }
        return groups
    }
}

// MARK: - 紐づけ先の解決

/// 紐づけた部品の今の値。計器は値・基準・状態、表は列と行、計画はまとまり
public struct PanelResolved: Codable, Hashable, Sendable {
    public var gauge: PanelGauge?
    public var columns: [String]?
    public var rows: [PanelRow]?
    public var plan: [WorkPlanGroup]?

    public init(gauge: PanelGauge? = nil, columns: [String]? = nil, rows: [PanelRow]? = nil, plan: [WorkPlanGroup]? = nil) {
        self.gauge = gauge
        self.columns = columns
        self.rows = rows
        self.plan = plan
    }
}

extension MachineState {
    /// 紐づけた部品の値を、この state から導く。アプリは fleet の state で、daemon は `GET /v1/tasks/{n}/panel` で同じ関数を使う
    public func resolve(_ part: PanelPartSpec, task: BoardTask) -> PanelResolved? {
        guard let bind = part.bind else { return nil }
        switch part.content {
        case .gauge(let gauge): return PanelResolved(gauge: resolveGauge(gauge, bind: bind, task: task))
        case .table:
            let (columns, rows) = resolveRows(bind, task: task)
            return PanelResolved(columns: columns, rows: rows)
        case .plan(let plan):
            let items = workItems(forTask: task.number)
            return PanelResolved(plan: WorkPlan.groups(items, only: plan.groups))
        case .diagram, .chart, .draft, .html:
            return nil
        }
    }

    /// 子のタスク: このタスクの会話が起動した会話の、別のタスク（作った順に 1 つずつ）
    public func childTasks(of task: BoardTask) -> [BoardTask] {
        var seen = Set<Int>()
        return conversations(of: task).flatMap { delegates(of: $0) }.compactMap { child -> BoardTask? in
            guard let number = child.taskNumber, number != task.number, seen.insert(number).inserted else { return nil }
            return tasks[TaskKey(machine: task.machine, number: number)]
        }
    }

    private func boundWork(_ bind: PanelBinding, task: BoardTask) -> [WorkItem] {
        let items = workItems(forTask: task.number)
        return bind.group.isEmpty ? items : items.filter { $0.group == bind.group }
    }

    private func resolveGauge(_ gauge: PanelGauge, bind: PanelBinding, task: BoardTask) -> PanelGauge {
        var result = gauge
        func fraction(_ done: Int, _ total: Int) {
            result.value = "\(done) / \(total)"
            result.amount = Double(done)
            result.basis = PanelBasis(kind: .denominator, value: "\(total)", amount: Double(total))
        }
        switch bind.source {
        case .work:
            let items = boundWork(bind, task: task)
            let progress = TaskProgress.derive(items)
            fraction(progress?.done ?? 0, progress?.total ?? 0)
            let mine = items.contains { $0.waitLine?.tone == .mine }
            result.tone = mine ? .attention : (progress.map { $0.total > 0 && $0.done == $0.total } ?? false) ? .done : .neutral
            result.note = progress?.currentLabel ?? progress?.primaryWait?.text ?? ""
        case .links:
            let states = task.pullRequestLinks.compactMap { links[$0.url]?.pullRequest }
            fraction(states.filter { $0.state == .merged }.count, task.pullRequestLinks.count)
            result.tone = states.contains { $0.checks?.isFailing == true } ? .failed : states.contains { $0.reviewDecision == "CHANGES_REQUESTED" } ? .attention : .neutral
        case .children:
            let children = childTasks(of: task)
            fraction(children.filter(isTerminal).count, children.count)
            result.tone = children.contains { child in conversations(of: child).contains { !$0.requests.isEmpty } } ? .attention : .neutral
        case .watches:
            let active = watches(of: task).filter { $0.state == .active }
            result.value = "\(active.count)"
            result.amount = Double(active.count)
            result.tone = active.contains { $0.error != nil } ? .failed : .neutral
        case .questions:
            let count = openQuestions(of: task).count
            result.value = "\(count)"
            result.amount = Double(count)
            result.tone = count > 0 ? .attention : .ok
        }
        return result
    }

    private func resolveRows(_ bind: PanelBinding, task: BoardTask) -> ([String], [PanelRow]) {
        switch bind.source {
        case .work:
            let items = WorkPlan.groups(boundWork(bind, task: task)).flatMap(\.items)
            let effective = WorkItem.effectiveStates(of: items)
            return (
                [String(localized: "番号"), String(localized: "項目"), String(localized: "状態")],
                items.map { item in
                    let state = effective[item.itemID] ?? .todo
                    let tone: PanelTone =
                        switch state {
                        case .done: .done
                        case .wait: item.waitLine?.tone == .mine ? .attention : .waiting
                        default: .neutral
                        }
                    return PanelRow(cells: [item.code, item.title, item.waitLine?.text ?? state.label], tone: tone)
                }
            )
        case .links:
            let shown = task.links.filter { [.githubPR, .githubIssue, .jira].contains($0.kind) }
            return (
                [String(localized: "リンク"), String(localized: "状態"), "CI", String(localized: "レビュー")],
                shown.map { link in Self.linkRow(link, status: links[link.url]) }
            )
        case .children:
            return (
                [String(localized: "タスク"), String(localized: "状況"), String(localized: "列")],
                childTasks(of: task).map { child in
                    let column = boards[child.boardID]?.columns.first { $0.id == child.columnID }?.label ?? child.columnID
                    let waiting = conversations(of: child).contains { !$0.requests.isEmpty }
                    return PanelRow(
                        cells: ["#\(child.number) \(child.title)", situation(of: child)?.headline ?? "", column],
                        tone: isTerminal(child) ? .done : waiting ? .attention : nil, open: PanelTarget(task: child.number))
                }
            )
        case .watches:
            return (
                [String(localized: "対象"), String(localized: "状態")],
                watches(of: task).map { watch in
                    let state: String =
                        if let error = watch.error { error } else {
                            switch watch.state {
                            case .active: String(localized: "監視中")
                            case .ended: String(localized: "終了")
                            case .cancelled: String(localized: "取り消し")
                            }
                        }
                    let tone: PanelTone? = watch.error != nil ? .failed : watch.state == .active ? nil : .done
                    return PanelRow(cells: [Self.watchTarget(watch), state], tone: tone, open: watch.url.map { PanelTarget(url: $0) })
                }
            )
        case .questions:
            return (
                [String(localized: "問い"), String(localized: "出どころ")],
                openQuestions(of: task).map { PanelRow(cells: [$0.text, $0.source], tone: .attention, open: $0.open) }
            )
        }
    }

    private func watches(of task: BoardTask) -> [Watch] {
        watches.values.filter { $0.machine == task.machine && $0.taskNumber == task.number }.sorted { $0.watchID < $1.watchID }
    }

    struct OpenQuestion {
        var text: String
        var source: String
        var open: PanelTarget?
    }

    /// 未回答の問い: 文書の質問と、タスクの会話の問い（権限の確認・AskUserQuestion・計画の承認・MCP の問い）
    private func openQuestions(of task: BoardTask) -> [OpenQuestion] {
        let asked = asks.values.filter { $0.machine == task.machine && $0.taskNumber == task.number && $0.status == .open }
            .sorted { $0.createdAt < $1.createdAt }
            .map { ask in
                OpenQuestion(
                    text: ask.questions.first?.question ?? "", source: documents[DocKey(machine: task.machine, id: ask.docID)]?.displayTitle ?? "",
                    open: PanelTarget(doc: ask.docID))
            }
        var requests: [OpenQuestion] = []
        for conversation in conversations(of: task) where !conversation.isClosed {
            for request in conversation.requests {
                requests.append(OpenQuestion(text: Self.requestText(request), source: conversation.customTitle ?? conversation.title ?? ""))
            }
        }
        return asked + requests
    }

    private static func requestText(_ request: ConversationRequest) -> String {
        if let question = request.waiting.questions?.first?.question { return question }
        if let permission = request.waiting.permission { return permission.summary }
        if request.plan != nil { return String(localized: "計画の承認") }
        return request.toolName
    }

    static func linkRow(_ link: TaskLink, status: LinkStatus?) -> PanelRow {
        let open = PanelTarget(url: link.url)
        if let pr = status?.pullRequest {
            let state: String =
                switch pr.state {
                case .merged: String(localized: "マージ済み")
                case .closed: String(localized: "クローズ")
                case .open: pr.isDraft ? String(localized: "下書き") : String(localized: "オープン")
                }
            let ci: String =
                switch pr.checks {
                case .success: String(localized: "成功")
                case .failure, .error: String(localized: "失敗")
                case .pending, .expected: String(localized: "実行中")
                case nil: "—"
                }
            let review: String =
                switch pr.reviewDecision {
                case "APPROVED": String(localized: "承認")
                case "CHANGES_REQUESTED": String(localized: "修正依頼")
                case "REVIEW_REQUIRED": String(localized: "レビュー待ち")
                default: "—"
                }
            let tone: PanelTone? =
                pr.state == .merged || pr.state == .closed ? .done
                : pr.checks?.isFailing == true ? .failed : pr.reviewDecision == "CHANGES_REQUESTED" ? .attention : nil
            return PanelRow(cells: [link.shortLabel, state, ci, review], tone: tone, symbol: .pullRequest, open: open)
        }
        if let jira = status?.jira {
            return PanelRow(cells: [link.shortLabel, jira.statusName, "—", "—"], tone: jira.category == .done ? .done : nil, open: open)
        }
        return PanelRow(cells: [link.shortLabel, status?.error == nil ? "—" : String(localized: "取得できません"), "—", "—"], open: open)
    }

    static func watchTarget(_ watch: Watch) -> String {
        if let command = watch.command { return String(command.command.prefix { !$0.isNewline }) }
        if let url = watch.url { return TaskLink(id: 0, url: url, kind: url.contains("/pull/") ? .githubPR : .githubIssue, addedAt: .distantPast).shortLabel }
        return watch.repo ?? ""
    }
}
