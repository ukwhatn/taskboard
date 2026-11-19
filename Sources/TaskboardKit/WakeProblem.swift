// ui-copy:ignore-file
// このファイルの文（記録の failure）は、MCP の wake_list・health とログに出て、画面には出ない。画面の文はアプリが理由から組む（WakeRow.note）
import Foundation

/// 再開の予定が届かなかった理由。記録の `Wake.failure` の文と 1 対 1 で、決まった文はそのまま、前の版の文や知らない文は `unexpected` に入る。
/// 文を言い換えると前の記録の読み方が変わるので、文は変えない
public indirect enum WakeProblem: Hashable, Sendable {
    /// 届け先の会話の記録が無い（失敗にする）
    case conversationMissing
    /// 届け先のタスクが無い（失敗にする）
    case taskMissing
    case busy
    case unconfirmed
    case resumeFailed
    case paneNotReady
    case resuming
    case startFailed
    /// daemon がターミナルで起動できない（launcher が無い）
    case terminalUnavailable
    case terminalFailed
    /// 最初の回から 24 時間届けられなかったので失敗にした。中身は最後の回の理由
    case gaveUp(WakeProblem)
    case unexpected(String)

    private static let texts: [(WakeProblem, String)] = [
        (.conversationMissing, "会話の記録がありません"),
        (.taskMissing, "タスクがありません"),
        (.busy, "会話が生成中か、質問への回答を待っています"),
        (.unconfirmed, "届いたかを確認できませんでした"),
        (.resumeFailed, "会話を再開できませんでした"),
        (.paneNotReady, "タスクのセッションが応答待ちではありません"),
        (.resuming, "停止したセッションを再開しています"),
        (.startFailed, "会話を起動できませんでした"),
        (.terminalUnavailable, "ターミナルで起動できません"),
        (.terminalFailed, "ターミナルで起動できませんでした"),
    ]
    private static let gaveUpPrefix = "24時間届けられませんでした。"

    public init(failure: String) {
        if failure.hasPrefix(Self.gaveUpPrefix), failure.count > Self.gaveUpPrefix.count, failure.hasSuffix("。") {
            self = .gaveUp(WakeProblem(failure: String(failure.dropFirst(Self.gaveUpPrefix.count).dropLast())))
        } else {
            self = Self.texts.first { $0.1 == failure }?.0 ?? .unexpected(failure)
        }
    }

    /// 記録に書く文（MCP の wake_list・health に出る）
    public var failure: String {
        switch self {
        case .gaveUp(let last): return Self.gaveUpPrefix + last.failure + "。"
        case .unexpected(let text): return text
        default: return Self.texts.first { $0.0 == self }!.1
        }
    }
}

extension Wake {
    /// 届かなかった理由（試し直しているか失敗したとき）
    public var problem: WakeProblem? { failure.map(WakeProblem.init(failure:)) }
}
