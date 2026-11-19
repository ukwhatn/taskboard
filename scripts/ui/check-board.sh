#!/bin/bash
# 全体のボードのカードを、見える位置まで送ってから押し、押したカードのタスクが開くかを確かめる（docs/ui-system.md「確かめ方」）。
# 押すのは列ごとに 1 枚目・見えている最後・「さらにN件」の中の 1 枚目（描かれた位置と押せる位置がずれるのは、列の端と面の端と開いた所）。ALL=1 で全カード
# アプリは前面に出さず、窓はほかの窓の後ろに置く。マウスとキーボードは動かさない（scripts/ui/lib.sh）ので、ほかの作業をしながら回せる。
# 既定は fixtures stress。SCENARIO= （空）で保存してある接続先（本物のデータ）。先に scripts/build-mac.sh でビルドしておく
#
#   scripts/ui/check-board.sh [幅] [高さ]   既定は 1728 × 1000
set -euo pipefail
source "$(dirname "$0")/lib.sh"
width=${1:-1728}
height=${2:-1000}
selected() { ui_get /state | python3 -c 'import json,sys; print(json.load(sys.stdin).get("selectedTask") or "")'; }

ui_launch
ui_frame "$width" "$height"
ui_capture "$out/board-$width.png"
ui_get /board/cards | ALL=${ALL:-} python3 -c '
import json, os, sys
d = json.load(sys.stdin); limit = d["limit"]
for column in d["columns"]:
    cards = column["cards"]
    if os.environ.get("ALL"):
        picks = cards
    else:
        picks = [cards[0], cards[min(limit, len(cards)) - 1]] + ([cards[limit]] if len(cards) > limit else [])
    for key in dict.fromkeys(picks): print(key)
' >"$out/cards.txt"

total=0; opened=0; failed=()
# 全カードを順に、キーのカーソルでそのカードまで送ってから押す。送られた位置は押すたびに変わるので、位置は毎回取り直す
while read -r key; do
    total=$((total + 1))
    ui_post /cursor "{\"key\": \"$key\"}" >/dev/null
    sleep 0.5
    if ! read -r _ x y w h ax ay aw ah < <("$probe" cards "$pid" | awk -v k="$key" '$1 == k' | head -1); then
        failed+=("$key → 描かれていない"); continue
    fi
    cx=$((x + w / 2)); cy=$((y + h / 2))
    # ボードの見えている範囲（サイドバーの右、題の帯の下）に中心が無ければ、送り切れていない
    if ! { [ "$cx" -gt "$ax" ] && [ "$cx" -lt $((ax + aw)) ] && [ "$cy" -gt "$ay" ] && [ "$cy" -lt $((ay + ah)) ]; }; then
        failed+=("$key（$cx,$cy）→ 見える位置まで送れない"); continue
    fi
    ui_post /click "{\"x\": $cx, \"y\": $cy}" >/dev/null
    sleep 0.5
    got=$(selected)
    if [ "$got" = "$key" ]; then
        opened=$((opened + 1))
    else
        failed+=("$key（$cx,$cy）→ ${got:-開かない}")
    fi
    ui_post /task/close >/dev/null
    sleep 0.4
done <"$out/cards.txt"

echo "幅 $width: カード $total 枚のうち $opened 枚が開いた（画像 $out/board-$width.png）"
for line in "${failed[@]+"${failed[@]}"}"; do echo "  開かない: $line"; done
[ ${#failed[@]} -eq 0 ]
