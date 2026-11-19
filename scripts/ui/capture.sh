#!/bin/bash
# 実ウィンドウを幅ごとに撮る（docs/ui-system.md「確かめ方」）。`List` を使う画面（サイドバー、一覧、設定）は snapshot test に写らないので、これで見る。
# アプリは前面に出さず、窓はほかの窓の後ろに置く。マウスとキーボードは動かさない（scripts/ui/lib.sh）。
#
#   scripts/ui/capture.sh <名前> [taskboard://…] [幅…]   例: scripts/ui/capture.sh task taskboard://task/fixture-studio/137 1280 1728
#   SCENARIO（既定 stress。空で本物のデータ）、APPEARANCE（light / dark / system、既定 system）、HEIGHT（既定 1000）。先に scripts/build-mac.sh でビルドしておく
set -euo pipefail
source "$(dirname "$0")/lib.sh"
name=${1:?名前が要る}
shift
url=
if [[ ${1:-} == taskboard://* ]]; then url=$1; shift; fi
if [ $# -gt 0 ]; then widths=("$@"); else widths=(1280 1728 2560); fi

ui_launch
ui_post /appearance "{\"scheme\": \"${APPEARANCE:-system}\"}" >/dev/null
if [ -n "$url" ]; then ui_post /navigate "{\"url\": \"$url\"}" >/dev/null; fi
for width in "${widths[@]}"; do
    ui_frame "$width" "${HEIGHT:-1000}"
    ui_capture "$out/$name-$width.png"
    echo "$out/$name-$width.png"
done
