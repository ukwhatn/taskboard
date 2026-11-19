// ui-copy:ignore-file
// このファイルの文（記録の lastExit）は、CLI・MCP の「終わり」とログに出て、画面には出ない。会話の画面の文は daemon が理由から組む（ConversationStopCause.notice）
import Foundation

/// 会話のプロセスが終わった理由。記録の `Conversation.lastExit` の文と 1 対 1 で、決まった文はそのまま、
/// 終了コード・signal のような動く文は `unexpected` に入る。文を言い換えると前の記録の読み方が変わるので、文は変えない
public enum ConversationStopCause: Hashable, Sendable {
    /// 人か agent が止めた（アプリ・MCP・CLI の停止）。画面で開いても、委譲先やリンクの知らせが来ても起こさない
    case person
    /// 人か lead が終了した（用済み）。記録は残し、画面の一覧から外す。画面で開いても知らせが来ても起こさず、送るか再開すると戻る
    case closed
    /// taskboard が止めた（起こした側の終了・常駐を切った・破棄して再起動・定期起動の回の後始末・版の確かめ）
    case taskboard
    /// 巻き戻し・元に戻す・端末で開くために止めた
    case suspended
    case idle
    case deferred
    case finished
    case hostRestarted
    case hostMissing
    case startFailed
    case unexpected(String)

    private static let texts: [(ConversationStopCause, String)] = [
        (.person, "止めた"),
        (.closed, "終了した"),
        (.taskboard, "taskboard が止めた"),
        (.suspended, "操作のために止めた"),
        (.idle, "使われていないので止めた"),
        (.deferred, "質問を defer で終えた"),
        (.finished, "定期起動の回が終わったので止めた"),
        (.hostRestarted, "agent host が起き直した"),
        (.hostMissing, "agent host に無い"),
        (.startFailed, "起こせなかった"),
    ]

    public init(lastExit: String) {
        self = Self.texts.first { $0.1 == lastExit }?.0 ?? .unexpected(lastExit)
    }

    /// 人が戻すまで起こさない（画面で開いたとき・委譲先やリンクの知らせ）
    public var keepsStopped: Bool { self == .person || self == .closed }

    /// 記録に書く文（CLI・MCP の「終わり」に出る）
    public var lastExit: String {
        if case .unexpected(let text) = self { return text }
        return Self.texts.first { $0.0 == self }!.1
    }
}

extension Conversation {
    /// 最後に始めたターンに応答が付く前に止まったか。予期しない終わりのうち、入力待ちの間の終わり（外からの kill など）は失ったものが無く、送れば起きるので異常にしない。
    /// 応答の文を書かずに終えたターンも途中として数える（記録から区別できない）
    public var stoppedInTurn: Bool {
        guard let started = turnStartedAt else { return false }
        guard let reply = lastReply else { return true }
        return reply.at < started
    }

    /// 止めると作業の途中で止まるか（生成中・問いの答えを待っている・起こしている途中）
    public var interruptedByStop: Bool { phase == .running || phase == .waiting || phase == .starting }

    /// 終了した（人か lead の終了と、定期起動の回の終わり）。画面の一覧と session_list に出さない
    public var isClosed: Bool {
        guard phase == .stopped, let lastExit else { return false }
        let cause = ConversationStopCause(lastExit: lastExit)
        return cause == .closed || cause == .finished
    }
}
