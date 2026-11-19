import Foundation
import TaskboardKit

/// 会話の画面の通知の行に出す文（`ConversationEvent.Kind.notice`）。UICopyTests が読む。チャットの通知の行（「中断しました」）と同じく句点なしの 1 文で、内側の理由は出さない
enum ConversationScreenText {
    /// 端末（TUI）で開く起動が後から失敗した（理由は daemon の文なので出さず、ログと起動の記録に残す）
    static let compactFailed = "会話を圧縮できませんでした"
    /// 会話の区切りの行。`tokens` は圧縮の前と後のトークン数
    static func compacted(automatic: Bool, tokens: (before: Int, after: Int)?) -> String {
        let head = automatic ? "会話を自動で圧縮しました" : "会話を圧縮しました"
        guard let tokens else { return head }
        return "\(head)（\(count(tokens.before))→\(count(tokens.after))トークン）"
    }

    private static func count(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "ja_JP"))) }
    static let restartedUnresponsive = "応答がなかったため、Claude Codeを再起動しました"
    static let restartedForBypass = "確認なしに切り替えるため、Claude Codeを再起動しました"
    static let promptDropped = "Claude Codeが時間内に受け付けなかったため、メッセージを送信できませんでした"
    static let promptDiscarded = "Claude Codeが終了する途中だったため、メッセージを送信できませんでした"
    static let promptRefused = "Claude Codeが受け付けなかったため、メッセージを送信できませんでした"
    static let refusedRequest = "アプリが対応していない種類の質問を断りました"
    static let steerAfterCompaction = "圧縮中のため、圧縮が終わってから送信します"
    static let steerAfterReview = "レビュー中のため、レビューが終わってから送信します"
    /// 会話で使えない組み込みのコマンド。前にコマンド名を付ける（`TranscriptParser`）。端末で使えることは入力欄の上の案内が伝える
    static let commandUnavailable = "会話では使えません。"
}

extension ConversationStopCause {
    func notice(engine: AgentKind) -> String {
        switch self {
        case .person, .taskboard, .suspended: "停止しました"
        case .closed: "終了しました"
        case .idle: "しばらく使われていないため停止しました"
        case .finished: "定期起動の実行が終わったため停止しました"
        case .deferred: "質問に答えると再開します"
        case .hostRestarted, .hostMissing, .startFailed, .unexpected: "\(engine.label)が終了しました"
        }
    }
}
