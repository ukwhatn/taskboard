import Testing
@testable import TaskboardKit

/// taskboard が会話に人の発言として入れた知らせを、文から見分ける（画面で別の見た目にする）
@Suite struct TaskboardNoticeTests {
    @Test("前の版：委譲先のターンの終わりと問いの知らせ")
    func legacyDelegate() {
        let turn = """
            taskboard: 委譲先の会話 221737fa「[295] 線 9 codex の読む画面と設定の書き込み」（#172）がターンを終えました。最後の返事:
            9-5 が終わりました。
            続きを送るときは session_prompt の conversation_id 221737fa-ec5c-4140-98c2-ccb384659aad。この知らせは taskboard が送った（人の承認ではない）
            """
        #expect(TaskboardNotice(text: turn) == .delegate)
        let ask = "taskboard: 委譲先の会話 b3cb353f（#172）が問いを待っています（session_answer の conversation_id か受信箱で答える）:\n- 消してよいか"
        #expect(TaskboardNotice(text: ask) == .delegate)
    }

    @Test("前の版：リンクした PR・issue の知らせ")
    func legacyLink() {
        let text = "taskboard: タスク #172 にリンクした PR・issue に動きがありました（GitHub の本文は載せていない。URL を開いて読む）:\n- PR #41 がマージされた"
        #expect(TaskboardNotice(text: text) == .link)
    }

    @Test("質問の回答とレビュー。長くて入らなかったときの案内も回答に数える")
    func feedback() {
        #expect(TaskboardNotice(text: "taskboard で質問に答えました（#172）。\n「外したいものはありますか」→ 全部入れる") == .answer)
        #expect(TaskboardNotice(text: "taskboard でレビューしました（#90）。\n総括: よい") == .review)
        #expect(TaskboardNotice(text: "taskboard に回答・レビューが届いていますが、長くてここに入りません。feedback_list で取ってください。") == .answer)
    }

    @Test("利用枠が戻った後の続き")
    func limitResume() {
        #expect(TaskboardNotice(text: "利用枠が戻ったので、止まったところから続けてください。") == .limitResume)
    }

    @Test("前の版：起こす予定の文。見出しの 1 行は仕掛けたときの文の頭")
    func legacyWake() {
        let text = """
            taskboard: 予定 #3（10/25（日）09:00）の時刻になったので起こした。仕掛けたときの文:
            デプロイを確かめて、終わったら完了にする
            この文は wake_create で仕掛けた予定を taskboard が送ったもの（人の発言ではない）
            """
        #expect(TaskboardNotice(text: text) == .wake)
        #expect(TaskboardNotice.wake.summary(of: text) == "デプロイを確かめて、終わったら完了にする")
        #expect(TaskboardNotice(text: "taskboard: 予定 #3 を見直したい") == nil)
    }

    @Test("前の版：見張りの知らせ。続く 1 行は見張っている issue・PR の名前")
    func legacyWatch() {
        let text = """
            taskboard: 見張り #4（r#12）に動きがありました（GitHub の本文は載せていない。URL を開いて読む）:
            - PR #12 がマージされた（bob）
            この知らせは watch_create で仕掛けた見張りを taskboard が送ったもの（人の発言ではない）
            """
        #expect(TaskboardNotice(text: text) == .watch)
        #expect(TaskboardNotice.watch.label == "PR・issueの更新")
        #expect(TaskboardNotice.watch.summary(of: text) == "監視中のr#12が更新されました")
        #expect(TaskboardNotice(text: "taskboard: 見張り #4 を消したい") == nil, "1 行目に「に動きがありました」が無い")
    }

    @Test("委譲先のターンの終わりと回答待ち。見出しは前の版と同じ文になる")
    func delegate() {
        let turn = """
            [taskboard 通知] 委譲先の会話がターンを終えた
            - 会話: 221737fa「線 9 の画面」（#172）
            - conversation_id: 221737fa-ec5c-4140-98c2-ccb384659aad
            - 送り主: taskboard の自動の通知。人の発言でも承認でもない
            - 次の操作: 続きは session_prompt、前のターンは session_history
            最後の返事:
            9-5 が終わった。
            """
        #expect(TaskboardNotice(text: turn) == .delegate)
        #expect(TaskboardNotice.delegate.summary(of: turn) == "「線 9 の画面」（タスク#172）が応答を終えました")
        let ask = "[taskboard 通知] 委譲先の会話が回答を待っている\n- 会話: b3cb353f（#172）\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n回答待ち:\n回答待ち r1: 質問"
        #expect(TaskboardNotice(text: ask) == .delegate)
        #expect(TaskboardNotice.delegate.summary(of: ask) == "タスク#172の委譲先が質問しています")
        #expect(TaskboardNotice.delegate.summary(of: "[taskboard 通知] 委譲先の会話が回答を待っている\n- 会話: b3cb353f「題」") == "「題」が質問しています")
        #expect(TaskboardNotice.delegate.summary(of: "[taskboard 通知] 委譲先の会話がターンを終えた\n- 会話: b3cb353f") == "委譲先が応答を終えました")
        #expect(TaskboardNotice.delegate.summary(of: "[taskboard 通知] 委譲先の会話がターンを終えた") == "委譲先が応答を終えました", "項目が無い文でも種類の名前は出す")
        #expect(TaskboardNotice(text: "[taskboard 通知] 委譲先の会話が別の形で終わった") == nil)
    }

