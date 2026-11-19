# 開発

ビルド、テスト、人の手を借りない動作確認、依存の版。daemon の仕様は [daemon.md](daemon.md)、画面の作りと文言は [ui-system.md](ui-system.md) と [ui-copy.md](ui-copy.md)。

## ビルド

```sh
swift build                 # Kit / daemon / CLI
swift test
cd App && xcodegen generate # Taskboard.xcodeproj を作る（.gitignore 済み。Sources にファイルを足したら生成し直す）
scripts/build-mac.sh        # Mac アプリをビルドし ~/Applications/Taskboard.app にコピー（Spotlight から開ける）
xcodebuild -project App/Taskboard.xcodeproj -scheme Taskboard \
  -destination 'platform=iOS Simulator,id=<udid>' -configuration Debug -derivedDataPath .build/DerivedData-iOS -quiet build
scripts/snapshot-test.sh    # 画面の snapshot test（macOS）。失敗した回の PNG を .build/snapshots-out/ に写す
scripts/snapshot-test.sh --ios <udid>   # iPhone の幅の snapshot test と iOS の単体テスト（scheme TaskboardiOS）をそのシミュレータで回す
```

iPhone の幅の snapshot test（`App/Tests/iOS/PhoneSnapshotTests.swift`）は、fixtures `conversations` のタスクの一覧・タスクの画面・会話の画面（キーボードなし）を、iPhone 17e と iPhone 18 Pro のシミュレータで描き、`App/Tests/iOS/__Snapshots__/` の PNG と比べる。端末はシミュレータの窓の大きさで決めるので、2 つの端末でそれぞれ回す（ほかの大きさの端末では落ちる）。ガラスの部品（タブバー・ナビゲーションバー）は key window で描かないと出ないので、テストのアプリの窓に載せて描く。タブバーのぼかしは回ごとに下の画素を少しずつ変える（17e のタスクの一覧で 1.4%）ので、2% までの違いは通す。失敗した回の PNG は `.build/snapshots-out/` に直接出る。同じ scheme で、iOS でも動く単体テスト（`MainThreadWatchdogTests`・`DiagnosticsOutboxTests`・`HangDiagnosticsTests`）も回る。

snapshot test（`App/Tests/BoardSnapshotTests.swift`）は fixtures のボード・カード・作業項目の一覧を light / dark / コントラスト増の 4 組で描き、`App/Tests/__Snapshots__/` の PNG と比べる。見た目を変えたら、`.build/snapshots-out/` に出た PNG を見てから `App/Tests/__Snapshots__/` に写してコミットする（`SNAPSHOT_TESTING_RECORD=all` はテストの実行先に渡らない）。日数の表示は環境値 `today` を固定して描くので実行日に依らない。

全体を回すと、毎回違う画面が 1〜2 枚落ちることがある（2026-10-20 に 12 回中 7 回）。どれも AppKit の入力欄で、欄の高さが 1〜4pt 違うか、欄の中の字の描き方が少し違う。原因は分かっていない。保存先（`AppDefaults.store`）の共有ではない（1 つの test の中で同じ model と保存先から 30 回撮っても揺れた）。高さは最初の配置から違い、待っても変わらないので、`LayoutMatrixSnapshotTests.host` の配置が止まるまで回す待ちでは防げない。落ちた画像の違いがこの形だけなら、回し直して確かめる。入力欄が 16pt でなく 17pt に配置され、その行から下がそっくり 1pt 下がる回がある（コネクタのシートの検索欄で、2026-10-25 に全体の回だけ落ちた。窓の無い view の AppKit の部品が倍率 1 で高さを切り上げるためと見ているが、2026-10-26 に全体を 8 回回しても再現せず、確かめていない）。窓に載せて倍率を揃えると部品が非アクティブの見た目になり参照の 506 枚が変わったので、揺れた画面だけ `assertImageSnapshot` の `allowingFieldGrowth` で、この形（違う行は 16pt 以内の 1 帯だけで、その下は参照と同じ行か 1pt 上の参照の行と同じ。`FieldGrowth`）を参照と同じとみなす。

Mac Studio（Xcode 無し、CLT の Swift 6.3）では daemon だけを `swift build -c release` でビルドする。アプリは Xcode 27 のある Mac で作る。

## アプリの動作確認（人の手を借りない経路）

DEBUG ビルドだけが `--debug-port` で loopback に制御口を開く。debug の口で起こしたアプリは、fixtures でなくても、この端末の設定（`AppDefaults`）をユーザーのアプリと別の空の保存先に置き、イベントのログも書かない。`--defaults-file <plist>` を付けると、その保存先に plist の中身を入れてから起動する（`defaults export uk.whatn.taskboard <plist>` で写したユーザーの設定で、ユーザーのアプリと同じ並びと開き方を再現する。写しには会話の下書きも入るので、確かめ終えたら消す）。

