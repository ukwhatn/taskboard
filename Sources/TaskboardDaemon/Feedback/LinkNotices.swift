import Foundation
import Logging
import TaskboardKit

/// タスクにリンクした PR・issue の通知（`taskLinkNotice`）を、タスクの lead（`TaskDeliveryTarget`）に 1 通にまとめて発言として入れる。
///
/// - 入れるのは lead が入力待ちのときだけ。生成中に溜まった分は、空いたとき（会話が idle に入った）か 60 秒ごとの見直しで渡す
/// - 止まった会話・止まった TUI は、対応が要る知らせ（`LinkNotice.needsAction`）を含むときだけ起こす（TUI は会話で戻す）。含まなければ次に動いたときに渡す。
///   人が止めた会話は起こさず、人が戻すまで残す
/// - 1 通に載せるのは 20 件まで。同じリンクの状態の移りは新しい方だけを載せ、残りは件数だけ書いて、全部を届けた扱いにする
actor LinkNotices {
    let store: Store
    let state: DaemonState
    private let delivery: NoticeDelivery<Int>
    private let now: @Sendable () -> Date
    private var delivering: Set<Int> = []
    private let logger = Logger(label: "uk.whatn.taskboardd.link-notices")

    /// 知らせの見直しの間隔。見張りの知らせ（`WatchNotices`）と委譲先の知らせ（`ConversationNotices`）も同じ
    static let sweepInterval: Duration = .seconds(60)
    static let perMessage = 20

    init(store: Store, state: DaemonState, conversations: ConversationService?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.state = state
        delivery = NoticeDelivery(state: state, conversations: conversations)
        self.now = now
    }

    func run() async {
        await state.observe(every: Self.sweepInterval, sweepFirst: true, handle: { _ in }, sweep: { await self.sweep() })
    }

    /// `GitHubSync` が知らせを足した
    func noticesRecorded(_ numbers: [Int]) async {
        for number in numbers { await deliver(task: number) }
    }

    /// 会話が入力待ちに入った（`ConversationService.onIdle`）
    func conversationIdle(_ id: String) async {
        guard let number = (try? store.conversation(id: id))??.taskNumber else { return }
        await deliver(task: number)
    }

    func sweep() async {
        do {
            try store.purgeDeliveredLinkNotices(at: now())
        } catch {
            logger.warning("delivered link notices not purged", metadata: ["error": "\(error)"])
        }
        for number in (try? store.tasksWithUndeliveredLinkNotices()) ?? [] { await deliver(task: number) }
    }

    func deliver(task number: Int) async {
        guard delivering.insert(number).inserted else { return }
        defer { delivering.remove(number) }
        guard let pending = try? store.undeliveredLinkNotices(task: number), !pending.isEmpty else { return }
        let collapsed = TaskLinkNotice.collapsed(pending)
        let shown = Array(collapsed.suffix(Self.perMessage))
        let kind = DeliveryKind.linkNotice(actionable: collapsed.contains { $0.notice.needsAction })
        let notes = Dictionary(((try? store.task(number: number))??.links ?? []).filter { !$0.note.isEmpty }.map { ($0.url, $0.note) }, uniquingKeysWith: { a, _ in a })
        let text = Self.text(task: number, notices: shown, omitted: collapsed.count - shown.count, notes: notes)
        let ids = pending.map(\.id)
        guard let target = await delivery.lead(task: number) else { return }
        let uuidSeed = "taskboard-link-notice:" + ids.map(String.init).joined(separator: ",")
        // 止まった TUI を戻したら、戻した会話が入力待ちに入ったとき（`conversationIdle`）にそこへ届ける
        guard case .delivered(let to) = await delivery.deliver(text, to: target, task: number, key: number, uuidSeed: uuidSeed, kind: kind) else { return }
        logger.info("link notices delivered", metadata: ["task": .stringConvertible(number), "to": .string(to), "count": .stringConvertible(ids.count)])
        markDelivered(ids)
    }

    private func markDelivered(_ ids: [Int64]) {
        do {
            try store.markLinkNoticesDelivered(ids: ids, at: now())
        } catch {
            logger.warning("link notices not marked delivered", metadata: ["error": "\(error)"])
        }
    }

    /// lead が読む文。GitHub の本文は載せない（外の人が書いた文が、人の発言としてセッションに入るため）。
    /// 動いたリンクにメモ（監視の代わりに残した指示。`Store.linkInsteadOfWatch`）があれば、最後に「作成時の指示:」の下に載せる
    static func text(task number: Int, notices: [TaskLinkNotice], omitted: Int, notes: [String: String]) -> String {
        var lines = [
            TaskboardNotice.marker(.link, ["task": "\(number)"]),
            TaskboardNotice.linkPrefix + "\(number) " + TaskboardNotice.linkMarker,
            TaskboardNotice.senderItem,
            TaskboardNotice.githubBodyItem,
        ]
        if omitted > 0 { lines.append(Copy.text("agent.notice.linkNotices.lines", ["omitted": "\(omitted)"])) }
        lines.append(Copy.text("agent.notice.linkNotices.lines.2"))
        for record in notices { lines.append("- " + line(record.notice)) }
        var noted: [String] = []
        for url in notices.map(\.notice.url) where !noted.contains(url) && notes[url] != nil { noted.append(url) }
        if !noted.isEmpty {
            lines.append(TaskboardNotice.promptHeading)
            for url in noted { lines.append("- \(label(url)): \(notes[url]!)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func label(_ url: String) -> String {
        TaskLink(id: 0, url: url, kind: TaskLink.kind(of: url), addedAt: .distantPast).shortLabel
    }

    static func line(_ notice: LinkNotice) -> String {
        let label = label(notice.url)
        let actor = notice.actor.map { "（\($0)）" } ?? ""
        let head = notice.target.map { "（\($0.prefix(7))）" } ?? ""
        let what =
            switch notice.kind {
            case .merged: Copy.text("agent.notice.linkNotices.merged") + actor
            case .closed: Copy.text("agent.notice.linkNotices.closed") + (notice.detail.map { "（\($0)）" } ?? "")
            case .reopened: Copy.text("agent.notice.linkNotices.reopened")
            case .ready: Copy.text("agent.notice.linkNotices.ready")
            case .draft: Copy.text("agent.notice.linkNotices.draft")
            case .commits: Copy.text("agent.notice.linkNotices.commits") + head
            case .checksPassed: Copy.text("agent.notice.linkNotices.checksPassed") + head
            case .checksFailed: Copy.text("agent.notice.linkNotices.checksFailed") + (notice.detail.map { ": \($0)" } ?? "")
            case .approved: Copy.text("agent.notice.linkNotices.approved") + actor
            case .changesRequested: Copy.text("agent.notice.linkNotices.changesRequested") + actor
            case .reviewed: Copy.text("agent.notice.linkNotices.reviewed") + actor
            case .comment: Copy.text("agent.notice.linkNotices.comment") + actor
            case .inlineComment: Copy.text("agent.notice.linkNotices.inlineComment") + actor
            case .inlineReply: Copy.text("agent.notice.linkNotices.inlineReply") + actor
            case .conflict: Copy.text("agent.notice.linkNotices.conflict")
            case .conflictResolved: Copy.text("agent.notice.linkNotices.conflictResolved")
            case .opened: Copy.text("agent.notice.linkNotices.opened") + actor + (notice.detail.map { "（label: \($0)）" } ?? "")
            case .tagged: Copy.text("agent.notice.linkNotices.tagged", ["detail": "\(notice.detail ?? "")"])
            case .devinWaiting: Copy.text("agent.notice.linkNotices.devinWaiting")
            case .devinPullRequest: Copy.text("agent.notice.linkNotices.devinPullRequest", ["targetURL": "\(notice.targetURL ?? "")"])
            case .devinFinished: Copy.text("agent.notice.linkNotices.devinFinished")
            case .devinExpired: Copy.text("agent.notice.linkNotices.devinExpired")
            }
        // コメントの URL はリンクの URL の下にあるときだけ使う。タグはリリースの画面
        let url = notice.kind == .tagged ? notice.targetURL ?? notice.url : notice.targetURL.flatMap { $0.hasPrefix(notice.url) ? $0 : nil } ?? notice.url
        return "\(label): \(what) \(url)"
    }
}
