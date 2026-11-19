#!/bin/bash
# 全体のボードの滑らかさを測る（CLAUDE.md「画面の滑らかさは -O のビルドで測る」）。窓 1512×945 で、待機・縦のスクロール・カーソルの移動・パネルの開閉。
# 結果は 1 行 1 手順の JSON（hitchRatio は遅れた時間 / 全体の時間 ms/s、hitches は引っかかりの回数、maxMs は最大のフレーム）。
# 1 回の値はばらつくので、同じ手順を 3 回回して比べる。ほかのアプリが重いと値が大きく揺れる（同じ版の待機で 12〜170 ms/s を見た）。
# 隠れた窓は描画が止まるので、この計測だけは窓をほかの窓の前に出す（アプリは前面に出さず、マウスとキーボードは動かさない）。
#
#   scripts/ui/perf.sh [回数]   既定 3 回。SCENARIO（既定は空で本物のデータ）=stress で fixtures。
#   本物のデータではパネルの開閉を測らない（タスクを開かない）
set -euo pipefail
SCENARIO=${SCENARIO-}
PORT=${PORT:-5793}
source "$(dirname "$0")/lib.sh"
runs=${1:-3}
post() { ui_post "$@"; }

ui_launch
post /window/frame '{"width": 1512, "height": 945}' >/dev/null
post /window/order '{"back": false}' >/dev/null
# 最初の描画が落ち着くまで
sleep 4

measure() {
    local name=$1; shift
    post /perf/start >/dev/null
    "$@"
    printf '{"run": %s, "step": "%s", "result": %s}\n' "$run" "$name" "$(post /perf/stop)"
}
idle() { sleep 8; }
scroll() { post /board/scroll '{"dy": 30, "steps": 120, "interval": 16}' >/dev/null; }
cursor() { for i in $(seq 40); do post /cursor/move '{"direction": "down"}' >/dev/null; post /cursor/move '{"direction": "right"}' >/dev/null; done; }
panel() { for i in $(seq 10); do post /navigate '{"url": "taskboard://task/fixture-studio/137"}' >/dev/null; sleep 0.4; post /task/close >/dev/null; sleep 0.4; done; }

for run in $(seq "$runs"); do
    measure idle idle
    measure scroll scroll
    measure cursor cursor
    if [ -n "${SCENARIO:-}" ]; then measure panel panel; fi
done