```sh
APP=.build/DerivedData/Build/Products/Debug/Taskboard.app/Contents/MacOS/Taskboard
$APP --debug-port 5790 --scenario sessions-basic &   # fixtures で起動。省略すると同一 Mac の daemon に繋ぐ。「settings+settings-second」のように + でつなぐと別のマシンとして並ぶ（設定の撮影用。fixtures は書き込めないので、保存すると「表示用のデータです」の失敗が出る）
curl :5790/state                                      # 画面の今（JSON）
curl -X POST :5790/screenshot -o shot.png             # 自ウィンドウの PNG（{"window":1} で /menu の windows の 1 番目の窓。設定の窓など。プロセス内描画。サイドバーとインスペクタの material は黒や虹色に写り、NSSwitch の on も写らない。シートが出ていればシートを撮る。インスペクタの中身は snapshot test か iPhone シミュレータで見る）
curl -X POST -d '{"scheme":"dark"}' :5790/appearance  # light / dark / system
curl -X POST -d '{"url":"taskboard://conversation/<machine-id>/<会話の id>"}' :5790/navigate   # board/<machine-id>/<board-id>、task/<machine-id>/<number>、unassigned/<machine-id>、pr?url= も。conversation はその置き場（タスク・オーケストレーター・タスクなし）の画面で札を選ぶ
curl -X POST -d '{"title":"...","links":"https://...\nhttps://...","due":"2026-10-05"}' :5790/new-task   # ⌘N のシートを下書き入りで出す。"submit":true で作成まで、"launch":true で「追加して起動」（cwd / kind / model / effort / args / prompt も受ける。model は `--model` に渡す名前（opus・claude-sonnet-5-5 など）、effort は low〜max）。`{"close":true}` で閉じる
curl -X POST -d '{"number":138,"cwd":"~/dev/x","model":"sonnet","effort":"high","prompt":"..."}' :5790/launch   # タスク画面の「起動」と同じ経路（Codex は "kind":"codex" に "codexModel"・"codexEffort"（codex の名前のまま）。"submit":false でシートを出すだけ、{"close":true} で閉じる）
curl -X POST :5790/worktrees/sheet                              # サイドバーのマシンの行の［使っていないworktreeを削除…］（見ている画面のマシン。一覧はそのマシンの daemon から読むので、fixtures では「書き込めません」になる。本物でない daemon に繋ぐなら `--daemon-url` と `--token-file`）。`{"close":true}` で閉じる
curl -X POST :5790/orchestrator/start                            # サイドバーのマシンの行の右クリックの「起動」
curl -X POST -d '{"text":"..."}' :5790/steer                    # 指示のシート（Mac）の「送信」（居なければ 409）
curl -X POST -d '{"number":138,"column":"working"}' :5790/task/move   # カードの「列を移す」と同じ経路
curl :5790/work                                                # 選択中のタスクの作業項目（"number" で指定も可）
curl -X POST -d '{"title":"実装する"}' :5790/work/add           # インスペクタの追加欄と同じ経路
curl -X POST -d '{"id":2,"state":"doing"}' :5790/work/update   # 行の状態の印と同じ経路（title / blockerKind / blockerText / "delete":true）
curl :5790/inbox; curl -X POST -d '{"id":"<machine>/ask/1"}' :5790/inbox/open  # 受信箱の項目（鳴らす項目は通知の題・補足・本文・行き先も）と、項目の行き先への遷移
curl -X POST -d '{"id":"<machine>/ask/1"}' :5790/inbox/notification   # その行の通知を押すのと同じ遷移（本物の通知は出さない）
curl -X POST -d '{"task":128,"machine":"<machine-id>"}' :5790/inbox/dismiss   # カードの右クリックの［対応待ちを非表示］（そのタスクの対応待ちを全部。daemon に記録し、全部の端末から消える）。{"id"} で 1 つ
curl -X POST -d '{"tab":"status"}' :5790/side-pane; curl -X POST -d '{"id":"column/<machine-id>/<board-id>/done","expanded":true,"collapsedByDefault":true}' :5790/sidebar/node   # タスク画面の右側の欄を開く（status / docs / work / changes / terminal。terminal は開いている会話のシェルを起こして欄に出し、"close":true で閉じて止める）と、サイドバーの案件・列の節の開け閉め
curl -X POST -d '{"handle":"status|docs","by":120,"steps":60,"gapMs":8}' :5790/side-panels/drag   # タスク画面の右側の欄の境目（handle は「上の欄|下の欄」）を、取っ手のドラッグと同じく動かし始めからの移動量で steps 回動かして離す。取っ手の DragGesture は、裏にある窓に /drag で作ったマウスのイベントでは動かない
curl -X POST -d '{"grouping":"state","order":"recent"}' :5790/sidebar/arrangement; curl -X POST :5790/attention/next  # サイドバーの「並べ方」（/state の sidebarTree の arranged に組が出る）と［次の入力待ちへ移動］（開いた項目か、無いときの知らせを返す）
curl -X POST -d '{"number":131,"pinned":true}' :5790/sidebar/pin; curl -X POST -d '{"number":137}' :5790/task/end-all  # ［ピン留め］（/state の sidebarTree の pinned に出る）と［すべて終了］（終えるものと、確認を出したならその本文を返す。fixtures では終了は送られない）
curl -X POST -d '{"conversation":"c-gen"}' :5790/task/split  # 開いているタスクの右に 2 つ目を並べる（札を ⌘ を押しながら押したのと同じ。窓の会話の一覧の数を返す）
curl :5790/push                                                 # iPhone・iPad の APNs: トークンの有無と先頭 8 字・環境・通知の許可・接続先ごとの登録（届くか・最後に送った時刻・失敗の理由）。秘密は返さない
curl :5790/push/delivered                                       # 通知センターに残っている通知（本物の APNs から届いたか、/push/respond に渡す userInfo）
curl -X POST -d '{"action":"allow","userInfo":{"connection":"conn:<uuid>","conversation":"<会話の id>","request":"<問いの id>"}}' :5790/push/respond   # 通知の「許可」「拒否」（"deny"）を押すのと同じ処理。失敗の知らせのローカル通知も出す
curl :5790/prs; curl -X POST -d '{"url":"https://github.com/o/r/pull/1"}' :5790/prs/open   # PR（取った PR の一覧）と、通知の PR を押すのと同じ遷移（結んだタスクのサイドパネルの PR か、タスクなしの画面）
curl ':5790/prs/detail?url=https://github.com/o/r/pull/1'; curl -X POST :5790/prs/refresh    # 中身の要約と「更新」
curl :5790/doc/text; curl -X POST :5790/doc/screenshot -o doc.png    # 開いている文書の本文・画像の読み込み有無と、WKWebView の描画（/screenshot には写らない）
curl -X POST -d '{"askID":1,"answers":[{"questionID":"q1","selected":["A"]}]}' :5790/ask/answer
curl -X POST -d '{"docID":1,"body":"ここ","quote":"一行目"}' :5790/comment; curl -X POST -d '{"number":145,"summary":"よい"}' :5790/review/submit
curl -X POST -d '{"mode":"chat"}' :5790/session/mode     # セッションの表示（chat / terminal）。UserDefaults に残る
curl -X POST -d '{"action":"find"}' :5790/session/actions  # 表示のメニューの［検索…］（zoomIn / zoomOut / zoomReset は拡大・縮小・実際のサイズ）。開いているチャット・会話・端末が受ける。受ける画面が無ければ 409
curl :5790/chat; curl -X POST -d '{"text":"..."}' :5790/chat/send   # 開いているセッションの会話と貼った画像、入力欄の「送信」（貼った画像も送る）
curl -X POST -d '{"path":"/tmp/a.png"}' :5790/chat/paste       # ⌘V・ドロップ・［ペースト］の代わりに、このMacの画像のファイルを入力欄に貼る
curl :5790/chat/question; curl -X POST -d '{"choices":[2]}' :5790/chat/answer   # AskUserQuestion の今の問（画面を読み直す）と、質問の欄の［次へ］・［回答を送信］（"other" で自由記述。確かめの画面は {}）
curl :5790/conversation           # 開いている host の会話の手元（phase・seq・epoch・末尾の発言・生成中の block・先に出した発言）と答えを待っている問い
curl -X POST -d '{"text":"..."}' :5790/conversation/send   # 会話の入力欄の「送信」（先に出してから送る）。{"clientMessageID":"..."} を /conversation/retry に送ると［再送信］
curl -X POST -d '{"allow":true}' :5790/conversation/answer # 今の問いに答える（権限・計画は allow、質問は {"answers":[{"questionID":"q0","selected":["HTML"]}]}）
curl -X POST :5790/conversation/interrupt                  # 生成を停止（プロセスは残す。待ち行列の発言は下書きに戻る）
curl -X POST :5790/conversation/close # 終了する（確認は出さない。記録は消さずに終了の印を付ける）
curl -X POST -d '{"open":"model"}' :5790/conversation/field   # 入力欄の下の欄を開く（model / effort / permission。{"close":true} で閉じる）。/conversation の openField・connectors・contextBreakdown・commands・runs・diff・fileDiffs で中身を読む
curl -X POST -d '{"open":"rewind"}' :5790/conversation/sheet   # 巻き戻しの確認（"message" で指示の id、省くと最後の指示）、差分の画面（"diff"）、コネクタ（"connectors"）、コンテキストの内訳（"context"）、上の帯の［状態］（"info"）を出す。{"close":true} で閉じる
curl -X POST -d '{"text":"/mo"}' :5790/conversation/slash      # 入力欄に打ったときの / の候補（名前・操作・合った別名）
curl -X POST -d '{"enabled":true}' :5790/conversation/keep-subscriptions  # 画面を離れても unsubscribe を送らない（購読の数がいつ減るかを測る）。返りに今の購読と数
curl :5790/approval/screen; curl -X POST -d '{"keys":["esc"]}' :5790/approval/keys   # シートが読んでいる画面と、ボタンと同じ送信
curl :5790/connections                                          # 接続先と状態（秘密は返さない）
curl :5790/usage                                                # マシンごとの枠の表の行と、セッションの context
curl :5790/schedules; curl ':5790/schedules/runs?id=1'            # 全マシンの定期起動（要約・次回・前回）と履歴
curl -X POST -d '{"name":"tb-確認","intervalMinutes":5,"cwd":"/tmp/x","model":"sonnet","effort":"high","prompt":"...","board":"<board-id>","column":"todo"}' :5790/schedules/create   # フォームの保存と同じ経路（"cron" も可。"task" で既存タスク、どちらも無ければ紐づけない）
curl -X POST -d '{"id":1}' :5790/schedules/run                  # 「今すぐ実行」。/schedules/enable {"id","enabled"}、/schedules/delete {"id"}
curl -X POST -d '{"id":3}' :5790/schedules/form                 # 定期起動の編集のシートを出す（id を省くと追加、{"close":true} で閉じる。保存はしない）
curl -X POST -d '{"landscape":true}' :5790/orientation          # iPad と iPhone の画面の向きを変える（シミュレータの横向きの撮影用。iOS だけ）
curl -X POST -d '{"name":"Studio","url":"https://...","tokenFile":"<path>","accessFile":"<path>"}' :5790/connections   # 秘密は path で渡す。accessFile は {"clientID","clientSecret"}。/connections/delete {"name"} で消す
curl -X POST -d '{"name":"sessions-basic"}' :5790/scenario   # 「+」でつなぐと別のマシンとして並べて読む（stress+machine-second でオーケストレーターの送り先、stress+lists-second+lists-long で 3 台、lists-second+prs-second で PR のアカウントが 2 つ（どちらも 2 台が取る）、empty で空のマシン。2 台目の fixtures は scripts/fixtures/make-second-machine.py が作る）
curl :5790/terminal/text                              # 開いている端末に見えている文字（Metal の描画も PNG に写るが、文字で確かめる方が確実）
curl -X POST -d '{"pane":"shell-<会話の id>","text":"ls\r"}' :5790/terminal/input  # 開いているシェルへ入力（/terminal/paste は貼り付けと同じ経路）。開いているシェルと違えば 409
curl -X POST :5790/terminal/takeover                  # 操作を引き継ぐ / :5790/terminal/release で返す
curl -X POST -d '{"lines":300}' :5790/terminal/scroll  # ホイールと同じ経路で過去へ（{"bottom":true} で最新へ）
curl -X POST -d '{"key":"terminal.fontSize","value":18}' :5790/defaults  # @AppStorage の値（⌘+ / ⌘- と同じ所）
curl -X POST -d '{"key":"k","modifiers":["command"],"activate":true}' :5790/key   # キーを 1 つ送る（"window" で送り先のウィンドウの題を指定。"activate" を付けたときだけアプリを前面に出す。前面に無いと、フォーカスが要る onKeyPress には届かないことがある）
curl -X POST -d '{"x":400,"y":300}' :5790/click   # 画面の座標（左上が原点）をアプリの中で作ったクリックで押す。マウスは動かさず、前面にも出さない。シートと popover の窓にも届く（popover は panel なので `orderedWindows` に無く、`NSApp.windows` から探す）。/key は key の窓が無ければ見えている窓に送る
curl -X POST -d '{"from":{"x":400,"y":300},"to":{"x":500,"y":700},"steps":12}' :5790/drag; curl :5790/chat/selection   # 同じ座標で押して動かして離す（"clickCount":2 で二度押し。窓が後ろにあっても、押した位置の view に直に渡す）と、会話の一覧が選んでいる文（⌘C で写す文。クリップボードには書かない）。/drag の `hit` は押下を渡した view の型
curl -X POST :5790/file/comment; curl -X POST -d '{"popover":true}' :5790/screenshot -o pop.png   # 会話の差分の画面で選んだ行の［コメント］と同じ操作をし、開いた popover の窓を撮る
curl -X POST -d '{"text":"本文の一部"}' :5790/doc/select   # 文書の本文の最初の一致を選び、選んだ所の枠を返す（作ったドラッグは WKWebView の選択にならない）。浮いた［コメント］は /screenshot に写る
curl :5790/outline   # サイドバー（List）の行の段・画面の上で開いているか・行と開閉の三角の位置（/click と同じ座標）と、AppModel の開閉の状態。List は /screenshot に写らず、アクセシビリティの許可の無いプロセスからも開閉を確かめられる
curl -X POST -d '{"back":true}' :5790/window/order   # 窓をほかのアプリの窓の後ろへ回す
curl -X POST -d '{"task":200}' :5790/window/open   # タスク（{"doc":1} で文書）を別ウィンドウで開く
curl :5790/board/cards; curl -X POST -d '{"key":"<machine>/<number>"}' :5790/cursor   # 全体のボードのカードの並び（scroll に面と中身の大きさと位置。位置はサイドバーとツールバーの分だけ負から始まる）と、そのカードまで送るキーのカーソル（開かない）
curl -X POST -d '{"direction":"down"}' :5790/cursor/move   # ↑↓←→ と同じくカーソルを動かす
curl :5790/menu; curl -X POST -d '{"title":"#7 ..."}' :5790/window/close   # メニューの項目とウィンドウの一覧、題でウィンドウを閉じる（`/menu?update=1` でメニューを開いたときと同じ更新をかけ、チェックの `state` も読む）
curl -X POST -d '{"title":"Taskboardについて"}' :5790/menu/perform   # メニューの項目を題で探して実行する（標準のパネルの撮影用）
curl -X POST -d '{"name":"palette"}' :5790/overlay   # ⌘K / ⌘/ / 案件を作るシートを出す（shortcuts / newBoard、none で閉じる）
curl -X POST -d '{"enabled":true,"id":"local"}' :5790/only-machine   # 1 台だけ表示（⌃⌘1 と同じ所。id を省くと今の残すマシン）
curl -X POST :5790/perf/start; curl -X POST :5790/perf/stop   # 画面の更新間隔を記録し、中央値・p95・最大と引っかかり（中央値の 2 倍超）の回数・ms/s を返す
curl -X POST -d '{"kind":"task-switch","count":20,"gapMs":300}' :5790/bench   # 操作してから描き終わる（画面の更新が 2 回届く）までを 1 回ずつ測り、中央値・p95・最大を返す。open-close は開くと閉じるを別に、sidebar は「すべての案件」と各案件を順に選ぶ。session は今の画面のまま、agent のいる最初のセッションの状態を回した知らせを fixtures の流れに差し込む。"numbers" でタスクを指定（省くと案件の終わっていないタスク。案件は "board" に id で指定し、省くと最初の案件）
curl -X POST -d '{"seconds":10,"perSecond":2}' :5790/fixture/flow   # fixtures だけ。動いている daemon が送り続けるのと同じ種類の知らせ（会話の様子が 4 回に 3 回、残りは終わっていないタスクの作業項目の更新）を、各マシンに順に流す。測る口に触らないので /hitch と並べて送れる。fixtures に差し込む知らせ（これと /fixture/work・/bench の session）は、その知らせのマシンの fixtures にだけ届く
curl -X POST -d '{"mode":"modal"}' :5790/presentation   # タスクの開き方（side / full / modal）
curl -X POST -d '{"dy":24,"steps":90,"interval":16}' :5790/board/scroll   # 全体のボードを 1 フレームずつ下へ送って戻す（合成したホイールは ScrollView に届かないので、位置を直接動かす）
curl -X POST -d '{"x":4900,"y":-300,"lines":6,"count":20}' :5790/wheel   # 画面の座標に phase の無いホイール（マウスのホイール）を送る。lines が正なら上へ。会話の画面の追従を確かめる（窓に直に渡し、local monitor にも見せる）
curl -X POST -d '{"messages":1500,"chunk":10,"streamSeconds":5,"deltaMs":50}' :5790/bench/conversation   # （"thinking":true で段落の発言の半分を畳んだ思考の行にする）開いている会話に、新しい控えとして発言を chunk 件ずつ流し、流し終えるまでの ms と、続けて生成中の差分を流した間の画面の更新間隔・主スレッドの使用時間・body の回数・流した字数を返す（fixtures の conversations で taskboard://conversation/fixture-studio/c-gen を開いてから）
curl -X POST -d '{"text":"…","gapMs":80,"caret":false,"noop":false,"keep":false}' :5790/conversation/type   # 開いている会話の入力欄の文を 1 字ずつ伸ばし（caret はカーソルを動かす）、打鍵ごとの主スレッドの時間・画面の更新間隔・body の回数を返す。keep で終わった後も文を残し、GET /conversation/draft で書きかけを読む
curl -X POST -d '{"text":"…","settleMs":3000,"then":"あいう","gapMs":80,"insert":true}' :5790/conversation/fill   # 開いている会話の入力欄に長い文を一度に入れ（貼り付けと同じく全部が一度に変わる）、settleMs の間の主スレッドの使用時間（spanMaxMs が一番長くふさがった時間）と、続けて then を末尾に 1 字ずつ足した打鍵ごとの時間を返す。insert なら Mac の入力欄の insertText で入れる（打鍵・貼り付けと同じ経路。省くと文の Binding を差し替える）。長い文で入力欄が止まらないかは scripts/ui/composer-perf.sh で測る
curl :5790/conversation/composer; curl -X POST -d '{"mark":"にほんご"}' :5790/conversation/composer   # Mac の入力欄の文・選択・変換中か・窓の first responder か・高さ。POST の mark で変換中の文を置き、{"unmark":true} で確定する（本物の入力メソッドは使わない）。{"key":"return","modifiers":["shift"]} は入力欄の窓に直にキーを渡し（アプリが前面に無くても届く）、{"focus":true} は入力欄にフォーカスし、{"replace":"文"} は打鍵と同じ経路で文を入れ替え、{"paste":"文"} は ⌘V と同じ経路（5,000 字以上なら添付の札、短ければ入力欄。本物のクリップボードは使わない）で入れ、{"addFiles":["/パス"]} はドロップと ⌘V のファイルと同じ経路（`AppModel.addChatFiles`）で下書きに足し、応答の `files`（札の名前とフォルダか）と `filesFailure` で確かめる。↩・⇧↩・変換中の ↩・/ の候補・Tab・下書きの持ち越しは scripts/ui/check-composer.sh でまとめて確かめる
curl -X POST -d '{"dy":20,"steps":240,"intervalMs":16,"back":false}' :5790/conversation/scroll   # 窓の中で中身が一番高い NSScrollView（会話の一覧。会話が短いとサイドバーの List を選ぶので、/bench/conversation で流し込んでから）に、ピクセル単位のホイールを 1 フレームずつ渡す。back なら同じだけ戻す。合成したホイールには窓が付かないので、一覧の NSScrollView に直に渡す（窓に渡しても一覧は動くが、それは /wheel で確かめる）。untilEdge で端に着いたら止め、trackpad で phase（began・changed・ended）と momentum の付いたなでにし、settleMs だけ待って位置を読み直す。送る前・向きを変える所・後・待った後の位置（offset と下端までの gap）を返す
curl -X POST -d '{"dy":40,"steps":60,"intervalMs":32}' :5790/conversation/scroll   # iPhone・iPad では、一覧の UIScrollView の位置を 1 回ごとに dy だけ上へずらす（負なら下へ）。delegate になでの始めと終わりを知らせる（知らせないと SwiftUI は人が送った位置と見なさず、ScrollPosition が下端を指したままになる）。両方の回に見えていた行の動きから送った量を引いた分を、ずれ（jumpSteps・maxJump）として返し、主スレッドの使用時間・画面の更新・body の回数も返す
curl :5790/conversation/rows   # iPhone・iPad だけ。一覧に今ある行の上端（見えている所の上端から。DEBUG のビルドで行ごとに控える）と位置。/bench/older の前後で比べ、見ていた行が動かないかを見る
curl -X POST -d '{"intervalMs":10}' :5790/hitch/start; curl -X POST :5790/hitch/stop   # 主スレッドの止まりを本番の main.hitch と同じ見張り（MainThreadWatchdog、100 ms 超え）で数え、数・最大・長い順を返す。見張る間は App Nap を止める（Mac）。iPhone・iPad でも返す
curl -X POST -d '{"ms":3000}' :5790/main/block   # 主スレッドを ms だけ止める（60,000 まで）。見張り・/hitch・止まりの記録が拾うかを確かめる
curl :5790/diagnostics; curl -X POST -d '{"durationMS":4100,"callStackTree":{…}}' :5790/diagnostics/hang   # iPhone・iPad だけ。接続先の daemon へ送る前の止まりの記録（溜まり）と、MetricKit の MXHangDiagnostic を受けたのと同じ経路で記録を足す（callStackTree は MXCallStackTree.jsonRepresentation() の形）
curl -X POST -d '{"count":600,"intervalMs":8,"region":"list"}' :5790/mouse/move   # mouseMoved を窓の中で動かしながら窓に渡す（本物のカーソルは動かさない。前面に無い窓は mouseMoved を受けないので、窓を key にして受けさせる）。list は会話の一覧、window は窓の全体
curl -X POST :5790/sidebar/toggle   # 主ウィンドウのサイドバーを開閉し、閉じているかを返す（メニューの項目は窓が key でないと届かないので、分割の controller に直に送る）
curl -X POST -d '{"seconds":10,"deltaMs":50}' :5790/bench/stream   # 開いている会話に生成中の返答の差分を流す。測る口に触らないので /conversation/scroll・/mouse/move と並べて送れる
curl -X POST -d '{"holdMs":3000}' :5790/bench/thinking   # 開いている会話に思考を書いている block を出し、holdMs の後に終わった思考の発言（履歴の行）で置き換える。置き換わる前後に /screenshot を撮って、思考の行の高さと位置が動かないかを見る（fixtures `chat-thinking` の c-think を開いて）
curl :5790/fields; curl -X POST -d '{"index":2,"text":"…","settleMs":3000,"then":"あいう"}' :5790/field/fill   # 見えている窓の入力欄（Mac は NSTextField・NSTextView、iPhone と iPad は UITextField・UITextView。名前・種類・字数・窓・位置・フォーカスがあるか）と、その index 番目に長い文を貼り付けと同じ経路（insertText）で入れたときの主スレッドの使用時間・続けて打った打鍵ごとの時間（"name" で読み上げの名前かプレースホルダーで選ぶ。SwiftUI の TextField は名前が空のことが多い）。/field/focus {"index"} はフォーカスを置いて見える所まで動かし（{"resign":true} はその窓のフォーカスを外す）、/field/key {"index","key","modifiers"} はその欄の窓に /key と同じキーを直に渡す（Mac だけ。窓が前面に無くても届く）。iPhone と iPad は /field/scroll {"index","to":"bottom"} か {"index","dy"} で欄を中に持つ一覧を送り（どちらも無ければその欄が見える所まで。Form は画面に出た行の欄しか作らない）、/field/return {"index"} でキーボードの ↩ と同じく delegate に聞いてから末尾に改行を入れる
curl -X POST -d '{"kind":"memo"}' :5790/lab/field   # fixtures では書き込めず開けない欄（title・memo・link のその場の編集、comment、reply、blocker）を、部品のまま載せた窓「測りの欄」に開く（Mac は後ろに、iPhone と iPad は画面の上に重ねる。{"close":true} で閉じる）。GET /lab/field はその欄で呼ばれた確定・取り消し・送信の記録
curl -X POST -d '{"rows":50,"columns":6}' :5790/bench/table   # 開いている会話に大きな表を含む発言を 1 つ届け、描き終わるまでの ms と、会話の一覧の中の NSTextView の数（listTextViews。行の文は NSTextView にしないので 0）を返す
curl -X POST -d '{"messages":200}' :5790/bench/older   # 開いている会話の前に、古いページを読んだのと同じに人の発言（「古いページ 0」が一番古い）を足す。一番上まで送ってから足し、見ている所が飛ばないかを撮って確かめる
curl -X POST -d '{"section":"boards","board":"<board-id>"}' :5790/settings   # 設定を開く（connections / boards / sessions / terminal / chat / notifications / display / shortcuts）。board を渡すと案件の中身（名前・マージしたら・列・起動）まで開く
```

