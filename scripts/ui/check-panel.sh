#!/bin/bash
# タスクのパネルを開き方 4 種（サイドビュー・全面・中央モーダル・別ウィンドウ）と幅 3 種で撮り、文書の画面も撮る（docs/ui-system.md「確かめ方」）。
# 撮った画像を見て崩れを確かめる。あわせて、パネルの右上の「閉じる」がパネルの中に描かれているか（押し広げられて外に出ていないか）を読み上げの木で確かめる。
# アプリは前面に出さず、窓はほかの窓の後ろに置く。マウスとキーボードは動かさない（scripts/ui/lib.sh）。先に scripts/build-mac.sh でビルドしておく
#
#   scripts/ui/check-panel.sh [タスクの番号] [文書の id]   既定は fixtures stress の #200（長い題と長い待ち理由）と文書 1
set -euo pipefail
source "$(dirname "$0")/lib.sh"
number=${1:-200}
doc=${2:-1}
widths=(1280 1728 2560)

ui_launch
machine=$(ui_get /board/cards | python3 -c 'import json,sys; print(json.load(sys.stdin)["columns"][0]["cards"][0].split("/")[0])')
open_task() { ui_post /navigate "{\"url\": \"taskboard://task/$machine/$number\"}" >/dev/null; sleep 1; }

failed=()
for mode in side full modal; do
    ui_post /presentation "{\"mode\": \"$mode\"}" >/dev/null
    for width in "${widths[@]}"; do
        ui_frame "$width" 1000
        open_task
        ui_capture "$out/panel-$mode-$width.png"
        # 「閉じる」のボタン（パネルの右上と帯）が、どれも窓の中に描かれているか
        read -r _ wx wy ww wh < <("$probe" window "$pid")
        # パネルの最小の高さが窓に伝わると、開いたタスクの長い文で窓が画面より高く伸びる（TaskPanel の根の minHeight）。
        # 窓が伸びずに中身がはみ出したときは、下の「閉じる」の検査で上下の端を見る
        [ "$wh" = 1000 ] || failed+=("$mode $width: 窓の高さが ${wh} に変わった")
        if ! "$probe" elements "$pid" | awk -F'\t' -v r=$((wx + ww)) -v t="$wy" -v b=$((wy + wh)) '$2 == "AXButton" && $3 == "閉じる" { n++; if ($4 + $6 > r + 1 || $5 < t - 1 || $5 + $7 > b + 1) bad = 1 } END { exit (bad || n == 0) }'; then
            failed+=("$mode $width: 閉じるが窓の外か、見つからない")
        fi
        echo "$out/panel-$mode-$width.png"
    done
done

# 文書の画面（全面のパネルの中と、別ウィンドウ）
ui_post /presentation '{"mode": "full"}' >/dev/null
ui_frame 1728 1000
open_task
ui_post /doc/open "{\"id\": $doc, \"number\": $number}" >/dev/null
sleep 1
ui_capture "$out/document-full-1728.png"
echo "$out/document-full-1728.png"
ui_post /doc/close >/dev/null
ui_post /task/close >/dev/null

# 別ウィンドウ（題は「#番号 題」）
ui_post /window/open "{\"task\": $number}" >/dev/null
sleep 1.5
title=$(ui_get /menu | python3 -c 'import json,sys; print(next((w for w in json.load(sys.stdin)["windows"] if w.startswith("#")), ""))')
if [ -z "$title" ]; then
    failed+=("別ウィンドウが開かない")
else
    # 開いた直後は既定の大きさ（TaskboardApp の defaultSize の高さ 760）のまま
    read -r _ _ _ _ wh < <("$probe" window "$pid" "#$number")
    [ "$wh" = 760 ] || failed+=("別ウィンドウ: 開いた直後の高さが ${wh}")
    for width in 900 1280; do
        ui_post /window/frame "{\"width\": $width, \"height\": 900, \"title\": \"$title\"}" >/dev/null
        ui_post /window/order '{"back": true}' >/dev/null
        sleep 1
        ui_capture "$out/panel-window-$width.png" "#$number"
        echo "$out/panel-window-$width.png"
    done
    ui_post /window/close "{\"title\": \"$title\"}" >/dev/null
fi

for line in "${failed[@]+"${failed[@]}"}"; do echo "  崩れ: $line"; done
[ ${#failed[@]} -eq 0 ]
