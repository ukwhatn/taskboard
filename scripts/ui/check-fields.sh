#!/bin/bash
# Mac の複数行の欄（MultilineTextField）のキーの決まりが、欄ごとに TextField のときと同じかを確かめる。
# fixtures では書き込めず開けない欄（題とメモのその場の編集・コメント・返信・待ち理由）を、debug の口の測りの欄の窓（POST /lab/field）に部品のまま開き、
# 文は /field/fill で、キーは /field/key で窓に直に渡す。確定・取り消し・送信は GET /lab/field の記録で見る。マウス・キーボード・クリップボードは使わない。
#
#   scripts/ui/check-fields.sh   APP（既定 .build/DerivedDataOpt の -O のビルド）、PORT（既定 5798）
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
port=${PORT:-5798}
base="http://127.0.0.1:$port"
out="$root/.build/ui"
mkdir -p "$out"
post() { curl -sf -m 60 -XPOST "$base$1" -d "${2:-{\}}"; }
get() { curl -sf -m 60 "$base$1"; }
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
failures=0
check() {
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: 期待 [$3]、実際 [$2]"; failures=$((failures + 1)); fi
}
# 測りの欄を開き直し、欄にフォーカスを置いて文を入れる
index=0
open() {
    post /lab/field "{\"kind\": \"$1\", \"width\": 400}" >/dev/null
    index=$(get /fields | field '[i for i, f in enumerate(d["fields"]) if f["window"] == "測りの欄"][0]')
    post /field/fill "$(python3 -c 'import json,sys; print(json.dumps({"index": int(sys.argv[1]), "text": sys.argv[2], "settleMs": 300, "keep": True}))' "$index" "$2")" >/dev/null
}
key() { post /field/key "{\"index\": $index, \"key\": \"$1\", \"modifiers\": ${2:-[]}}" >/dev/null; }
events() { get /lab/field | field '",".join(d["events"])'; }
# 測りの欄の窓の欄の字数
text() { get /fields | field '[f for f in d["fields"] if f["window"] == "測りの欄"][0]["chars"]'; }

"$app/Contents/MacOS/Taskboard" --debug-port "$port" --scenario stress --no-notifications \
    -ApplePersistenceIgnoreState YES >"$out/check-fields-$port.log" 2>&1 &
pid=$!
trap 'post /lab/field "{\"close\": true}" >/dev/null 2>&1 || true; kill $pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do get /state >/dev/null 2>&1 && break; sleep 0.2; done
post /window/order '{"back": true}' >/dev/null

# その場の編集（題・メモ。複数行の欄）: ↩ は確定、⇧↩ と ⌥↩ は改行、Esc は取り消し、フォーカスが外れたら確定（text は字数）
for kind in title memo; do
    open $kind "文"
    key return
    check "$kind: ↩ は確定する" "$(events)" "commit"
    open $kind "文"
    key return '["shift"]'
    key return '["option"]'
    check "$kind: ⇧↩ と ⌥↩ は改行し、確定しない" "$(events)$(text)" "3"
    key escape
    check "$kind: Esc は取り消す" "$(events)" "cancel"
    open $kind "文"
    post /field/focus "{\"index\": $index, \"resign\": true}" >/dev/null
    sleep 0.3
    check "$kind: フォーカスが外れたら確定する" "$(events)" "commit"
done

# コメント・返信: ⇧↩ と ⌥↩ は改行、↩ は何もしない（送信はボタン）
for kind in comment reply; do
    open $kind "文"
    key return '["shift"]'
    key return '["option"]'
    check "$kind: ⇧↩ と ⌥↩ は改行する" "$(text)" "3"
    key return
    check "$kind: ↩ は送らず、改行も入れない" "$(events)$(text)" "3"
done

# 待ち理由: ↩ と ⇧↩ は保存、⌥↩ は改行、Esc は取り消し
open blocker "理由"
key return
check "blocker: ↩ は保存する" "$(events)" "save"
open blocker "理由"
key return '["shift"]'
check "blocker: ⇧↩ も保存する（改行しない）" "$(events)" "save"
open blocker "理由"
key return '["option"]'
check "blocker: ⌥↩ は改行し、保存しない" "$(events)$(text)" "3"
key escape
check "blocker: Esc は取り消す" "$(events)" "cancel"

echo "失敗 $failures 件"
exit "$failures"