アプリはイベントのログを JSON Lines で `~/Library/Application Support/taskboard/logs/app-events.jsonl` に書く（iOS はアプリの container の同じ所。5MB で `app-events.1.jsonl`・`.2.jsonl` に回す。fixtures・test host・snapshot test は書かない）。種類はセッションの切替の段階（`session.switch`。opened → connected → first_frame → control_acquired → first_draw、チャットは shown_cached・reloaded）と、Mac の主スレッドの引っかかり（`main.hitch`。100 ms 以上ふさがった。`ms` がふさがっていた長さ、`mode` がそのとき開いていた画面）と止まり（`main.stall`。1.5 秒以上。`stage` が書き出したファイルの名前）、画面を開いた経路（`nav.open`。`mode` が経路で sidebar・board・palette・key・notification・attention・link・app・url・debug、`stage` が行き先の種類、`machine` が行き先のマシン。`AppModel.navigate(to:from:)` が 1 回の操作に 1 行を書く）、画面の中での会話の選び替え（`conversation.select`。`mode` が pill・beside・key、`pane` が会話の id）で、直近の 50 件は `/state` の `events` にも出る。集計は `scripts/perf/switch-report.py <ログ>...`（開き方・マシン・持ち越したかごとの段階の p50・p95 と、遅かった回。`--since 2026-10-06T18:00` で時刻を絞る）。

