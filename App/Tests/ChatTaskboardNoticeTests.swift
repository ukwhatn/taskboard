import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// taskboard が人の発言として入れた知らせ（`ChatRowFactory` の知らせの行）。委譲先・リンク・レビュー・利用枠の続きは左の行に畳み、回答は人の吹き出しのまま畳む
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatTaskboardNoticeSnapshotTests {
    nonisolated static let variants: [BoardSnapshotTests.Variant] = BoardSnapshotTests.variants.filter { ["light", "dark"].contains($0.name) }

    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let delegate = ChatMessage(
        id: "u2", role: .user, kind: .text,
        text: "taskboard: 委譲先の会話 221737fa「[295] 線 9 codex の読む画面」（#172）がターンを終えました。最後の返事:\n9-5 が終わりました。取り込んでよいです。\n続きを送るときは session_prompt の conversation_id 221737fa。この知らせは taskboard が送った（人の承認ではない）",
        at: at)
    static let answer = ChatMessage(
        id: "u6", role: .user, kind: .text, text: "taskboard で質問に答えました（#172）。\n「外したいものはありますか」→ 全部入れる", at: at)
    static let messages = [
        ChatMessage(id: "u1", role: .user, kind: .text, text: "線 9 の進みを見ておいて", at: at),
        delegate,
        ChatMessage(id: "u3", role: .user, kind: .text, text: "taskboard: タスク #172 にリンクした PR・issue に動きがありました（GitHub の本文は載せていない。URL を開いて読む）:\n- PR #41 がマージされた", at: at),
        ChatMessage(id: "u4", role: .user, kind: .text, text: "taskboard でレビューしました（#90）。\n総括: よい", at: at),
        ChatMessage(id: "u5", role: .user, kind: .text, text: "利用枠が戻ったので、止まったところから続けてください。", at: at),
        answer,
        ChatMessage(id: "a1", role: .assistant, kind: .text, text: "承知しました。", at: at),
    ]

    @Test("一覧では見出しの 1 行に畳む", arguments: variants.map(\.name))
    func collapsed(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: Self.messages)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 520), variant: variant), named: variant.name)
    }

    @Test("開くと全文（委譲先は枠の中、回答は吹き出しの中）", arguments: variants.map(\.name))
    func expanded(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: [Self.delegate, Self.answer], expandedTools: [Self.delegate.id, Self.answer.id])
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 320), variant: variant), named: variant.name)
    }
}

/// 通知の頭を替えても、画面の見出し（種類の名前と 1 行）は前の版の通知と同じになる
@Suite struct ChatTaskboardNoticeHeadingTests {
    /// （前の版の文, 今の文）。見出しは同じ
    static let pairs: [(old: String, new: String)] = [
        (
            "taskboard: 委譲先の会話 221737fa「線 9 の画面」（#172）がターンを終えました。最後の返事:\n終わりました",
            "[taskboard 通知] 委譲先の会話がターンを終えた\n- 会話: 221737fa「線 9 の画面」（#172）\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n最後の返事:\n終わりました"
        ),
        (
            "taskboard: 委譲先の会話 b3cb353f（#172）が問いを待っています（session_answer で答える）:\n問い r1: 質問",
            "[taskboard 通知] 委譲先の会話が回答を待っている\n- 会話: b3cb353f（#172）\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n回答待ち:\n回答待ち r1: 質問"
        ),
        (
            "taskboard: タスク #172 にリンクした PR・issue に動きがありました（GitHub の本文は載せていない。URL を開いて読む）:\n- PR #41 がマージされた",
            "[taskboard 通知] タスク #172 のリンク先の PR・issue に動きがあった\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n動き:\n- PR #41 がマージされた"
        ),
        (
            "taskboard: 見張り #4（r#12）に動きがありました（GitHub の本文は載せていない。URL を開いて読む）:\n- PR #12 がマージされた",
            "[taskboard 通知] 監視 #4（r#12）に動きがあった\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n動き:\n- PR #12 がマージされた"
        ),
        (
            "taskboard: 予定 #3（10/25（日）09:00）の時刻になったので起こした。仕掛けたときの文:\nデプロイを確かめる\nこの文は wake_create で仕掛けた予定を taskboard が送ったもの（人の発言ではない）",
            "[taskboard 通知] 予定 #3（10/25（日）09:00）の時刻になった\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n作成時の指示:\nデプロイを確かめる"
        ),
    ]

    @Test("前の版と今の形で、通知の種類と見出しの 1 行が同じになる", arguments: pairs.indices)
    func sameHeading(index: Int) throws {
        let pair = Self.pairs[index]
        let old = try #require(TaskboardNotice(text: pair.old))
        let new = try #require(TaskboardNotice(text: pair.new))
        #expect(old == new)
        #expect(old.label == new.label)
        #expect(old.summary(of: pair.old) == new.summary(of: pair.new))
        #expect(new.summary(of: pair.new) != nil)
    }
}
