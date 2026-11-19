import Foundation
import Logging
import TaskboardKit

/// 委譲先の会話（`notifyParent`）のターンの終わりと回答待ちを、起こした側の host の会話に発言として届ける。
/// 残っている知らせは委譲先の会話の記録（`parentNoticeTurns`・`parentNoticeAt`）が持つので、daemon が起き直しても落とさない
actor ConversationNotices {
    let conversations: ConversationService
    let state: DaemonState
    private var delivering: Set<String> = []
    private let logger = Logger(label: "uk.whatn.taskboardd.notices")

    init(conversations: ConversationService, state: DaemonState) {
        self.conversations = conversations
        self.state = state
    }

    /// 1 分ごとに見直す（起き直した直後の分と、届け先が空くのを待っている分）
    func run() async {
        await state.observe(every: LinkNotices.sweepInterval, sweepFirst: true, handle: { _ in }, sweep: { await self.sweep() })
    }

    /// 会話が入力待ちに入った：委譲先として残した知らせと、起こした側として受ける知らせを届ける
    func conversationIdle(_ id: String) async {
        for child in await conversations.pendingNotices() {
            if child == id {
                await deliver(child)
            } else if await conversations.noticeState(child)?.record.parentConversationId == id {
                await deliver(child)
            }
        }
    }

    func sweep() async {
        for child in await conversations.pendingNotices() { await deliver(child) }
    }

    /// 委譲先 `child` の残っている知らせを届ける。委譲先が生成中なら届けない（ターンが終わってから最後の返事と一緒に届ける）
    func deliver(_ child: String) async {
        guard delivering.insert(child).inserted else { return }
        defer { delivering.remove(child) }
        guard let current = await conversations.noticeState(child), current.record.notifyParent, let at = current.record.parentNoticeAt, !current.busy
        else { return }
        let record = current.record
        // 問いは答えられた後で、数えたターンも無い
        guard record.parentNoticeTurns > 0 || !current.requests.isEmpty else {
            await conversations.noticeDelivered(child, at: at)
            return
        }
        let reply = record.parentNoticeTurns > 0 ? await conversations.latestReply(child) : nil
        let text = Self.text(record: record, reply: reply, requests: current.requests)
        if let parent = record.parentConversationId {
            guard await conversations.noticeState(parent) != nil else {
                logger.info("notice dropped: parent conversation removed", metadata: ["conversation": .string(child), "parent": .string(parent)])
                await conversations.noticeDelivered(child, at: at)
                return
            }
            let uuid = StableUUID.make("taskboard-notice:\(child):\(Int((at.timeIntervalSince1970 * 1000).rounded()))")
            // 人が止めた親は起こさない。人が戻したとき（`conversationIdle`）に届ける
            switch await conversations.deliver(conversationID: parent, text: text, uuid: uuid, kind: .delegateNotice) {
            case .delivered:
                logger.info("notice delivered to conversation", metadata: ["conversation": .string(child), "parent": .string(parent)])
                await conversations.noticeDelivered(child, at: at)
            case .cancelled:
                await conversations.noticeCancelled(child, at: at)
            case .busy, .unknown, nil:
                return
            }
        } else {
            await conversations.noticeDelivered(child, at: at)
        }
    }

    /// 起動した側の agent が読む文。ターンの終わりがあれば「ターンを終えた」、無ければ「回答を待っている」で始め、回答待ちがあれば返事の前に載せる
    static func text(record: ConversationRecord, reply: String?, requests: [ConversationRequest]) -> String {
        let name = "\(record.id.prefix(8))" + (record.displayTitle.map { "「\($0)」" } ?? "") + (record.taskNumber.map { "（#\($0)）" } ?? "")
        let endedTurn = record.parentNoticeTurns > 0
        var lines = [
            TaskboardNotice.marker(.delegate, ["conversation": String(record.id.prefix(8)), "task": record.taskNumber.map(String.init) ?? ""]),
            endedTurn ? TaskboardNotice.delegateTurnHead : TaskboardNotice.delegateAskHead,
            Copy.text("agent.notice.conversationNotices.lines", ["name": "\(name)"]),
            "- conversation_id: \(record.id)",
            TaskboardNotice.senderItem,
        ]
        if record.parentNoticeTurns > 1 {
            lines.append(Copy.text("agent.notice.conversationNotices.lines.2", ["parentNoticeTurns": "\(record.parentNoticeTurns - 1)"]))
        }
        if !requests.isEmpty { lines.append(Copy.text("agent.notice.conversationNotices.lines.3", ["requests": "\(requests.count)"])) }
        lines.append(Copy.text("agent.notice.conversationNotices.lines.4") + (requests.isEmpty ? "" : Copy.text("agent.notice.conversationNotices.lines.5")))
        if !requests.isEmpty {
            lines.append(Copy.text("agent.notice.conversationNotices.lines.6"))
            lines += requests.flatMap(\.lines)
        }
        if endedTurn {
            lines.append(TaskboardNotice.replyHeading)
            lines.append(reply ?? Copy.text("agent.notice.conversationNotices.lines.7"))
        }
        return lines.joined(separator: "\n")
    }
}