Mac のアプリは主スレッドが 1.5 秒より長く応答しないと、`/usr/bin/sample` で 2 秒ぶんの全スレッドのスタックを同じ `logs/` の `hang-<時刻>.txt` に書く（`MainThreadWatchdog`。新しい 10 個だけ残す。fixtures・test host・snapshot test は見張らない）。固まって強制終了した回は macOS が ips も spindump も残さないことがあるので、何で止まったかはこのファイルで見る。

iPhone・iPad のアプリも同じ見張りで `main.hitch` と `main.stall` を記録する（`sample` が無いのでスタックは書かず、`stage` は空）。背面にいる間は見張りを止め、前面に戻ってから数え直す（背面で止められた時間を止まりと数えない）。止まり（1.5 秒以上）と MetricKit の `MXHangDiagnostic`（OS が翌日までにまとめて届ける。スタックは止まった元のスレッドの、標本の多い枝の `<binary>+0x<offset>`）は、アプリの保存先に溜めてから接続先の全部の daemon に送り（`POST /v1/devices/current/diagnostics`。[daemon.md](daemon.md)）、daemon の logs に 1 件 1 行で残る。送れなかった分は次の起動か前面に戻ったときに送り直す。止まりは 1 時間に 10 件・溜まりは 50 件まで、7 日で捨てる。fixtures・test host・snapshot test は見張らないが、`--watchdog` を付けると fixtures でも見張る（下の `ios-hang-check.sh` が使う）。

