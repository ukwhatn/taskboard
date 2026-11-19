import Foundation

/// Claude の会話 ID の transcript の頭より前の発言を持つ、写し元の transcript。
/// CLI はフォーク・巻き戻し（`--fork-session --resume-session-at`）で、地点から親をたどって最後の要約の区切り（`compact_boundary`）までだけを
/// 新しい transcript に写す（区切りは親を持たない）。区切りより前の発言は写し元にだけ残る（2.1.303 で実測）
public struct TranscriptSource: Equatable, Sendable {
    public var session: String
    /// 写し元の transcript の中の、写っていない部分の終わり（区切りの行の頭）。transcript は追記だけなので位置は変わらない
    public var end: UInt64

    public init(session: String, end: UInt64) {
        self.session = session
        self.end = end
    }

    /// `fork` の transcript の頭が要約の区切りなら、その区切りの行を `source` の transcript で探して写し元にする。
    /// 頭が区切りでない（CLI が全部写した）か、写し元に区切りが無い・区切りより前に何も無ければ nil
    static func find(fork: URL, source session: String, at url: URL) -> TranscriptSource? {
        guard let boundary = TranscriptLines.headBoundary(in: fork), let line = TranscriptLines.line(boundary, in: url), line.start > 0 else { return nil }
        return TranscriptSource(session: session, end: line.start)
    }
}

/// 1 つの会話の履歴を読む transcript の並び。今の会話 ID の transcript（まだ無ければ写す元を地点まで）から、写し元を順にたどる
struct TranscriptLineage {
    /// 読む 1 本。`end` より前を読む
    struct Segment: Equatable {
        var session: String
        var url: URL
        var end: UInt64
    }

    /// 写し元を 1 つずつたどる上限（巻き戻しを重ねた回数。輪になった記録で止まらないように）
    static let depthLimit = 64

    let record: ConversationRecord
    /// `realpath` を通した transcript の置き場
    let projects: URL
    /// 記録した写し元（`Store.transcriptSource(of:)`）
    let recorded: (String) -> TranscriptSource?

    init(record: ConversationRecord, projects: URL, recorded: @escaping (String) -> TranscriptSource?) {
        self.record = record
        self.projects = projects.standardizedFileURL.resolvingSymlinksInPath()
        self.recorded = recorded
    }

    /// フォーク・巻き戻しの後でまだ transcript が無い会話の、写す元と地点（写す元の transcript があるときだけ）
    var pendingFork: ConversationFork? {
        guard TranscriptTail.locate(record.agentSessionId, in: projects) == nil, let pending = record.pendingForkSessionId, let at = record.pendingForkAt,
            TranscriptTail.locate(pending, in: projects) != nil
        else { return nil }
        return ConversationFork(session: pending, uuid: at)
    }

    /// 最初に読む 1 本。今の会話 ID の transcript か、フォーク・巻き戻しの後でまだ無ければ写す元の地点まで
    var head: Segment? {
        if let own = TranscriptTail.locate(record.agentSessionId, in: projects) {
            return Segment(session: record.agentSessionId, url: own, end: .max)
        }
        guard let pending = record.pendingForkSessionId, let at = record.pendingForkAt, let base = TranscriptTail.locate(pending, in: projects),
            let line = TranscriptLines.point(at, in: base)
        else { return nil }
        return Segment(session: pending, url: base, end: line.end)
    }

    /// `segment` の transcript の頭より前を持つ 1 本。transcript が無い（掃除で消えた）か、前に何も無ければ nil
    func next(after segment: Segment) -> Segment? {
        guard let source = source(of: segment.session), source.end > 0, let url = TranscriptTail.locate(source.session, in: projects) else { return nil }
        return Segment(session: source.session, url: url, end: source.end)
    }

    /// 頭から写し元をたどった並び（読む順）
    var segments: [Segment] {
        guard var segment = head else { return [] }
        var result = [segment]
        while result.count < Self.depthLimit, let next = next(after: segment), !result.contains(where: { $0.session == next.session }) {
            result.append(next)
            segment = next
        }
        return result
    }

    /// 会話 ID の写し元。記録が無くても、今の会話 ID の transcript の頭が要約の区切りで、巻き戻す前の会話 ID の transcript にその区切りがあれば、
    /// そこを写し元とみなす（写し元を記録する前に、要約の後へ巻き戻した会話）
    func source(of session: String) -> TranscriptSource? {
        if let source = recorded(session) { return source }
        guard session == record.agentSessionId, let previous = record.previousSessionId, previous != session,
            let own = TranscriptTail.locate(session, in: projects), let base = TranscriptTail.locate(previous, in: projects)
        else { return nil }
        return TranscriptSource.find(fork: own, source: previous, at: base)
    }
}
