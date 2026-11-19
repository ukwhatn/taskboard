import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 人の発言の見分け。Stop hook のターンの始まり（`TranscriptTurn`）・フォークと巻き戻しの地点（`TranscriptLines`）・
/// 履歴の差し込みの印（`TranscriptParser`）が、同じ行を同じに見分ける。行の形は Claude Code 2.1.3xx の transcript の実物から取った
@Suite("人の発言の見分け")
struct HumanPromptTests {
    private static func user(_ content: Any, _ extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "uuid": "u", "timestamp": "2026-10-20T00:00:00.000Z", "message": ["role": "user", "content": content]].merging(extra) { $1 }
    }

    /// （名前、行、人の発言の本文）
    static var cases: [(String, [String: Any], String?)] { [
        ("端末で打った文", user("直して", ["origin": ["kind": "human"]]), "直して"),
        ("mod が人の代わりに入れた文（チャットの送信・回答）", user("回答です", ["origin": ["kind": "plugin"]]), "回答です"),
        ("origin の無い文（stream-json の会話）", user("はじめ"), "はじめ"),
        ("画像と文", user([["type": "text", "text": "見て"], ["type": "image", "source": [:]]], ["origin": ["kind": "human"]]), "見て"),
        ("コマンド", user("<command-name>/model</command-name><command-args>opus</command-args>", ["origin": ["kind": "human"]]), "/model opus"),
        ("裏の作業の知らせ", user("<task-notification><summary>終わった</summary></task-notification>", ["origin": ["kind": "task-notification"]]), nil),
        ("ほかのセッションからの文", user("Another Claude session sent a message", ["origin": ["kind": "peer"], "isMeta": true]), nil),
        ("利用枠が戻った続き", user("Your usage limit has reset", ["origin": ["kind": "auto-continuation"], "isMeta": true]), nil),
        ("知らない origin", user("何か", ["origin": ["kind": "future"]]), nil),
        ("meta（スキルの本文）", user([["type": "text", "text": "Base directory for this skill"]], ["isMeta": true]), nil),
        ("stream-json の差し込み", user("差し込み", ["isSynthetic": true]), nil),
        ("圧縮の要約", user("This session is being continued", ["isCompactSummary": true]), nil),
        ("サブエージェントの行", user("調べて", ["isSidechain": true]), nil),
        ("中断の印", user([["type": "text", "text": "[Request interrupted by user]"]]), nil),
        ("system-reminder だけ", user("<system-reminder>x</system-reminder>", ["origin": ["kind": "human"]]), nil),
        ("ツールの結果", user([["type": "tool_result", "tool_use_id": "t", "content": "ok"]]), nil),
    ] }

    @Test("1 つの規則で見分ける", arguments: 0..<16)
    func sameRule(_ index: Int) throws {
        let (name, object, expected) = Self.cases[index]
        #expect(TranscriptParser.humanPrompt(object) == expected, "\(name)")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect((TranscriptTurn.parse([data]) != nil) == (expected != nil), "Stop hook のターンの始まり: \(name)")
        #expect(TranscriptLines.parse(data, start: 0, end: 0)?.prompt == expected, "フォークの地点: \(name)")
        // 履歴: 人の発言は印の無い文、人でない文は差し込みの印付き（巻き戻しの地点にならない）
        if object["isSidechain"] == nil, case .messages(let messages) = TranscriptParser.parse(object: object, index: 0) {
            for message in messages where message.kind == .text {
                #expect(message.isRewindTarget == (expected != nil), "履歴: \(name)")
            }
        }
    }
}