### iPhone へ入れる前の止まりの確認

iPhone の実機に入れ替える前に、iOS シミュレータの -O のビルドで `scripts/ui/ios-hang-check.sh <udid> [port]` を回し、止まり 0 で終わることを確かめる（`lockf -t 7200 /tmp/taskboard-build.lock` で包む）。iPhone 17e と iPhone 18 Pro の 2 台で回す。会話の画面で主スレッドが止まり続けた条件（9r の段階 1 で直した、キーボードの後に下端への送り直しが終わらない不具合）を、1 回ずつアプリを起こし直して条件ごとに 5 回（`ROUNDS`）回す。

- `gen-focus`：生成中の会話（c-gen）で入力欄にフォーカスしてキーボードを出す
- `ask-focus`：問いのある会話（c-ask）で同じ
- `files-3lines`：c-files の入力欄を 1 行ずつ 3 行まで伸ばす
- `limit-stream`：c-limit に 1,500 件を流し込み、フォーカスしてから 30 秒間生成中の差分を流す
- `tools-to-ask`：c-tools でフォーカスしてから c-ask へ移ってフォーカスする

判定は debug の口の応答で行う。操作の 15 秒後から 5 秒の間に主スレッドの CPU 時間が 3,500 ms 以上増えたか、口が 3 秒で答えなければ止まりとし、1 回でもあれば 1 で終わる。1 回 1 行の JSON（`cpu5s`・下端への追従を止めた回数 `followLimit`・見張りの `stalls`）は `.build/ui/ios-hang-<udid>.jsonl` にも残る。`CONDITIONS=tools-to-ask` のように条件を絞れる。ビルドは「ビルド」の iOS の xcodebuild に `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s` を付けたもの（置き場は `.build/DerivedData-iOS`。`APP` で替える）。同じ Mac で並べて回すときは port を分ける（シミュレータはホストのポートを共有する）。

