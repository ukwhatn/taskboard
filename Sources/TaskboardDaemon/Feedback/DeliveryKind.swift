import Foundation

/// 届けるものの種類と、届け先が止まっているときの扱い（1 つの表）。届け先は頼んだ会話か、タスクの lead（`TaskDeliveryTarget`）
enum DeliveryKind: Hashable, Sendable {
    /// 質問の回答・レビュー（人が答えた）
    case feedback
    /// 委譲先の会話の知らせ（起こした側へ）
    case delegateNotice
    /// リンクした PR・issue の知らせ。`actionable` は対応が要る知らせ（`LinkNotice.needsAction`）を含むか
    case linkNotice(actionable: Bool)
    /// 利用枠の上限の後の続き（会話そのものへ）
    case limitResume
    /// 決めた時刻に起こす予定（`WakeService`）。起こすために仕掛けたので、人が止めた・終了した会話も起こす
    case wake
    /// 見張った issue・PR の出来事（`WatchNotices`）。起こすために仕掛けたので、人が止めた・終了した会話も起こす
    case watch

    /// 止まった会話を起こすか。人が止めた会話を起こさないものは、人が戻すまで残す
    var wake: ConversationWakePolicy {
        switch self {
        case .feedback, .limitResume, .wake, .watch: .always
        case .delegateNotice: .unlessStoppedByPerson
        case .linkNotice(let actionable): actionable ? .unlessStoppedByPerson : .never
        }
    }

    /// 止まった TUI の lead を会話で戻して届けるか（`ConversationService.resumeStoppedLead`）。戻さないものは、次に動いたときに渡す
    var resumesStoppedTerminal: Bool {
        switch self {
        case .feedback, .wake, .watch: true
        case .linkNotice(let actionable): actionable
        case .delegateNotice, .limitResume: false
        }
    }
}
