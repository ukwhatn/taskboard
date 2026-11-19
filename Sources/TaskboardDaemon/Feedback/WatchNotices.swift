import Foundation
import Logging
import TaskboardKit

/// 監視（`watch`）の出来事を、届け先（会話か、タスクの lead）に 1 通にまとめて発言として入れる。作りは `LinkNotices` と同じで、違うのは次のところ。
///
/// - 監視は起動か再開のために作るので、止まった会話・終了した会話・人が止めた会話も再開する（`DeliveryKind.watch`）。止まった TUI の lead は会話で戻す
/// - タスク宛てでタスクにセッションが 1 つも無ければ、セッションができるまで溜めておく（監視で新しい会話は起動しない）
/// - 届けたら、1 回だけの監視と、マージ・クローズした issue・PR の監視を終える（`Store.markWatchEventsDelivered`）。届け先の会話の記録が無ければ終える
/// - 期限を過ぎた監視は 60 秒ごとの見直しで終える。届けていない出来事も届けない
actor WatchNotices {
    let store: Store
    let state: DaemonState
    private let delivery: NoticeDelivery<Int64>
    private let now: @Sendable () -> Date
    private var delivering: Set<Int64> = []
    private let logger = Logger(label: "uk.whatn.taskboardd.watch-notices")

    init(store: Store, state: DaemonState, conversations: ConversationService?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.state = state
        delivery = NoticeDelivery(state: state, conversations: conversations)
        self.now = now
    }

    func run() async {
        await state.observe(every: LinkNotices.sweepInterval, sweepFirst: true, handle: { _ in }, sweep: { await self.sweep() })
    }

    /// `GitHubSync` が出来事を足した
    func eventsRecorded(_ ids: [Int64]) async {
        for id in ids { await deliver(watch: id) }
    }

    /// 会話が入力待ちに入った（`ConversationService.onIdle`）。その会話宛てと、その会話のタスク宛ての見張りを渡す
    func conversationIdle(_ id: String) async {
        let task = (try? store.conversation(id: id))??.taskNumber
        for watch in pending(where: { $0.conversationId == id || (task != nil && $0.taskNumber == task) }) { await deliver(watch: watch) }
    }

    func sweep() async {
        do {
            try store.endExpiredWatches(at: now())
            try store.purgeFinishedWatches(at: now())
        } catch {
            logger.warning("watches not swept", metadata: ["error": "\(error)"])
        }
        for id in (try? store.watchesWithUndeliveredEvents()) ?? [] { await deliver(watch: id) }
    }

    /// 届けていない出来事のある有効な見張りのうち、`matches` に合うもの
    private func pending(where matches: (Store.WatchRow) -> Bool) -> [Int64] {
        ((try? store.watchesWithUndeliveredEvents()) ?? []).filter { id in (try? store.watchRow(id: id)).flatMap { $0 }.map(matches) ?? false }
    }

    func deliver(watch id: Int64) async {
        guard delivering.insert(id).inserted else { return }
        defer { delivering.remove(id) }
        guard let row = try? store.watchRow(id: id), row.stateValue == .active, let (text, ids) = message(row), !ids.isEmpty else { return }
        let uuidSeed = "taskboard-watch:\(id):" + ids.map(String.init).joined(separator: ",")
        let outcome: NoticeDelivery<Int64>.Outcome
        if let conversationID = row.conversationId {
            guard (try? store.conversation(id: conversationID)) != nil else {
                logger.info("watch ended: conversation missing", metadata: ["watch": .stringConvertible(id), "conversation": .string(conversationID)])
                try? store.endWatch(id: id, .targetMissing, at: now())
                return
            }
            outcome = await delivery.deliver(text, toConversation: conversationID, key: id, uuidSeed: uuidSeed, kind: .watch)
        } else if let number = row.taskNumber, let target = await delivery.lead(task: number) {
            // 止まった TUI を戻したら、戻した会話が入力待ちに入ったとき（`conversationIdle`）にそこへ届ける
            outcome = await delivery.deliver(text, to: target, task: number, key: id, uuidSeed: uuidSeed, kind: .watch)
        } else {
            return
        }
        guard case .delivered(let to) = outcome else { return }
        logger.info("watch events delivered", metadata: ["watch": .stringConvertible(id), "to": .string(to), "count": .stringConvertible(ids.count)])
        markDelivered(id, ids)
    }

    /// 届ける文と、それで届けたことにする出来事の id。読めなければ nil
    private func message(_ row: Store.WatchRow) -> (String, [Int64])? {
        guard let id = row.id else { return nil }
        if row.kind == Watch.Kind.command.rawValue {
            guard let pending = try? store.undeliveredCommandEvents(watch: id) else { return nil }
            let shown = Array(pending.suffix(Self.commandResultsPerMessage))
            return (Self.commandText(row, results: shown.map(\.result), omitted: pending.count - shown.count), pending.map(\.id))
        }
        guard let pending = try? store.undeliveredWatchEvents(watch: id) else { return nil }
        let collapsed = LinkNotice.collapsed(pending, notice: \.notice, id: \.id)
        let shown = Array(collapsed.suffix(LinkNotices.perMessage))
        return (Self.text(row, notices: shown.map(\.notice), omitted: collapsed.count - shown.count), pending.map(\.id))
    }

    /// 1 通に載せるコマンドの回の結果（出力の末尾を載せるので少なくする）
    static let commandResultsPerMessage = 3

    private func markDelivered(_ id: Int64, _ ids: [Int64]) {
        do {
            try store.markWatchEventsDelivered(watch: id, ids: ids, at: now())
        } catch {
            logger.warning("watch events not marked delivered", metadata: ["watch": .stringConvertible(id), "error": "\(error)"])
        }
    }

    /// 会話が読む文。GitHub の本文は載せない（外の人が書いた文が、人の発言としてセッションに入るため）
    static func text(_ row: Store.WatchRow, notices: [LinkNotice], omitted: Int) -> String {
        let label = row.url.map { TaskLink(id: 0, url: $0, kind: TaskLink.kind(of: $0), addedAt: .distantPast).shortLabel } ?? row.repoLabel ?? ""
        var lines = [
            TaskboardNotice.marker(.watch, ["id": "\(row.id ?? 0)"]),
            TaskboardNotice.watchPrefix + "\(row.id ?? 0)（\(label)）" + TaskboardNotice.watchMarker,
            TaskboardNotice.senderItem,
            TaskboardNotice.githubBodyItem,
        ]
        if row.kind == Watch.Kind.repo.rawValue {
            lines.append(Copy.text("agent.notice.watchNotices.lines") + (row.query.map { Copy.text("agent.notice.watchNotices.lines.2", ["value": "\($0)"]) } ?? ""))
        }
        if omitted > 0 { lines.append(Copy.text("agent.notice.linkNotices.lines", ["omitted": "\(omitted)"])) }
        if row.once {
            lines.append(Copy.text("agent.notice.watchNotices.lines.3"))
        } else if row.snapshotValue?.isFinished == true {
            lines.append(Copy.text("agent.notice.watchNotices.lines.4"))
        }
        lines.append(Copy.text("agent.notice.linkNotices.lines.2"))
        for notice in notices { lines.append("- " + LinkNotices.line(notice)) }
        if let prompt = row.prompt { lines += [TaskboardNotice.promptHeading, prompt] }
        return lines.joined(separator: "\n")
    }
}