操作の速さは、-O のビルド（`build-mac.sh` と同じ置き場 `-derivedDataPath ../.build/DerivedDataOpt` と設定 `SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s`。worktree では `build-mac.sh` を回さず、同じ引数の xcodebuild だけを回す。`build-mac.sh` は `~/Applications` に写す）を `--scenario perf-many --debug-port <port>` で起こし、`/bench` を開き方ごとに 3 回ずつ回して比べる。`/bench` は 1 回ごとの画面の更新までの時間に加えて、同じ区間の主スレッドの CPU 時間を `cpu` に返す。ほかのビルドやテストで Mac が混んでいる間は、待たされた時間を含まない `cpu` の中央値で比べる（経過時間は同じ版でも 80〜110 ms と揺れた）。`perf-many` は案件 8 つ・タスク 600 件の fixtures で、`scripts/perf/make-many-fixture.py` が `stress.json` から作る。fixtures は 2 秒ごとに最初のセッションの状態を回すので、1 回ごとの値には揺れが入る。どこで時間を使っているかは、`/bench` を回している間に `xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 15s --output run.trace` で記録し、`scripts/perf/top-frames.py run.trace --module Taskboard` で main の thread の関数を並べる。直す前と比べるときは、`git worktree add --detach` で直す前の版を `$TMPDIR` の下に作り、同じ設定でビルドして交互に回す。測り終えたら、その worktree（中のビルドごと）を `git worktree remove` で消す。DerivedData の置き場は `DerivedData`（snapshot test）・`DerivedData-iOS`（`sync-strings.sh`）・`DerivedDataOpt`（-O）・`DerivedDataDevice`（実機）だけにし、測るための亜種を作らない（1 つ 2GB ほどあり、worktree ごとに増えて Mac の空きを埋めた）。