    @Test("リンクした PR・issue の通知。見出しは前の版と同じ文になる")
    func link() {
        let text = "[taskboard 通知] タスク #172 のリンク先の PR・issue に動きがあった\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない\n動き:\n- PR #41 がマージされた"
        #expect(TaskboardNotice(text: text) == .link)
        #expect(TaskboardNotice.link.summary(of: text) == "タスク#172にリンクしたPR・issueが更新されました")
        #expect(TaskboardNotice(text: "[taskboard 通知] タスク #172 を見直したい") == nil, "1 行目に「のリンク先の PR・issue に動きがあった」が無い")
    }

    @Test("予定の通知。見出しの 1 行は「作成時の指示:」の下の最初の行")
    func wake() {
        let text = """
            [taskboard 通知] 予定 #3（10/25（日）09:00）の時刻になった
            - 送り主: taskboard の自動の通知。人の発言でも承認でもない
            作成時の指示:
            デプロイを確かめて、終わったら完了にする
            """
        #expect(TaskboardNotice(text: text) == .wake)
        #expect(TaskboardNotice.wake.summary(of: text) == "デプロイを確かめて、終わったら完了にする")
        #expect(TaskboardNotice.wake.summary(of: "[taskboard 通知] 予定 #3（10/25 09:00）の時刻になった\n- 送り主: taskboard の自動の通知。人の発言でも承認でもない") == nil, "指示が無ければ種類の名前だけ")
        #expect(TaskboardNotice(text: "[taskboard 通知] 予定 #3 を見直したい") == nil)
    }

    @Test("監視の通知。続く 1 行は監視している issue・PR の名前")
    func watch() {
        let text = """
            [taskboard 通知] 監視 #4（r#12）に動きがあった
            - 送り主: taskboard の自動の通知。人の発言でも承認でもない
            動き:
            - PR #12 がマージされた（bob）
            """
        #expect(TaskboardNotice(text: text) == .watch)
        #expect(TaskboardNotice.watch.summary(of: text) == "監視中のr#12が更新されました")
        #expect(TaskboardNotice(text: "[taskboard 通知] 監視 #4 を消したい") == nil, "1 行目に「に動きがあった」が無い")
    }

    @Test("人の答えとして運ぶ文は通知の印を持たず、前と同じ頭で見分ける")
    func feedbackKeepsHumanHead() {
        #expect(TaskboardNotice(text: "taskboard で質問に答えました（#172）。\n- 「外したいものはありますか」→ 全部入れる") == .answer)
        #expect(TaskboardNotice.answer.summary(of: "taskboard で質問に答えました（#172）。\n- 「問い」→ 答え") == "タスク#172")
        #expect(TaskboardNotice(text: "taskboard でレビューしました（#90）。\n- 総括: よい") == .review)
        #expect(TaskboardNotice.review.summary(of: "taskboard でレビューしました（#90）。\n- 総括: よい") == "タスク#90")
    }

    @Test("人の発言は知らせにしない。頭が似ているだけの文、文の途中に出てくる文言、空の文も")
    func humanText() {
        #expect(TaskboardNotice(text: "taskboardの通知（委譲先との会話など）は別の見た目になるといいな") == nil)
        #expect(TaskboardNotice(text: "taskboard: これは自分で打った") == nil)
        #expect(TaskboardNotice(text: "さっき「taskboard: 委譲先の会話 1234」と出ていた") == nil)
        #expect(TaskboardNotice(text: "利用枠が戻ったので、止まったところから続けてください。あと別件も") == nil)
        #expect(TaskboardNotice(text: "") == nil)
        #expect(TaskboardNotice(text: "さっき「[taskboard 通知] 委譲先の会話がターンを終えた」と出ていた") == nil)
        #expect(TaskboardNotice(text: "[taskboard 通知] これは自分で打った") == nil)
    }