extension WatchNotices {
    /// コマンドの見張りの文。出力は自分のコマンドのものなので末尾を載せる（印の無い fence で囲む）
    static func commandText(_ row: Store.WatchRow, results: [Store.CommandWatchResult], omitted: Int) -> String {
        let spec = row.commandSpec
        var lines = [
            TaskboardNotice.marker(.watch, ["id": "\(row.id ?? 0)"]),
            TaskboardNotice.watchPrefix + Copy.text("agent.notice.watchNotices.lines.5", ["id": "\(row.id ?? 0)"]) + TaskboardNotice.watchMarker,
            TaskboardNotice.senderItem,
            Copy.text("agent.notice.watchNotices.lines.6") + MarkdownCode.inline(String((spec?.command ?? "").split(separator: "\n").first ?? "").prefixed(200)),
        ]
        if let cwd = spec?.cwd { lines.append(Copy.text("agent.notice.watchNotices.lines.7", ["cwd": "\(cwd)"])) }
        if let spec { lines.append(Copy.text("agent.notice.watchNotices.lines.8") + conditionText(spec)) }
        if omitted > 0 { lines.append(Copy.text("agent.notice.watchNotices.lines.9", ["omitted": "\(omitted)"])) }
        if row.once { lines.append(Copy.text("agent.notice.watchNotices.lines.3")) }
        lines.append(Copy.text("agent.notice.watchNotices.lines.10"))
        for result in results {
            lines.append("- " + resultLine(result))
            if let matched = result.matchedLine { lines.append(Copy.text("agent.notice.watchNotices.lines.11") + MarkdownCode.inline(matched.prefixed(200))) }
            if !result.outputTail.isEmpty {
                lines.append(Copy.text("agent.notice.watchNotices.lines.12") + (result.truncated || result.outputTail.count >= Store.CommandWatchResult.outputTailLimit ? Copy.text("agent.notice.watchNotices.lines.13") : "") + ":")
                lines.append(MarkdownCode.block(result.outputTail))
            }
        }
        if let prompt = row.prompt { lines += [TaskboardNotice.promptHeading, prompt] }
        return lines.joined(separator: "\n")
    }

    static func conditionText(_ spec: CommandWatchSpec) -> String {
        let every = Copy.text("agent.notice.watchNotices.every", ["interval": "\(spec.interval)"])
        switch spec.condition {
        case .succeeds: return Copy.text("agent.notice.watchNotices.succeeds", ["every": "\(every)"])
        case .fails: return Copy.text("agent.notice.watchNotices.fails", ["every": "\(every)"])
        case .matches: return Copy.text("agent.notice.watchNotices.matches", ["inline": "\(MarkdownCode.inline(spec.pattern ?? ""))", "every": "\(every)"])
        case .changes: return Copy.text("agent.notice.watchNotices.changes", ["every": "\(every)"])
        case .finishes: return Copy.text("agent.notice.watchNotices.finishes")
        }
    }

    static func resultLine(_ result: Store.CommandWatchResult) -> String {
        if result.interrupted { return Copy.text("agent.notice.watchNotices.resultLine") }
        let took = Copy.text("agent.notice.watchNotices.took", ["seconds": "\(result.seconds)"])
        if result.timedOut { return Copy.text("agent.notice.watchNotices.took.2", ["took": "\(took)"]) }
        return Copy.text("agent.notice.watchNotices.exitCode", ["code": result.exitCode.map(String.init) ?? Copy.text("agent.notice.watchNotices.unknownCode"), "took": took])
    }
}

extension String {
    fileprivate func prefixed(_ limit: Int) -> String { count > limit ? String(prefix(limit)) + "…" : self }
}