性能の関門は `scripts/perf-gate.sh [回数]`（既定 3 回。ほかと同じく `lockf -t 7200 /tmp/taskboard-build.lock` で包む。`BUILD=1` で先に -O でビルドする）。-O の fixtures のアプリを回ごとに裏で起こし直し、手順ごとに主スレッドの止まり（`/hitch`。本番の `main.hitch` と同じ 100 ms 超え）を数え、1 つでもあるか、スクロールの位置の確かめが外れたら 1 で終わる。手順は `scripts/perf/gate.py` にあり、会話の画面（既定は中央モーダル。`PRESENTATION` で替える）は、起こした直後に初めて c-tools を開く（`chat.open.cold`。パネルの外と上の帯を初めて組む回）・c-tools に 1,500 件（コード・表・長い段落・画像を含む）を流してもう一度開く・上端まで・下端まで・下端から小さなホイールと小さなトラックパッドのなでを続けて入れて引き戻されないか・生成中のスクロール・mouseMoved（生成中も）・入力欄に 4,000 字と 20,000 字を貼ってから 3 字打つ（`/conversation/fill` の insert）・セッションの状態の変化（`/bench` の session）・同じタスクの c-gen を右に並べる（`/task/split`。窓の会話の一覧が 2 つになったかを確かめる）・並べたまま c-tools を上端まで送って下端へ戻す、ボードの画面（列の形のホーム）は mouseMoved・スクロール・セッションの状態の変化・タスクの切り替え・開閉・サイドバーの切り替えと開閉、案件 8 つ・タスク 600 件（`perf-many`）でのサイドバーの切り替え（すべての案件と各案件の間を両方向に）。スクロールの手順は、表示の位置が期待どおり動いたかを毎回確かめる（動いていない一覧を測らない）。引き戻されないかは表示の位置（offset）で見る（fixtures は 2 秒ごとにセッションの状態を回し、一覧の上の帯を出し入れするので、下端までの距離は 40 pt ほど増減する）。本番の量の手順（`prod.*`）は、3 台の本番の state を伏せた fixtures（`prod-local+prod-studio+prod-third`。タスク 793 件・作業項目 1,062 件・会話 227 件。`scripts/fixtures/make-production.py` が作る。作った Mac だけに置き、repo には入れない（`.gitignore`）。無ければ関門は `prod.*` を飛ばす）で、ホームを見張り盤にして開いたまま受信箱の見回りと daemon の知らせ（`/fixture/flow`、1 秒に 2 通）が回る間・mouseMoved・サイドバーの切り替え・Studio の一番大きい案件のタスクの切り替えと開閉・会話の一番多いタスクの会話を全画面・中央モーダル・横に並べるで開き（600 件を流してから）、知らせが流れる間を測る（生成中の差分は流さない。流すと描き直しがまとまり、本番で会話を読んでいる間に出ていた止まりが出なくなる）。`ONLY=chat.scroll` のように手順の名前の頭で絞れる。最後に手順ごとの各回の止まりの数と最大を表にする。

会話の画面の入力とスクロールは `scripts/ui/chat-perf.sh [回数]` で測る（同じ -O のビルドを `.build/DerivedDataOpt` に置いてから）。実行ファイルを裏で直に起こし（前面に出さず、`open` を通さない）、窓を 1600×1000 にして後ろへ回し、タスクを「大きく表示」で開いて c-tools を 1,500 件にし、続けて生成中の差分を 8 秒流す（`MESSAGES`・`STREAM_SECONDS`・`CONVERSATION`・`PRESENTATION`・`SIDE_PANE_HIDDEN` で替える。本番で引っかかりが出た形は `PRESENTATION=modal CONVERSATION=c-gen`）。後ろの窓でも display link は届くが、フレームの間隔の上限は窓が載った画面の更新の速さ（60 Hz なら 16.7 ms、120 Hz なら 8.3 ms）で、回ごとに替わることがある。手順は次の 5 つで、1 行 1 手順の JSON を `scripts/ui/chat-perf-report.py` で表にする。

- `stream`：流し込んだ後に生成中の差分を流す間（1 回目だけ）。画面の更新間隔のほか、主スレッドの使用時間（`busy`）と body の回数（`bodies`。`ChatTranscript` は block の並びが変わったときだけ、Mac の一覧の行は `ChatRowHost.build` で、書きかけの行が見せる文が進むたびと、段落を書き終えて塊の行を組み直したときに数える）
- 待機（5 秒）
- `noop`：測る口だけを回す負荷
- `type`：入力欄の文を 1 字ずつ伸ばす（`POST /conversation/type`。80 ms おきに 120 字）
- `caret`：カーソルを 1 字ずつ動かす
- `scroll`：チャットの一覧にピクセル単位のホイールを 1 フレームずつ渡し、上へ 4,800 px 送る（`POST /conversation/scroll`。戻ると作ってある行を使い回すだけになるので戻らない）

打鍵の重さは、主スレッドの run loop が起きてから寝るまでの時間を打鍵の間ごとに足したもの（`perKeyP50Ms` など。display link に頼らない）。body の回数は DEBUG の数え口（`DebugCounters`）の打鍵 1 回あたり。fixtures が 2 秒ごとに回すセッションの状態で、`noop` でも 100〜200 ms の引っかかりが 10 秒に数回入るので、p95 と最大には揺れが入り、比べるのは中央値と body の回数にする。`PROFILE_STEP=type` で 1 回目のその手順の間だけ Time Profiler を記録し（`stream` は流し込みから生成中の差分の終わりまで）、`scripts/perf/frame-owners.py`（`--under` と `--count` で、指定した関数の中で通った数。`--min-burst 30` で 30 ms 以上続いた区間だけ）で SwiftUI の中の時間の持ち主を数える。

作業項目の欄は `python3 scripts/ui/work-perf.py [回数]` で測る（同じ -O のビルドを `.build/DerivedDataOpt` に置いてから）。fixtures `perf-work`（#301 に依存のある 300 件。`scripts/fixtures/make-perf-work.py` が `work-graph.json` から作る）のタスクを中央モーダルに開き、作業項目の欄を開く・項目の状態を変える（DEBUG だけの口 `POST /fixture/work` が、fixtures に作業項目を変えた知らせを流す）・右側の幅と欄の境目を動かす（取っ手と同じ値を `/defaults` で 16 ms ごとに書く）間の `/perf` を、1 行 1 手順の JSON で出す。回ごとにアプリを起こし直し、窓が載る画面（60 Hz か 120 Hz）も回ごとに替わるので、比べるのは同じ更新間隔の回どうしにする。`--no-notifications` は付けない（fixtures では効かず、`-ApplePersistenceIgnoreState YES` と一緒に付けると裏で起こしたアプリが窓を作らなかった）

