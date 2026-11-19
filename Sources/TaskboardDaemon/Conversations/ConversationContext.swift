import Foundation
import Logging
import TaskboardKit

/// 会話の actor が engine に依らず使う daemon の部品（`ClaudeConversation.Context`・`CodexConversation.Context` が持ち、欄をそのまま読ませる）
struct ConversationContext: Sendable {
    var machine: MachineID
    var store: Store
    var host: any AgentHostTransport
    /// 確かめた版の CLI と環境。使ってよい版が無ければ投げる
    var launch: @Sendable () async throws -> EngineLaunch
    var attachments: AttachmentStore?
    /// プロセス（thread）を起こしたときに入れる案内（SessionStart の案内と同じ文）
    var guide: @Sendable (_ task: Int) async -> String?
    /// 入力待ち（idle）に入った（回答の配送）
    var becameIdle: @Sendable (_ conversationID: String) async -> Void
    var logger: Logger
    /// CLI の会話 ID の予約。起こす前に取り、プロセスが終わるまで持つ
    var reservations = SessionReservations()
    var timing = ConversationTiming()
    var now: @Sendable () -> Date = { Date() }
    /// daemon の起動ごとの印（`DaemonState.epoch`）。seq は起動ごとに 1 から数え直すので、購読の続きはこれが同じときだけ送る
    var epoch = ""
    /// 会話の様子が変わった（`DaemonState` に載せる。呼んだ順に載る）
    var publish: @Sendable (Conversation) -> Void = { _ in }
    /// 会話（id）が使っているツールが変わった（`DaemonState` に載せる。`publish` と同じ列で順に載る）
    var publishTool: @Sendable (_ conversationID: String, _ toolName: String?) -> Void = { _, _ in }
    /// 同時に動かす会話の枠（`ConversationService` と共有）
    var slots = ConversationSlots(soft: .max, hard: .max)
    /// 目安の上限を超えて起こした：使っていない会話を 1 つ止める
    var makeRoom: @Sendable (_ except: String) async -> Void = { _ in }
    /// 作業フォルダの差分の要約（`ConversationDiff`）。取れなければ nil（前の要約を残す）
    var diff: @Sendable (_ cwd: String) async -> ConversationDiffSummary? = { _ in nil }
    /// 起こした側への知らせが残った（ターンの終わり・問いを待ち始めた。`ConversationNotices`）
    var noticeChanged: @Sendable (_ conversationID: String) async -> Void = { _ in }
}
