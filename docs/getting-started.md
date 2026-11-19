# 動かす

作者の環境で動かすために作っていて、ほかの環境でそのまま動くとは限らない。
CLI と daemon は `swift build` で作れる。
アプリは既定で ad hoc 署名でビルドする（下の「署名」）。iPhone と iPad への通知（APNs）には、自分の Apple Developer の鍵が要る（[daemon.md](daemon.md)）。

## 必要なもの

- **必須**
  - macOS 26 以降と Swift 6.2 以降
- **使うエージェント**：[Claude Code](https://code.claude.com) と [Codex](https://github.com/openai/codex) のどちらか、または両方
- **任意**
  - [GitHub CLI](https://cli.github.com)：PR の状態を追うとき
  - Xcode 27 と [XcodeGen](https://github.com/yonaskolb/XcodeGen)：アプリを作るとき（アプリは macOS と iOS、iPadOS の 26 以降）

## 入れる

```sh
swift build
.build/debug/taskboard install-launchd           # daemon・agent host を launchd に入れる
curl http://127.0.0.1:5780/v1/health             # daemon が動いているか
.build/debug/taskboard install-hooks --dry-run   # Claude Code の hook の変更を見るだけ
.build/debug/taskboard install-hooks             # ~/.claude/settings.json を backup してから hook を足す
claude mcp add --scope user --transport stdio taskboard -- ~/.local/bin/taskboard mcp
.build/debug/taskboard conversation check        # Claude Code の版を確かめ、会話に使えるようにする（Codex は --engine codex）
scripts/build-mac.sh                             # Mac のアプリを ~/Applications に入れる
```

同じ Mac のアプリは、起動すると daemon に自動で繋がる。
アプリから起動したセッションがカードに結ばれ、ボードに出る。

## 署名

`App/Signing.xcconfig` の既定は ad hoc で、Mac のアプリとシミュレータはそのままビルドできる。
自分の Apple Developer の Team で署名するときは、`App/Signing.local.xcconfig.example` を `App/Signing.local.xcconfig` に写して値を書く（`.gitignore` 済み）。

- **Mac のアプリ**：`TASKBOARD_MAC_SIGN_IDENTITY` に証明書の名前（`security find-identity -v -p codesigning` で出る `Apple Development: …`）、`TASKBOARD_TEAM_ID` に Team ID を書く。ad hoc のままだと、ビルドし直すたびに Keychain の確認が出る
- **iPhone と iPad の実機**：`TASKBOARD_TEAM_ID` と、自分の Team で登録できる `TASKBOARD_IOS_BUNDLE_ID` を書く

daemon の実行ファイルは `scripts/install-cli.sh` が署名する。証明書が Keychain にあればそれを使い、無ければ ad hoc にする（`TASKBOARD_SIGN_IDENTITY` で選べる）。

## 別の端末から繋ぐ

- **別の Mac**：アプリの設定の「接続先」に、その Mac の daemon の URL と token を入れる
- **iPhone と iPad**：繋ぐ先の Mac のアプリの設定（接続先）に出る QR コードを読む

daemon の token を持つ端末は、その Mac にセッションを作ってシェルに入力できる。
daemon をインターネットに直接出さず、信頼できるネットワークか認証付きの proxy（作者は Cloudflare Access）の内側に置く。

## Slack から頼む

1. api.slack.com/apps の「Create New App → From a manifest」に、次の manifest を貼ってアプリを作り、ワークスペースに入れる（管理者の承認が要るワークスペースもある）
2. 「OAuth & Permissions」の Bot User OAuth Token（`xoxb-`）と、「Basic Information → App-Level Tokens」で scope `connections:write` を付けて作った token（`xapp-`）を取る
3. アプリの案件の設定の「Slack」に 2 つの token を入れ、「受け付ける人」に依頼を受け付ける人のメンバー ID を足す。「チャンネルの届け先」でチャンネルをタスクに対応づけると、そのチャンネルの依頼はそのタスクのセッションに届く（ほかはオーケストレーター）。届け先にはほかの案件のタスクも選べるので、同じワークスペースのチャンネルを 1 つのアプリで案件ごとの常設のタスクに振り分けられる
4. メンションで頼むチャンネルにアプリを追加する。メッセージのメニューの「アプリに接続する → taskboardに送る」は、アプリを追加していないチャンネルでも使える。確認の画面で送り先（既定はチャンネルの届け先のタスク、無ければオーケストレーター）と指示を選んで送り、返信はアプリとの DM に届く
5. 上のバーのアプリの入口か、チャンネルの横に開いたアプリの画面で頼むと、返事は自分にだけ見える。頼んだときに横で開いていたチャンネルに届け先があれば、そのタスクのセッションに届く（同じスレッドの続きは最初の依頼と同じ届け先）。セッションが動いている間は Slack に「作業中」と出る（Slack の Agents の機能。有料のプランが要る。使えないアプリでは、届いた依頼に 👀 が付く）

前の manifest でアプリを作っていたら、アプリの設定の「App Manifest」を次のものに置き換えて保存し、ワークスペースに入れ直す（ショートカットの `commands` の権限と `interactivity`、Agents の `agent_view`・`assistant:write`・`app_context_changed`・`app_home_opened` が増えた）。

1 つのアプリは 1 台の Mac だけに設定する。

```yaml
display_information:
  name: taskboard
features:
  bot_user:
    display_name: taskboard
    always_online: true
  shortcuts:
    - name: taskboardに送る
      type: message
      callback_id: taskboard_send_message
      description: このメッセージをtaskboardのセッションに送ります
  app_home:
    messages_tab_enabled: true
    messages_tab_read_only_enabled: false
  agent_view:
    agent_description: taskboardのセッションに依頼を届けます。開いているチャンネルに届け先のタスクがあればそのセッションに、無ければオーケストレーターに届きます。
oauth_config:
  scopes:
    bot:
      - app_mentions:read
      - assistant:write
      - commands
      - chat:write
      - reactions:write
      - im:history
      - channels:history
      - groups:history
      - channels:read
      - groups:read
      - users:read
settings:
  event_subscriptions:
    bot_events:
      - app_mention
      - message.im
      - app_context_changed
      - app_home_opened
  interactivity:
    is_enabled: true
  socket_mode_enabled: true
```

## 次に読む

- [architecture.md](architecture.md)：しくみ
- [daemon.md](daemon.md)：コマンドと API
- [development.md](development.md)：ビルドとテスト、動作確認
