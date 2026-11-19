import Foundation

/// daemon が要求を断るときに付ける理由の種類。画面の文はアプリがこれと `params` から組む（docs/ui-copy.md「エラー」）。
/// 一緒に返す `message` は、エージェント（MCP）とログのための文で、画面には出さない
public enum DaemonErrorCode: String, Codable, Sendable, Hashable, CaseIterable {
    /// 対象が無い。params: `kind`（`Kind`）
    case notFound = "not_found"
    /// 質問がもう回答待ちでない
    case askNotOpen = "ask_not_open"
    /// 未回答の質問が残っている。params: `count`
    case askUnanswered = "ask_unanswered"
    /// 送信済みのコメントは変えられない
    case commentNotDraft = "comment_not_draft"
    /// 下書きのコメントは解決にできない
    case commentIsDraft = "comment_is_draft"
    /// 同じ名前の文書が別の形式である。params: `name`
    case docFormatMismatch = "doc_format_mismatch"
    /// 案件がアーカイブされている。params: `name`
    case boardArchived = "board_archived"
    /// 最後の案件はアーカイブも削除もできない
    case boardLast = "board_last"
    /// 案件にタスクが残っている。params: `name`、`count`
    case boardHasTasks = "board_has_tasks"
    /// 案件の名前が空
    case boardNameEmpty = "board_name_empty"
    /// 同じ名前の案件がある。params: `name`
    case boardNameTaken = "board_name_taken"
    /// 列の名前が空
    case columnLabelEmpty = "column_label_empty"
    /// 列の名前が重なっている。params: `label`
    case columnLabelDuplicate = "column_label_duplicate"
    /// 既定の列の完了扱いの変更と、「完了」の削除はできない。params: `label`、`change`（`kind` か `remove`。古い daemon は付けない）
    case defaultColumnLocked = "default_column_locked"
    /// 進行中の列が 1 つも無くなる
    case noOpenColumn = "no_open_column"
    /// 削除する列にタスクが残っている。params: `label`、`count`
    case columnHasTasks = "column_has_tasks"
    /// 定期起動の名前が空
    case scheduleNameEmpty = "schedule_name_empty"
    /// cron 式を読めない
    case cronInvalid = "cron_invalid"
    /// 間隔が短すぎる。params: `minimum`（分）
    case intervalTooShort = "interval_too_short"
    /// 同じ時刻の実行が既にある
    case scheduleRunExists = "schedule_run_exists"
    /// 文が長すぎる。params: `limit`（文字数）
    case textTooLong = "text_too_long"
    /// オーケストレーターは既に動いている
    case orchestratorRunning = "orchestrator_running"
    /// オーケストレーターがいない
    case orchestratorMissing = "orchestrator_missing"
    /// オーケストレーターを起動している途中
    case orchestratorStarting = "orchestrator_starting"
    /// 常駐がオンのオーケストレーターは止められない
    case orchestratorResident = "orchestrator_resident"
    /// セッションは既に動いている
    case sessionRunning = "session_running"
    /// ペアリングのコードが違うか、期限が切れているか、使用済み
    case pairingCodeInvalid = "pairing_code_invalid"
    /// ペアリングの失敗が続いたので、しばらく受け付けない。params: `seconds`
    case pairingTooManyFailures = "pairing_too_many_failures"
    /// GitHub から PR を取得できなかった（gh の失敗を含む）
    case githubFailed = "github_failed"
    /// iPhone・iPad の登録ではできない操作（端末の追加・登録の解除）
    case deviceNotAllowed = "device_not_allowed"
    /// セッションの操作（作成・入力・読み取り）に失敗した
    case sessionCommandFailed = "session_command_failed"
    /// セッションが応答待ちでない（通知から応答したときに、もう答えてあったなど）
    case notWaiting = "not_waiting"
    /// 画像が大きすぎる。params: `limit`（MB）
    case attachmentTooLarge = "attachment_too_large"
    /// 送れない形式の画像（png・jpeg・gif・webp だけ）
    case attachmentUnsupported = "attachment_unsupported"
    /// 送信に載せた画像が daemon に無い（日数で消えた、別のマシンに置いた）
    case attachmentMissing = "attachment_missing"
    /// セッションが AskUserQuestion の答えを待っている（文を送ると、カーソルの選択肢が選ばれてしまう）
    case questionPending = "question_pending"
    /// その Mac で動かせる会話（agent host のセッション）の数が上限に達している。params: `limit`
    case conversationLimit = "conversation_limit"
    /// 確かめた Claude Code の版が無いので、会話を起動しない（`taskboard conversation check` で確かめる）
    case claudeUnverified = "claude_unverified"
    /// 確かめた codex の版が無いので、codex の会話を起動しない（`taskboard conversation check --engine codex` で確かめる）
    case codexUnverified = "codex_unverified"
    /// 接続先の codex の版が古く、その操作に要る口が無い（コネクタの認証の `loginId` など）。codex を更新する
    case codexOutdated = "codex_outdated"
    /// 会話が止まっていて送れない
    case conversationStopped = "conversation_stopped"
    /// 会話が動いているので消せない（止めてから消す）
    case conversationRunning = "conversation_running"
    /// 会話が生成中・問いを待っている・裏のタスクがある・ほかの操作の途中なので、その操作はできない
    case conversationBusy = "conversation_busy"
    /// 画面を開いた後に会話が替わった（巻き戻し・元に戻す・`/clear`）。開き直してからやり直す
    case conversationChanged = "conversation_changed"
    /// フォーク・巻き戻しの後、まだ発言を送っていない（先に 1 回送る）
    case conversationNotSent = "conversation_not_sent"
    /// 会話で同時に動かせる Run の数が上限に達している。params: `limit`
    case runLimit = "run_limit"
    /// その engine の会話ではできない操作（Codex の巻き戻し・コネクタの操作など）。params: `engine`（`AgentKind`）
    case engineUnsupported = "engine_unsupported"
    /// daemon のその機能が動いていない
    case unavailable
    /// 要求の形が違う（アプリの誤り。アプリが先に入力を確かめる）
    case invalidRequest = "invalid_request"
    /// daemon の中の誤り
    case internalError = "internal_error"

