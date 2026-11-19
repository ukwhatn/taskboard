import Foundation
import TaskboardKit

/// 会話の actor が記録に書くもののうち、engine に依らない分（起こした側への知らせ・taskboard が送る続きの待ち・記録の読み直し）
protocol ConversationRecordKeeping: Actor {
    nonisolated var id: String { get }
    var record: ConversationRecord { get set }
    var recordStore: Store { get }
    func currentDate() -> Date
    /// 会話の様子を `DaemonState` と購読に流す
    func publishState()
    /// 起こした側への知らせが残った（`ConversationNotices`）
    var noticeChangedHandler: @Sendable (_ conversationID: String) async -> Void { get }
}

extension ConversationRecord {
    /// 新しい子を起こす前の記録。host の行の番号は同じ key の子をまたいで続くが、host が起き直すと 1 から振り直す。
    /// 記録に残した番号（控えを捨てた所・数えた最後のターンの終わり）を、今の host で読んだ所 `through` に揃える（前の host の番号のままだと、新しい子のターンの終わりをその番号を超えるまで数えない）
    mutating func startProcess(through: Int) {
        runner = Conversation.Runner.host.rawValue
        lastExit = nil
        trimmedThrough = through
        parentNoticeSeq = through
    }
}

extension ConversationRecordKeeping {
    /// 記録を書き換える。書けなければ前の記録のまま
    func updateRecord(_ change: (inout ConversationRecord) -> Void) {
        try? writeRecord(change)
    }

    /// 記録を書き換える。書けなければ前の記録のまま投げる
    func writeRecord(_ change: (inout ConversationRecord) -> Void) throws {
        record = try recordStore.updateConversation(id: id, at: currentDate(), change)
    }

    /// 起こした側への知らせを入れるか切るか。切ると残っている知らせも消す
    func setNotifyParent(_ request: ConversationControlRequest) throws -> ConversationControlResponse {
        let notify: Bool
        switch request.value {
        case "on", "true": notify = true
        case "off", "false": notify = false
        default: throw ConversationError.invalid("set_notify_parent は on・off")
        }
        if notify, record.parentConversationId == nil { throw ConversationError.invalid("知らせる先（parent）が無い") }
        try writeRecord {
            $0.notifyParent = notify
            if !notify {
                $0.parentNoticeTurns = 0
                $0.parentNoticeAt = nil
            }
        }
        publishState()
        return ConversationControlResponse(payloadJSON: nil)
    }

    /// 起こした側への知らせを残す。`turn` はターンの終わりの行の seq（問いを待ち始めたときは nil で、数は増やさない）
    func leaveNotice(turn seq: Int?) {
        guard record.notifyParent else { return }
        let at = nextNoticeAt()
        updateRecord {
            if let seq {
                $0.parentNoticeTurns += 1
                $0.parentNoticeSeq = seq
            }
            $0.parentNoticeAt = at
        }
        publishState()
        let changed = noticeChangedHandler
        let id = id
        Task { await changed(id) }
    }

    /// 知らせを届けた：その後に別の知らせが残っていなければ（時刻が同じなら）消す
    func noticeDelivered(at: Date) {
        guard record.parentNoticeAt == at else { return }
        updateRecord {
            $0.parentNoticeTurns = 0
            $0.parentNoticeAt = nil
        }
        publishState()
    }

    /// 知らせが待ち行列で取り消された：時刻を進めて別の uuid で届け直す
    func noticeCancelled(at: Date) {
        guard record.parentNoticeAt == at else { return }
        let next = nextNoticeAt()
        updateRecord { $0.parentNoticeAt = next }
        publishState()
    }

    /// 知らせの時刻は届けた印と uuid の元なので、残っている時刻より必ず後にする（同じミリ秒に 2 つ残すと、1 つ目を届けた印で 2 つ目まで消える）
    private func nextNoticeAt() -> Date {
        let now = Store.storedDate(currentDate())
        guard let previous = record.parentNoticeAt, now <= previous else { return now }
        return Store.storedDate(Date(timeIntervalSince1970: ((previous.timeIntervalSince1970 * 1000).rounded() + 1) / 1000))
    }

    /// taskboard が送る続き（利用枠の上限の後・ネットワークが戻った後）を取り消す。人や agent が送った・止めた・取り消した
    func clearResumeWaits() {
        guard record.limitResumeAt != nil || record.networkResumeAt != nil || record.networkResumeTries > 0 else { return }
        updateRecord {
            $0.limitResumeAt = nil
            $0.limitPaused = false
            $0.networkResumeAt = nil
            $0.networkResumeTries = 0
        }
        publishState()
    }

    /// 起こした側を替える（破棄して再起動）。記録は `Store.reparentConversations` が書いた
    func reloadRecord() {
        guard let current = try? recordStore.conversation(id: id) else { return }
        record = current
        publishState()
    }
}

/// host の子の様子
enum ConversationChild: Equatable, Sendable {
    /// 起こしていない・引き取っていない（daemon が起きた直後・起こし直す前）
    case none
    /// 動いている。`acceptsInput` が false なら、入力を閉じると決めた（止める・続けられない・巻き戻しなどの操作の前）
    case running(acceptsInput: Bool)
    /// 子が終わったのを控えの行で見た
    case exited

    var isRunning: Bool { if case .running = self { true } else { false } }
    var acceptsInput: Bool { self == .running(acceptsInput: true) }
}
