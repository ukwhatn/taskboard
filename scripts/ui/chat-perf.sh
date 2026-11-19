#!/bin/bash
# 会話の画面の入力とスクロールの重さを測る（CLAUDE.md「画面の滑らかさは -O のビルドで測る」）。fixtures の conversations の c-tools を 1,500 件にして、
# 待機・測る口だけ（noop）・1 字ずつの入力・カーソルの移動・チャットの縦のスクロールを回し、1 行 1 手順の JSON を出す。
# アプリは実行ファイルを裏で直に起こし、前面に出さない。窓はほかの窓の後ろに回す（後ろの窓でも display link は届く。2026-10-20 に実測）。
# マウスとキーボードは動かさない（入力は /conversation/type、スクロールはアプリの中で作ったホイールを渡す /conversation/scroll）。
#
#   scripts/ui/chat-perf.sh [回数]   既定 3 回。APP（既定 .build/DerivedDataOpt の -O のビルド。build-mac.sh と同じ置き場と設定）、PORT（既定 5794）
#   MESSAGES（既定 1500）は流し込む発言の数。0 なら fixtures の元の会話のまま。流し込んだ後に生成中の差分を STREAM_SECONDS（既定 8）秒流す（手順 stream）
#   CONVERSATION（既定 c-tools）は開く会話。PRESENTATION（既定 full）はタスクの開き方（side・full・modal）、SIDE_PANE_HIDDEN=1 で右の欄を隠す
#   PROFILE_STEP=type（noop・type・caret・scroll・stream）なら、1 回目のその手順の間だけ Time Profiler を記録して .build/ui/chat-perf-<手順>.trace に置く
#   （stream は流し込みから生成中の差分の終わりまで）
#   （scripts/perf/top-frames.py で main の thread の関数を並べる）
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
port=${PORT:-5794}
runs=${1:-3}
base="http://127.0.0.1:$port"
mkdir -p "$root/.build/ui"
post() { curl -sf -XPOST "$base$1" -d "${2:-{\}}"; }

"$app/Contents/MacOS/Taskboard" --debug-port "$port" --scenario conversations --no-notifications \
    -ApplePersistenceIgnoreState YES >"$root/.build/ui/chat-perf-$port.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$base/state" >/dev/null 2>&1 && break; sleep 0.2; done
post /window/order '{"back": true}' >/dev/null
# 右の欄が横に並ぶ幅で、タスクを全面に開く（1280 では右の欄が下に積まれ、会話の列が 140 px ほどになった）
post /window/frame '{"width": 1600, "height": 1000}' >/dev/null
post /window/order '{"back": true}' >/dev/null
post /presentation "{\"mode\": \"${PRESENTATION:-full}\"}" >/dev/null
# SIDE_PANE_HIDDEN=1 なら右の欄を隠す（タスクの画面の［右の欄を隠す］と同じ設定）
[ -n "${SIDE_PANE_HIDDEN:-}" ] && post /defaults '{"key": "taskPanel.detailsHidden", "value": true}' >/dev/null
post /navigate "{\"url\": \"taskboard://conversation/fixture-studio/${CONVERSATION:-c-tools}\"}" >/dev/null
sleep 2
# MESSAGES=0 なら流し込まず、fixtures の元の会話（20 件ほど）のまま測る
messages=${MESSAGES:-1500}
# 流し込んだ後に生成中の差分を STREAM_SECONDS（既定 8）秒流し、その間の画面の更新間隔を 1 回目の手順「stream」として出す
stream=
tracer=
if [ "${PROFILE_STEP:-}" = stream ] && [ "$messages" -gt 0 ]; then
    rm -rf "$root/.build/ui/chat-perf-stream.trace"
    xcrun xctrace record --template 'Time Profiler' --attach "$pid" --time-limit "$(( ${STREAM_SECONDS:-8} + 15 ))s" --output "$root/.build/ui/chat-perf-stream.trace" >/dev/null 2>&1 &
    tracer=$!
    sleep 3
fi
[ "$messages" -gt 0 ] && stream=$(post /bench/conversation "{\"messages\": $messages, \"chunk\": 10, \"streamSeconds\": ${STREAM_SECONDS:-8}, \"deltaMs\": 50}")
# 流し込んだ後の下端への寄せが落ち着くまで
sleep 3
if [ -n "$tracer" ]; then wait "$tracer" || true; fi

# 1 回目の PROFILE_STEP の間だけ Time Profiler を記録する
measure() {
    local run=$1 step=$2 path=$3 body=$4 tracer=
    if [ "$run" = 1 ] && [ "$step" = "${PROFILE_STEP:-}" ]; then
        rm -rf "$root/.build/ui/chat-perf-$step.trace"
        xcrun xctrace record --template 'Time Profiler' --attach "$pid" --time-limit 14s --output "$root/.build/ui/chat-perf-$step.trace" >/dev/null 2>&1 &
        tracer=$!
        sleep 3
    fi
    printf '{"run": %s, "step": "%s", "result": %s}\n' "$run" "$step" "$(post "$path" "$body")"
    if [ -n "$tracer" ]; then wait "$tracer" || true; fi
}

text="入力の重さを測るための文です。Claude Desktop と比べて、打鍵とカーソルの移動の間に一覧が走っていないかを見ます。ここまでで百二十字ほどの文になるように書き足していきます。"
[ -n "$stream" ] && printf '{"run": 1, "step": "stream", "result": %s}\n' "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])["stream"]))' "$stream")"
for run in $(seq "$runs"); do
    post /perf/start >/dev/null; sleep 5
    printf '{"run": %s, "step": "idle", "result": %s}\n' "$run" "$(post /perf/stop)"
    for step in noop type caret; do
        body=$(python3 -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "gapMs": 80, "noop": sys.argv[2] == "noop", "caret": sys.argv[2] == "caret"}))' "$text" "$step")
        measure "$run" "$step" /conversation/type "$body"
    done
    # 上へだけ送る（戻ると作ってある行を使い回すだけになる）。1 回で 4,800 px、3 回でまだ作っていない所を上がり続ける
    measure "$run" scroll /conversation/scroll '{"dy": 20, "steps": 240, "intervalMs": 16, "back": false}'

done
