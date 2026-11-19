import TaskboardKit
import Testing
@testable import Taskboard

/// 設定の書き込みを断られたときの文（`ConversationSettingsText.failure`）
@Suite struct ConversationSettingsTextTests {
    private func rejected(_ reason: String?) -> SessionSourceError {
        .rejected(DaemonRejection(status: 409, message: "Rule already exists", code: .sessionCommandFailed, params: reason.map { ["reason": $0] } ?? [:]))
    }

    @Test("理由の種類から原因と対処を組み、daemon の英語の文は出さない")
    func reasons() {
        #expect(ConversationSettingsText.failure("規則を追加できませんでした", rejected("duplicate"))?.text == "規則を追加できませんでした。同じものがすでにあります。")
        #expect(
            ConversationSettingsText.failure("フックを削除できませんでした", rejected("not_found"))?.text
                == "フックを削除できませんでした。対象が見つかりません。再読み込みしてから、やり直してください。")
        #expect(ConversationSettingsText.failure("規則を追加できませんでした", rejected("locked"))?.text == "規則を追加できませんでした。組織の設定で固定されています。")
        #expect(
            ConversationSettingsText.failure("フックを保存できませんでした", rejected("conflict"))?.text
                == "フックを保存できませんでした。設定のファイルがほかで書き換えられています。再読み込みしてから、やり直してください。")
        let other = ConversationSettingsText.failure("規則を追加できませんでした", rejected("other"))?.text
        #expect(other?.contains("Rule already exists") == false)
    }

    @Test("Codex が書き換えを断るのは、ユーザーの config.toml にないもの")
    func codexLocked() {
        #expect(
            ConversationSettingsText.failure("フックを削除できませんでした", rejected("locked"), engine: .codex)?.text
                == "フックを削除できませんでした。ユーザーの設定（config.toml）にないものは変更できません。")
    }

    @Test("書いた値が効かないときと、会話を再開すると効くときは、保存した後に知らせる")
    func notices() {
        #expect(
            ConversationSettingsText.notice(ConversationSettingsEditResult(overriddenBy: "permission_mode"))
                == "設定を保存しました。アプリの会話では会話の権限のモードが優先されるため、この値は効きません。ターミナルで起動したCodexには効きます。")
        #expect(
            ConversationSettingsText.notice(ConversationSettingsEditResult(needsRestart: true, overriddenBy: "system"))
                == "設定を保存しました。Mac全体の設定で上書きされているため、この会話には効きません。")
        #expect(ConversationSettingsText.notice(ConversationSettingsEditResult(needsRestart: true)) == "設定を保存しました。この会話には、会話を終了して再開すると効きます。")
        #expect(ConversationSettingsText.notice(ConversationSettingsEditResult()) == nil)
    }

    @Test("理由の無い断りと接続の失敗は、ふつうの失敗の文にする")
    func fallsBack() {
        #expect(ConversationSettingsText.failure("規則を追加できませんでした", rejected(nil))?.text == "規則を追加できませんでした。接続先のMacでセッションを操作できません。時間をおいて、やり直してください。")
        #expect(ConversationSettingsText.failure("規則を追加できませんでした", CancellationError()) == nil)
    }
}
