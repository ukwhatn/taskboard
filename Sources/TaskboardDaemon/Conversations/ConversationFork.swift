import Foundation
import TaskboardKit

/// フォークと巻き戻しで、新しい Claude の会話 ID に写す地点（元の Claude の会話 ID と、写す最後の行の uuid）
struct ConversationFork: Equatable, Sendable {
    var session: String
    var uuid: String

    /// `messageID` の発言（`#n` は落とす）の地点。省くと末尾（生成中なら断る）。会話の transcript がまだ無ければ（フォーク・巻き戻しの後に
    /// まだ送っていない）、写す元の transcript の、写す地点までの中で探す。見つからなければ写し元（要約より前）を順に探す
    static func point(in lineage: TranscriptLineage, messageID: String?, generating: Bool) throws -> ConversationFork {
        let record = lineage.record
        if messageID == nil, let pending = lineage.pendingFork { return pending }
        guard let base = lineage.head else { throw ConversationError.notSent(record.id) }
        guard let messageID else {
            guard !generating else { throw ConversationError.busy(record.id, "生成中（末尾からはフォークできない）") }
            guard let last = TranscriptLines.last(in: base.url) else { throw ConversationError.notSent(record.id) }
            return ConversationFork(session: base.session, uuid: last.uuid)
        }
        let uuid = lineUUID(messageID)
        guard !uuid.isEmpty else { throw ConversationError.messageNotFound(uuid) }
        // 写す元の、まだ写していない後ろの行は、この会話の履歴に無い
        for segment in lineage.segments {
            if let line = TranscriptLines.find(uuid, in: segment.url, before: segment.end == .max ? nil : segment.end) {
                return ConversationFork(session: segment.session, uuid: line.uuid)
            }
        }
        throw ConversationError.messageNotFound(uuid)
    }

    /// `ChatMessage.id` の transcript の行の uuid（block の発言は `uuid#i`）
    static func lineUUID(_ messageID: String) -> String {
        messageID.firstIndex(of: "#").map { String(messageID[..<$0]) } ?? messageID
    }
}

extension ConversationRecord {
    func forked(from source: String, request: String, point: ConversationFork) -> ConversationRecord {
        var record = self
        record.forkSourceId = source
        record.forkRequestId = request
        record.forkAt = point.uuid
        record.pendingForkSessionId = point.session
        record.pendingForkAt = point.uuid
        return record
    }
}
