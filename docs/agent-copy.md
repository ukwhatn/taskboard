# 会話へ送る文

taskboard が会話（Claude Code・Codex）へ送る文と CLI の出力の置き場と書き方。画面の文は `docs/ui-copy.md` で、使わない語の表（下の「使わない語」）は両方に効く。

対象は次の文。読み手はエージェントで、CLI の出力だけは端末で読む開発者。

- MCP の instructions、tool の説明、tool の結果と誤り
- taskboard の知らせ（委譲先の報告、リンク・監視・予定の通知、質問の回答、レビュー、手作業の完了）
- hook の文（SessionStart の案内、Stop と PostToolUse と UserPromptSubmit が追加する文）
- 起動プロンプトの既定、オーケストレーターの起動プロンプト、列の既定の説明
- CLI の出力とエラー、`--help` の文

## 置き場

文は `Sources/TaskboardKit/Resources/` に置き、コードには書かない。どれも `{{名前}}` を値に置き換える（起動プロンプトの `{{id}}` と同じ書式）。

- 短い文（1 行の説明、エラー、項目）は `Agent.xcstrings` のキーにし、`Copy.text("キー", ["名前": 値])` で取得する
- 長い文（instructions、起動プロンプト）は `Prompts/<言語>/<名前>.md` のテンプレートにし、`Copy.prompt("名前", [...])` で取得する。daemon があとで値に置き換える起動プロンプトの既定は `Copy.template("名前")` で、置き換えずに取得する
- 概況の部品の種類ごとの欄（`panel_set`・`panel_update` の `parts` の説明）は `Prompts/ja/panel-parts.md`。部品の種類・記号・紐づけ先・CSS の変数とクラスの名前を変えたら、Kit の `Panel.swift`・アプリの `PanelHTMLPage` と一緒に修正する。予算と書式の誤りの文は `agent.panel.invalid.*`、注意は `agent.panel.warning.*`（`PanelValidation` が組み、daemon が 400 と `warnings` で返す）
- `{{id}}` のような placeholder を説明として文字どおり含む短い文は `Copy.unfilled("キー")` で取得する
- 文の placeholder と渡した値の名前が食い違うと、debug のビルドは `Copy.fill` で止まる。使っているキーとテンプレートの有無と、placeholder の名前の食い違いは `AgentCopyTests` が見る

キーの頭で、誰が読む文かを分ける。

- `agent.`: 会話が読む文。続きは置き場（`agent.tool.<tool の名前>.<引数>`、`agent.mcp.<ファイル>.<宣言>`、`agent.notice.`、`agent.hook.`、`agent.guidance.`、`agent.column.<列の id>`）
- `cli.`: 端末で人が読む CLI の文
- `ui.`: daemon が組んで画面に届く文（チャットの `/` の候補の説明 `ui.slash.<名前>`）。`docs/ui-copy.md` の規則に従い、UICopyTests が同じ規則で読む

SwiftPM は `Agent.xcstrings` とテンプレートを compile せずに `taskboard_TaskboardKit.bundle` へコピーし、`Copy` が `Agent.xcstrings` を JSON として読む（`.process` にすると、xcstringstool の無い Command Line Tools でビルドした Mac では compile されずに写り、文がキーのまま返った）。`scripts/install-cli.sh` は実行ファイルの隣に bundle もコピーする（bundle が無いと `Bundle.module` が見つからず止まる）。アプリには Xcode が同じ bundle を含める。

### 英語の追加

今は日本語だけを持つ。英語を追加するときは、`Agent.xcstrings` の各キーに `en` の訳を書き、テンプレートは `Prompts/en/` に同じ名前で置く。テンプレートの言語は `Agent` の表と同じ言語（`Bundle.module.preferredLocalizations` の先頭）で選び、その言語のファイルが無ければ `ja` を使う。

## 書き方

会話へ送る文は、会話が誤読しないことを優先する。