複数行の欄（`MultilineTextField`）に長い文を入れたときの止まりは `python3 scripts/ui/fields-perf.py [--app APP] [--sizes 4000,20000] [--rounds 1] [--simulator UDID]` で測る（同じ -O のビルドを `.build/DerivedDataOpt` に置いてから。`--simulator` なら iPhone か iPad のシミュレータに `.build/DerivedData-iOS` の -O のビルドを入れて測る。文書の画面の 2 つの欄はシートの先で開けないので測らない）。欄ごとにアプリを起こし直して欄を開き、`/field/fill` で docs/development.md を繰り返した改行の混ざった文を一度に入れ、続けて 3 字を 80 ms おきに打つ。欄は `/fields` の並び順で選ぶので、直す前の版（TextField は名前を持たない）にも同じ欄で当てられる。1 行 1 回の JSON と、欄と字数ごとの中央値の表を出す。欄ごとのキーの決まり（↩・⇧↩・⌥↩・Esc・フォーカスが外れたときの確定）は `scripts/ui/check-fields.sh` で、会話の入力欄は `scripts/ui/check-composer.sh` で確かめる

`curl` の URL は `http://127.0.0.1:5790/...` と書く（`:5790/...` の省略形は curl が "No host part" で拒む）。`/screenshot` はプロセス内描画なので、`ScrollView` / `List` の中身（ボードの列・セッション一覧）も白く写る。見た目の確認はタスク画面（端末は写る）と snapshot test、iPhone シミュレータの `simctl io screenshot` で行う。

MCP server を人の手を借りずに叩くときは、`taskboard mcp` を stdio で起動して JSON-RPC（`initialize` → `notifications/initialized` → `tools/list` / `tools/call`）を 1 行ずつ流す。daemon が居ないと `tools/call` は `isError: true` で返り、stdout には JSON-RPC 以外を出さない（`TaskboardCLITests`）。

同一 Mac の daemon 以外に繋ぐときは `--daemon-url http://host:5780 --token-file <path>`（token は引数に書かない）。シミュレータはホストのファイルを読めるので、`--daemon-url http://127.0.0.1:5780 --token-file "$HOME/Library/Application Support/taskboard/token"` でホストの daemon に繋がる。

シミュレータは `xcrun simctl boot <udid>` → `install` → `launch <udid> uk.whatn.taskboard.ios --scenario sessions-basic --debug-port <port>` → `xcrun simctl io <udid> screenshot out.png`。iOS の `/screenshot` は無く、シートも `simctl io` で撮る。シミュレータの bundle ID は実機と同じ `uk.whatn.taskboard.ios`（APNs の鍵の team で送れるように。前の `uk.whatn.taskboard` で入れたアプリの接続先と設定は引き継がれないので、QR で追加し直す）。

README の画面（`docs/images`）は、架空のデータの fixtures `demo`・`demo-laptop`（`scripts/fixtures/make-demo.py` が作り、人・リポジトリ・パスに本物の値が残っていれば止まる）で `scripts/ui/demo-shots.sh` が撮る。先に `scripts/build-mac.sh` と iOS シミュレータのビルドを済ませる。Mac はアプリの中で描く `/screenshot` で撮り、サイドバーが出ていれば白い帯になるので切り落とす（`screencapture` は画面収録の許可が要り、macOS 27.2 に上げた後のこの Mac では断られた）。本物のデータの画面を README に載せない

iPhone・iPad の APNs（アプリを閉じているときの通知）は、シミュレータでも本物のトークンが届く（sandbox）。シミュレータの通知の許可のダイアログは `simctl` で押せないので、`--provisional-notifications` で起動するとダイアログ無しの仮の許可（provisional）で求める。仮の許可ではトークンは届くがバナーは出ない（通知センターにだけ入る）。バナーまで確かめるときは、シミュレータを止めて `data/Library/BulletinBoard/VersionedSectionInfo.plist` の `uk.whatn.taskboard.ios` の項目（NSKeyedArchiver の `BBSectionInfoSettings`）の `authorizationStatus` を 2、`alertType` を 1 にしてから起動し直す（P9 で実測）。通知は `xcrun simctl push <udid> uk.whatn.taskboard.ios payload.json` で出せる（`aps.category` を `taskboard.permission` にすると「許可」「拒否」が付く。値の名前は `PushPayload`）。押して答えるのは `/push/respond` で代える

## 依存の版

版は 2 つの Package.resolved に分けて固定する。

- 根の `Package.resolved`: SwiftPM（`swift build`・`swift test`）の分。`Package.swift` の依存だけが載る
- `App/Taskboard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`: Xcode（xcodebuild）の分。アプリだけが使うものも含めて全部が載る。xcodeproj は .gitignore 済みなので、このファイルだけを `git add -f` で追跡している（`xcodegen generate` は消さない）

1 つのファイルを共有していたときは、`swift test` が App だけの依存を落として書き直し、xcodebuild が全部を書き戻していた。落ちた依存は、書き戻すときに新しい版に上がることがあった（swift-issue-reporting が 2.1.2 になり、`sync-strings.sh` の iOS のビルドが止まった）。Xcode は、xcworkspace の分があれば根のファイルを読み書きしない。

両方にある package は、同じ版と revision にする（`PackageResolvedTests` が確かめる）。版を上げるときは、`Package.swift` か `App/project.yml` を直し、`swift package update <パッケージ>` で根を書き直す。そのあと、変わった pin を Xcode の分に写してから `xcodebuild -resolvePackageDependencies -project App/Taskboard.xcodeproj -scheme Taskboard` を回す（Xcode は、満たしている pin を変えない）。

| パッケージ | tag |
|---|---|
| hummingbird | 2.27.0 |
| hummingbird-websocket | 2.8.0 |
| swift-nio | 2.103.0 以上 |
| swift-argument-parser | 1.8.2 |
| swift-log | 1.15.1 以上 |
| swift-sdk（MCP） | 0.12.1 |
| GRDB | 7.11.1 |
| libghostty-spm（アプリのみ、`App/project.yml`） | 1.6.20261003 |
| swift-snapshot-testing（テストのみ、`App/project.yml`） | 1.19.6 |
| swift-markdown（アプリのみ、`App/project.yml`） | 0.9.0 |
| swift-cmark（swift-markdown の依存） | 0.9.0 |
