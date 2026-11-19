部品 1 つ。共通の欄は id・kind・place・bind で、ほかの欄は kind ごとに同じ階層に並べる。会話が渡すのは意味だけで、色・書体・余白はアプリが決める。
- place（置く場所）: band（タスクの見出しの下の 1 行。gauge を 4 個まで）・head（会話の一覧の上。table・plan・diagram・chart・html のどれか 1 つ。高さは会話の 3 分の 1 までで、超えた分は中で送る）・composer（入力欄の上。draft を 2 件まで）・side（右の欄。head と同じ種類を 1 つ。人が開くまで閉じている）。省くと head
- tone（状態の種類）: ok・attention・waiting・done・failed・neutral。強い色になるのは attention と failed だけなので、基準の外の値にだけ使う
- symbol（記号）: check・clock・person・people・document・chart・flag・warning・calendar・link・pull_request・bug・gear・mail・chat・lock・money・server・test・deploy
- open（押したときに開く対象）: {"task": 番号}・{"doc": 文書の id}・{"url": "https://…"} のどれか 1 つ

kind ごとの欄:
- gauge（計器。band に置く）: label（40 字）、value（画面に表示する値、20 字）、amount（数）、basis（基準。{"kind": "denominator|limit|deadline|previous", "value": "6", "amount": 6}）、tone、symbol、note（補足 1 行、120 字）。値には必ず基準を添える。amount と basis.amount が両方あればバーを描く。bind を付けると value・amount・basis・tone は taskboard の今の値になる（work は「済み / 全体」、questions は件数）
- table（一覧と表）: title、columns（5 列まで）、rows（50 行まで。{"cells": [...], "tone", "symbol", "open"}。セルは 1 行で 20 字まで）。画面は 8 行を超えた分を「ほか N 件」に折りたたむ。bind を付けると列と行は taskboard の今の値になる
- plan（計画）: title、groups（表示するまとまり。省くと全部）。作業項目に紐づき、まとまり（work_add の group）ごとに「6 / 12」と表を描く。今のまとまりだけを開き、済んだまとまりは 1 行に折りたたむ。値は渡さない
- diagram（図）: style（flow・timeline・compare・relation）、title、nodes（12 個まで。{"id", "label", "note", "tone", "at", "values", "recommended", "open"}）。flow は段の並び、timeline は at（「12/1」）つきの出来事、compare は columns（列の見出し）と各 node の values（列と同じ数）で比べ、推奨の選択肢に recommended、relation は edges（{"from", "to", "label"}。from と to は node の id）
- chart（グラフ）: style（bar・line）、title、unit、series（4 系列まで。{"name", "points": [{"x": "11/18", "y": 12}]}。点は全部で 50 個まで）、target（基準の線の値）、target_label
- draft（送る文面。composer に置く）: title、to（宛先と名義、200 字）、body（本文、4,000 字）、checks（検査の結果。{"label": "敬体", "ok": true, "note"}）。利用者は本文を編集してから［承認］し、承認と本文が「taskboard で送る文面を承認しました」で届く。送るのは会話で、taskboard は送らない。同じ文面を AskUserQuestion で重ねて問わない
- html（自由。1 個 20,000 字まで）: title、html。上の部品で表せないときだけ使う。script・イベントの属性・外部の読み込み（画像・CSS・フォント・iframe）は誤りで返る。色と余白は直接書かず、次の変数とクラスで組む（直接書くと受け付けたうえで注意が返る）
  - 色: var(--tb-text)・--tb-secondary・--tb-muted・--tb-surface・--tb-raised・--tb-fill・--tb-border・--tb-accent・--tb-attention・--tb-failed
  - 余白: var(--tb-space-inline)・--tb-space-row・--tb-space-block・--tb-space-section。角丸: var(--tb-radius-box)・--tb-radius-card
  - クラス: tb-h（見出し）、tb-table（表）、tb-gauges と tb-gauge（計器の並び。中に tb-gauge-label・tb-gauge-value・tb-gauge-note）、tb-badge（状態の札。tb-ok・tb-attention・tb-waiting・tb-done・tb-failed・tb-neutral と組む）、tb-muted（補足の文）、tb-row（横に並べる）

bind（紐づけ先）の source:
- work: 作業項目（plan、計器の「6 / 12」、表）。group でまとまりを選ぶ
- links: リンクした PR・issue の状態・CI・レビュー
- children: 子のタスク（この会話が起動した委譲先のタスク）の帯の 1 文と列
- watches: 監視の状態
- questions: このタスクの未回答の問い（文書の質問と会話の問い）
