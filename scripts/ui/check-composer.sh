#!/bin/bash
# Mac の会話の入力欄（MultilineTextField）が、↩ の送信・⇧↩ と ⌥↩ の改行・変換中の ↩・/ の候補のキー・Tab・下書きの持ち越し・高さを今までどおりに扱うかを確かめる。
# fixtures の conversations の会話をタスクのモーダルで開き、debug の口（/conversation/composer・/conversation/fill）でキーと文を入力欄の窓に直に渡す。
# マウス・キーボード・クリップボードと本物の入力メソッドは使わない。アプリは実行ファイルを裏で直に起こし、前面に出さない。
#
#   scripts/ui/check-composer.sh   APP（既定 .build/DerivedDataOpt の -O のビルド）、PORT（既定 5797）。撮った画面は .build/ui/composer-*.png
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
port=${PORT:-5797}
base="http://127.0.0.1:$port"
out="$root/.build/ui"
mkdir -p "$out"
post() { curl -sf -m 60 -XPOST "$base$1" -d "${2:-{\}}"; }
get() { curl -sf -m 60 "$base$1"; }
# JSON の値を 1 つ読む（python の式。d が JSON）
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
failures=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: 期待 [$3]、実際 [$2]"; failures=$((failures + 1)); fi
}
composer() { get /conversation/composer; }
key() { post /conversation/composer "{\"key\": \"$1\", \"modifiers\": ${2:-[]}}" >/dev/null; }
# 入力欄の文を打鍵と同じ経路で入れ替え、フォーカスを入力欄に置く
put() { post /conversation/composer "$(python3 -c 'import json,sys; print(json.dumps({"focus": True, "replace": sys.argv[1]}))' "$1")" >/dev/null; }
# 入力欄が送信を呼んだ回数（fixtures は書き込めないので、送信は発言を残さない）
submits() { composer | field 'd["submits"]'; }
# 入力欄の画面の上の位置（下端の y と高さ。左上が原点）
frame() { get /fields | field '" ".join(str(f["frame"]["y"] + f["frame"]["height"]) + " " + str(f["frame"]["height"]) for f in d["fields"] if f["name"] == "メッセージ")'; }

"$app/Contents/MacOS/Taskboard" --debug-port "$port" --scenario conversations --no-notifications \
    -ApplePersistenceIgnoreState YES >"$out/check-composer-$port.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do get /state >/dev/null 2>&1 && break; sleep 0.2; done
post /window/order '{"back": true}' >/dev/null
post /window/frame '{"width": 1600, "height": 1000}' >/dev/null
post /window/order '{"back": true}' >/dev/null
post /presentation '{"mode": "modal"}' >/dev/null
post /navigate '{"url": "taskboard://conversation/fixture-studio/c-tools"}' >/dev/null
sleep 3

check "開いたら入力欄にフォーカスがある" "$(composer | field 'd["firstResponder"]')" True
one=$(composer | field 'round(d["height"])')
post /screenshot >"$out/composer-empty.png"

put "こんにちは"
check "打った文が下書きに入る" "$(get /conversation/draft | field 'd["text"]')" "こんにちは"
key left
key return '["shift"]'
check "⇧↩ はカーソルの位置で改行し、送らない" "$(composer | field 'repr(d["text"])')" "'こんにち\\nは'"
key return '["option"]'
check "⌥↩ も改行する" "$(composer | field 'd["text"].count(chr(10))')" 2
check "3 行で欄が高くなる" "$(composer | field "round(d['height']) > $one")" True
post /screenshot >"$out/composer-lines.png"

put "$(python3 -c 'print("\n".join(f"行{i}" for i in range(12)))')"
six=$(composer | field 'round(d["height"])')
check "12 行でも 6 行の高さで止まり、中でスクロールする" "$(composer | field "round(d['height']) < round(d['documentHeight']) and $six <= $one * 6 + 1")" True

put "かな"
post /conversation/composer '{"mark": "にほんご"}' >/dev/null
check "変換中の文が入る" "$(composer | field 'd["marked"]')" True
before=$(submits)
key return
check "変換中の ↩ は確定だけして送らない" "$(composer | field 'd["text"] + str(d["marked"])')" "かなにほんごFalse"
check "変換中の ↩ で送信を呼ばない" "$(submits)" "$before"

put "/rev"
key down
key return
check "/ の候補で ↓ と ↩ は 2 つめの候補を選んで補う" "$(composer | field 'repr(d["text"])')" "'/pr-review '"
put "/rev"
before=$(submits)
key return
check "/ の候補が出ている間の ↩ は送らない" "$(submits)" "$before"
put "/rev"
key escape
check "/ の候補の Esc は候補だけ閉じる（タスクの画面は開いたまま）" "$(get /state | field 'd["selectedTask"]')" "fixture-studio/137"
key return
check "候補を閉じた後の ↩ は送信を呼ぶ" "$(submits)" "$((before + 1))"

put "送る文"
before=$(submits)
key return
check "↩ は送信を呼び、改行を入れない" "$(submits)$(composer | field 'repr(d["text"])')" "$((before + 1))'送る文'"
key return '["command"]'
check "⌘↩ は入力欄では送らず改行も入れない" "$(submits)$(composer | field 'repr(d["text"])')" "$((before + 1))'送る文'"

put "持ち越す文"
post /presentation '{"mode": "side"}' >/dev/null
sleep 2
check "開き方を替えて作り直しても下書きが残る" "$(composer | field 'd["text"]')" "持ち越す文"
post /presentation '{"mode": "modal"}' >/dev/null
sleep 2
post /conversation/composer '{"focus": true}' >/dev/null
key tab
check "Tab はフォーカスを次へ送り、文に入れない" "$(composer | field 'str(d["firstResponder"]) + repr(d["text"])')" "False'持ち越す文'"

# 会話を直に開いた画面（横の開き方）の縦の並びは、入力欄の行に最小の高さだけを提案する。外の枠が伸びないと欄が枠の上下にはみ出す。
# 枠は下に寄せてあるので、枠の最小の高さを超えた後は、行が増えても欄の下端は動かない（はみ出すと伸びた分の半分下がる。3 行から 5 行で 16pt。下の並びのほかの要素が数 pt 動くことがあるので 5pt まで許す）
post /presentation '{"mode": "side"}' >/dev/null
post /navigate '{"url": "taskboard://conversation/fixture-studio/c-tools"}' >/dev/null
sleep 3
for lines in 3 5; do
    put "$(python3 -c "print('\\n'.join(f'行{i}' for i in range($lines)))")"
    sleep 0.5
    read -r bottom height <<<"$(frame)"
    eval "bottom$lines=$bottom height$lines=$height"
done
check "会話を直に開いた画面で、入力欄の枠が文に合わせて伸びる" "$(python3 -c "print($height5 > $height3 and abs($bottom5 - $bottom3) < 5)")" True
post /screenshot >"$out/composer-conversation-lines.png"

echo "失敗 $failures 件"
exit "$failures"
