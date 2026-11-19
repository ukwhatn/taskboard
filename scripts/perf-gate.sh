#!/bin/bash
# 性能の関門。-O の fixtures のアプリで、人が普通に使う操作（起こした直後と 2 回目に長い会話を開く・端までのスクロール・下端の近くの小さなスクロール・生成中のスクロール・
# マウスの移動の代わりの mouseMoved・入力欄の長い下書き・セッションの状態の変化・会話を 2 つ並べる・並べたままのスクロール・ボードの操作・タスクの開閉・サイドバーの開閉と切り替え（案件 8 つでも））を回し、手順ごとに主スレッドの止まり
# （本番の main.hitch と同じ 100 ms 超え）を数える。止まりが 1 つでもあるか、スクロールの位置が期待どおり動かない・下端へ引き戻されると 1 で終わる。
# 手順の中身は scripts/perf/gate.py。アプリは回ごとに実行ファイルを裏で直に起こし直し、窓はほかの窓の後ろに回す。マウスとキーボードは動かさない。
# ほかのビルドが動いている間の値は比べない（CLAUDE.md「画面の滑らかさは -O のビルドで測る」）。
#
#   scripts/perf-gate.sh [回数]   既定 3 回。BUILD=1 なら先に -O でビルドする（build-mac.sh と同じ引数・置き場。アプリは入れ替えない）
#   APP（既定 .build/DerivedDataOpt の -O のビルド）、PORT（既定 5795）、ONLY（手順の名前の頭。chat.scroll など）、
#   PRESENTATION（既定 modal。タスクの開き方）、VERBOSE=1 で口の生の結果も出す
#   ビルドとテストは共通のロックで 1 本ずつ回す: lockf -t 7200 /tmp/taskboard-build.lock scripts/perf-gate.sh
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
port=${PORT:-5795}
runs=${1:-3}
out="$root/.build/ui"
mkdir -p "$out"

if [ -n "${BUILD:-}" ]; then
    (cd "$root/App" && xcodegen generate >/dev/null && xcodebuild -project Taskboard.xcodeproj -scheme Taskboard -destination 'platform=macOS' -configuration Debug \
        -derivedDataPath ../.build/DerivedDataOpt -quiet SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s build)
fi

args=(--app "$app" --log "$out/perf-gate-$port.log" --port "$port" --runs "$runs" --presentation "${PRESENTATION:-modal}" --only "${ONLY:-}")
[ -n "${VERBOSE:-}" ] && args+=(--verbose)
python3 "$root/scripts/perf/gate.py" "${args[@]}"