- 常体で書く（「〜する」「〜した」「〜が無い」）
- 誰が何をするかを書く。会話にしてほしいことは「次の操作:」の項目か「〜する」「〜を渡す」で書き、taskboard がしたことは「〜した」で書く。指示と事実を 1 つの文に混ぜない
- 期限と条件があれば書く（「confirm: true を付けるまで実行しない」「60 秒ごと」）
- tool の名前、引数の名前、値（`force: true`、`state wait`）はそのまま書く
- 書き言葉の漢語を使う。話し言葉と和語の作業動詞（確かめる、消す、止める、要る、足す、直す）は使わず、確認する、削除する、停止する、必要、追加する、修正すると書く。検査は `python3 -I ~/.claude/skills/writing-prose/scripts/check_register.py <ファイル>`
- 定着した英語とカタカナ語は和語や漢語に置き換えない。タスク、PR、issue、マージ、セッション、エフォート、worktree はそのまま書く
- 語を置き換えるのは、AI が作りがちで意味の伝わりにくい語（下の表）と、上の話し言葉に限る。意味は変えない

### 変えない印と見出し

次の文字は、会話と hook と別のプログラム（`TaskboardNotice` の読み取り、`~/.claude` の指示）が文で見分けている。文字を変えない。どれも `Sources/TaskboardKit/TaskboardNotice.swift` に置いたままにし、カタログに移さない。

- `<!-- taskboard: ... -->` の印
- 「[taskboard 通知]」と、それに続く見出し（「委譲先の会話がターンを終えた」「別のセッションからの発言」「Slack から依頼が届いた」など）
- 「taskboard で質問に答えました（#」「taskboard でレビューしました（#」「taskboard で手作業を済ませました（#」「taskboard で送る文面を承認しました（#」
- 知らせの本文の項目名のうち、`TaskboardNoticeSummary` が読む「- 送り主:」「- 会話:」

## 使わない語

画面の文と会話へ送る文の両方で使わない。1 列目の語は UICopyTests の `CopyRule.avoided` が見つける（表に語を追加したら規則も追加する。`avoidedTableMatchesDocs` が表と規則の食い違いを見る）。

| 使わない語 | 使う語 | 理由 |
|---|---|---|
| 「人の番」「自分の番」「利用者の番」「誰の番」 | 画面は「対応待ち」。会話へ送る文は、誰が何をするかを書く（「対応する側」） | 何を待っているのか、誰が動くのかが読めない |
| 「〜の形」「〜する形で」「〜という形」 | 書式、形式（「id の書式でない」「入力の形式が正しくありません」）。言い回しの「〜という形で」は削る | 「id の形でない」「始まる形で入力」は、何が違うのかが読めない |
| 「棲み分け」 | 使い分け、役割の分担 | 比喩で、何をどう分けるのかが読めない（今の文には無い。ユーザーが挙げた語） |
| 「担保」 | 保証する、確認する | 誰が何をするのかが読めない（今の文には無い。設計書が挙げた語） |
| 「見張る」「見張り」 | 監視（「PR・issueの監視」） | 画面の用語表は監視 |
| 「起こす」「起き直す」 | 起動、再起動。起動した会話は委譲元 | 画面の用語表は起動 |
| 「結ぶ」「結び」 | 紐づける、紐づけ | 画面の用語表は紐づけ |
| 「写す」「写し」 | コピー | 「会話を写した」が、複製なのか表示なのかが読めない |
| 「差し込む」 | 追加する | 画面の用語表は追加 |
| 「畳む」 | 折りたたむ | 画面の用語表は折りたたむ |

## 検査

- `swift test --filter UICopyTests`: 画面の catalog、`Agent.xcstrings`、テンプレートに使わない語が無いことと、`ui.` の文が画面の規則に合うことを見る
- `swift test --filter AgentCopyTests`: コードが取得するキーとテンプレートがあること、使われていないキーが無いこと、placeholder の名前が食い違わないことを見る
- 話し言葉は `check_register.py` で見る（テストには含めていない）