    @Test("前の版：見出しは種類の名前と、文から読み取った番号と題。会話 ID と agent 向けの語は出さない")
    func legacySummary() {
        let turn = "taskboard: 委譲先の会話 221737fa「線 9 の画面」（#172）がターンを終えました。最後の返事:\n本文"
        #expect(TaskboardNotice.delegate.label == "委譲先の報告")
        #expect(TaskboardNotice.delegate.summary(of: turn) == "「線 9 の画面」（タスク#172）が応答を終えました")
        #expect(TaskboardNotice.delegate.summary(of: "taskboard: 委譲先の会話 b3cb353f（#172）が問いを待っています（session_answer で答える）:\n- 消してよいか") == "タスク#172の委譲先が質問しています")
        #expect(TaskboardNotice.delegate.summary(of: "taskboard: 委譲先の会話 b3cb353f「題」が問いを待っています:") == "「題」が質問しています")
        #expect(TaskboardNotice.delegate.summary(of: "taskboard: 委譲先の会話 b3cb353fがターンを終えました。最後の返事:") == "委譲先が応答を終えました")
        #expect(TaskboardNotice.link.summary(of: "taskboard: タスク #172 にリンクした PR・issue に動きがありました（URL を開いて読む）:\n- PR #41") == "タスク#172にリンクしたPR・issueが更新されました")
        #expect(TaskboardNotice.answer.summary(of: "taskboard で質問に答えました（#172）。\n「問い」→ 答え") == "タスク#172")
        #expect(TaskboardNotice.answer.summary(of: TaskboardNotice.feedbackTooLong) == "回答とレビューが長いため、セッションが別に取得します")
        #expect(TaskboardNotice.review.summary(of: "taskboard でレビューしました（#90）。\n総括: よい") == "タスク#90")
        #expect(TaskboardNotice.limitResume.summary(of: TaskboardNotice.limitResumeText) == "続きを送信しました")
        // 頭の文が変わった前の版の知らせは、種類の名前だけを出す
        #expect(TaskboardNotice.delegate.summary(of: "taskboard: 委譲先の会話 b3cb353f が別の形で終わった") == nil)
    }

    @Test("1 行目の印で見分け、値の組を読む。印は頭の文より先に見て、知らない種類と 2 行目以降の印は知らせにしない")
    func marker() {
        let marker = TaskboardNotice.marker(.sessionPrompt, ["from": "c98fc7dc", "task": "172", "empty": ""])
        #expect(marker == "<!-- taskboard: session_prompt from=c98fc7dc task=172 -->", "空の値は省く")
        let parsed = TaskboardNotice.parseMarker(marker + "\n本文")
        #expect(parsed?.kind == "session_prompt" && parsed?.attributes == ["from": "c98fc7dc", "task": "172"])
        #expect(TaskboardNotice(text: TaskboardNotice.marked(.delegate, "印の後はどんな文でもよい")) == .delegate)
        #expect(TaskboardNotice(text: TaskboardNotice.marked(.link, TaskboardNotice.limitResumeText)) == .link, "頭の文より印を採る")
        #expect(TaskboardNotice(text: "<!-- taskboard: future_kind -->\n新しい種類") == nil)
        #expect(TaskboardNotice(text: "人の発言\n<!-- taskboard: wake -->") == nil)
        #expect(TaskboardNotice(text: "<!-- taskboard: wake -->と続けて書いた人の発言") == nil)
        #expect(TaskboardNotice(text: TaskboardNotice.limitResumePrompt) == .limitResume)
        #expect(TaskboardNotice.stripMarker(TaskboardNotice.limitResumePrompt) == TaskboardNotice.limitResumeText)
        #expect(TaskboardNotice.stripMarker("印の無い文") == "印の無い文")
        #expect(TaskboardNotice.limitResume.summary(of: TaskboardNotice.limitResumePrompt) == "続きを送信しました", "要約は印を外した文で組む")
    }

    @Test("別のセッションからの発言：送り主の呼び名と本文の頭の 1 行を要約にする")
    func sessionPrompt() {
        let text = [
            TaskboardNotice.marker(.sessionPrompt, ["from": "c98fc7dc", "task": "172"]),
            TaskboardNotice.sessionPromptHead,
            "- 送り主: 会話 c98fc7dc「taskboard改修」（#172）。人の発言ではない",
            TaskboardNotice.bodyHeading,
            "",
            "DOCKER_CONFIG の件、了解です。",
            "以後は付けます。",
        ].joined(separator: "\n")
        #expect(TaskboardNotice(text: text) == .sessionPrompt)
        #expect(TaskboardNotice.sessionPrompt.summary(of: text) == "「taskboard改修」（タスク#172）　DOCKER_CONFIG の件、了解です。")
        let pane = [
            TaskboardNotice.marker(.sessionPrompt, ["from": "w1:p3"]), TaskboardNotice.sessionPromptHead,
            "- 送り主: pane w1:p3（reviewer）。人の発言ではない", TaskboardNotice.bodyHeading, "見てください",
        ].joined(separator: "\n")
        #expect(TaskboardNotice.sessionPrompt.summary(of: pane) == "pane w1:p3（reviewer）　見てください")
    }
}
