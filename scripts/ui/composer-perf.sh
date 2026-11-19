#!/bin/bash
# 会話の入力欄に長い文を一度に入れたとき（貼り付け）と、その後に 1 字ずつ足したときの主スレッドの止まりを測る（CLAUDE.md「画面の滑らかさは -O のビルドで測る」）。
# fixtures の conversations の会話をタスクのモーダルで開き、字数（SIZES）と文の種類（KINDS）ごとに POST /conversation/fill を回して、1 行 1 回の JSON を出す。
# アプリは実行ファイルを裏で直に起こし、前面に出さない。マウスとキーボードとクリップボードは使わない。
#
#   scripts/ui/composer-perf.sh [回数]   既定 3 回。APP（既定 .build/DerivedDataOpt の -O のビルド）、PORT（既定 5795）
#   SIZES（既定 "1000 4000 20000"）、KINDS（既定 "ja en doc"。ja は日本語、en は英数、lines は日本語を 80 字ごとに改行、
#   doc は docs/development.md の頭から（日本語・英数・記号・改行が混ざった、貼り付けに近い文。足りなければ繰り返す））
#   THEN（既定「あいうえおかきくけこ」）は入れた後に 1 字ずつ足す文
#   PROFILE=1 なら 1 回目の間だけ Time Profiler を記録して .build/ui/composer-perf.trace に置く（scripts/perf/top-frames.py で main の thread の関数を並べる）
#   PRESENTATION（既定 modal）、CONVERSATION（既定 c-tools）、INSERT=1 で文を入力欄の insertText で入れる（打鍵・貼り付けと同じ経路。TextField の版では効かない）
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
port=${PORT:-5795}
runs=${1:-3}
base="http://127.0.0.1:$port"
mkdir -p "$root/.build/ui"
post() { curl -sf -m 600 -XPOST "$base$1" -d "${2:-{\}}"; }

"$app/Contents/MacOS/Taskboard" --debug-port "$port" --scenario conversations --no-notifications \
    -ApplePersistenceIgnoreState YES >"$root/.build/ui/composer-perf-$port.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -sf "$base/state" >/dev/null 2>&1 && break; sleep 0.2; done
post /window/order '{"back": true}' >/dev/null
post /window/frame '{"width": 1600, "height": 1000}' >/dev/null
post /window/order '{"back": true}' >/dev/null
post /presentation "{\"mode\": \"${PRESENTATION:-modal}\"}" >/dev/null
post /navigate "{\"url\": \"taskboard://conversation/fixture-studio/${CONVERSATION:-c-tools}\"}" >/dev/null
sleep 3
tracer=
if [ -n "${PROFILE:-}" ]; then
    rm -rf "$root/.build/ui/composer-perf.trace"
    xcrun xctrace record --template 'Time Profiler' --attach "$pid" --time-limit "${PROFILE_SECONDS:-30}s" --output "$root/.build/ui/composer-perf.trace" >/dev/null 2>&1 &
    tracer=$!
    sleep 3
fi

for run in $(seq "$runs"); do
    for kind in ${KINDS:-ja en doc}; do
        for size in ${SIZES:-1000 4000 20000}; do
            body=$(python3 - "$kind" "$size" "$root/docs/development.md" <<'EOF'
import json, os, sys
kind, size = sys.argv[1], int(sys.argv[2])
unit = {"en": "The quick brown fox jumps over the lazy dog 0123456789. ", "doc": open(sys.argv[3]).read()}.get(kind, "入力欄に長い文を貼ったときの重さを測るための日本語の文です。")
text = (unit * (size // len(unit) + 1))[:size]
if kind == "lines":
    text = "\n".join(text[i:i + 80] for i in range(0, len(text), 80))[:size]
print(json.dumps({"text": text, "settleMs": 3000, "then": os.environ.get("THEN", "あいうえおかきくけこ"), "gapMs": 80, "insert": os.environ.get("INSERT") == "1"}))
EOF
)
            printf '{"run": %s, "kind": "%s", "size": %s, "result": %s}\n' "$run" "$kind" "$size" "$(post /conversation/fill "$body")"
            sleep 1
        done
    done
done
if [ -n "$tracer" ]; then wait "$tracer" || true; fi