    /// `notFound` の対象
    public enum Kind: String, Sendable {
        case board, column, task, workItem, document, ask, comment, revision, schedule, device, session, launch, claim, pullRequest, conversation
        /// 起こす予定（`wake_create`）
        case wake
        /// GitHub の issue・PR の見張り（`watch_create`）
        case watch
        /// 会話の発言（フォーク・巻き戻しの地点）
        case message
        /// チャットのファイルの札の中身（`GET /v1/chat/{pane_id}/files/{tool_id}`）
        case file
        /// 会話のコードブロックの Run（daemon が起き直すと無くなる）
        case run
    }
}

/// daemon が断った要求。`code` の無い応答（古い daemon）は `code` が nil
public struct DaemonRejection: Error, Sendable, Hashable {
    public var status: Int
    public var message: String
    public var code: DaemonErrorCode?
    public var params: [String: String]

    public init(status: Int, message: String, code: DaemonErrorCode? = nil, params: [String: String] = [:]) {
        self.status = status
        self.message = message
        self.code = code
        self.params = params
    }

    /// 失敗の応答の本文（`{"error":{"message","code","params"}}`）
    public struct Body: Codable, Sendable {
        public struct Inner: Codable, Sendable {
            public var message: String
            public var code: String?
            public var params: [String: String]?
        }
        public var error: Inner

        public init(message: String, code: DaemonErrorCode?, params: [String: String]) {
            error = Inner(message: message, code: code?.rawValue, params: params.isEmpty ? nil : params)
        }
    }
}
