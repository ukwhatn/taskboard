# scripts/ui の共通の手順（source して使う）。docs/ui-system.md「確かめ方」。
# アプリを別に起動し、窓を作らせるために 1 度だけ前面に出してから、前面を元のアプリに返し、窓はほかの窓の後ろへ回す。
# マウスとキーボードは動かさない。押す・送るはアプリの debug の口（/click・/cursor・/key）で、アプリの中でイベントを作って渡す。
#
# 変数: PORT（既定 5792）、SCENARIO（既定 stress。空にすると保存してある接続先＝本物のデータ）、APP、OUT、
#       EXTRA_ARGS（足す起動引数。例: "--daemon-url=http://127.0.0.1:5797 --token-file=<path>"。値は = でつなぐ）
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
app=${APP:-$root/.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app}
out=${OUT:-$root/.build/ui}
port=${PORT:-5792}
probe="$out/uiprobe"
mkdir -p "$out"
[ "$probe" -nt "$root/scripts/ui/uiprobe.swift" ] || swiftc -O -o "$probe" "$root/scripts/ui/uiprobe.swift"

ui_post() { curl -sf -XPOST "http://127.0.0.1:$port$1" -d "${2:-{\}}"; }
ui_get() { curl -sf "http://127.0.0.1:$port$1"; }

ui_launch() {
    local scenario=${SCENARIO-stress}
    # 保存された窓の状態を読まず、書かない（同じ bundle ID のユーザーのアプリと共有していて、窓の無い状態が残ると主ウィンドウが開かなかった）
    local args=(--debug-port "$port" --no-notifications -ApplePersistenceIgnoreState YES)
    [ -n "$scenario" ] && args+=(--scenario "$scenario")
    # shellcheck disable=SC2206
    [ -n "${EXTRA_ARGS:-}" ] && args+=($EXTRA_ARGS)
    "$app/Contents/MacOS/Taskboard" "${args[@]}" >"$out/app-$port.log" 2>&1 &
    pid=$!
    trap 'kill $pid 2>/dev/null || true' EXIT
    for _ in $(seq 50); do ui_get /state >/dev/null 2>&1 && break; sleep 0.2; done
    # 後ろで起動したアプリは、前面に出るまで最初の窓を作らない（2026-10-06 に実測。fixtures でも NSApp.windows が空のままだった）
    local front
    front=$(lsappinfo info -only bundleID "$(lsappinfo front)" | sed -E 's/.*"CFBundleIdentifier"="([^"]*)".*/\1/')
    open -a "$app"
    for _ in $(seq 50); do [ "$(ui_windows)" -gt 0 ] && break; sleep 0.2; done
    [ -n "$front" ] && open -b "$front"
    # 本物のデータは接続して読み込むまで待つ
    if [ -n "$scenario" ]; then sleep 1.5; else sleep 6; fi
    # 確かめ方は列の形のホーム（カードの並び・/board/cards・/board/scroll）を前提にする。見張り盤を見るときは HOME_LAYOUT=conversations
    ui_post /home/layout "{\"layout\": \"${HOME_LAYOUT:-columns}\"}" >/dev/null
    ui_post /window/order '{"back": true}' >/dev/null
}

# 見えている主ウィンドウの数
ui_windows() { ui_get /menu | python3 -c "import json,sys; print(len(json.load(sys.stdin)['windows']))" 2>/dev/null || echo 0; }

# 窓の大きさを変え、後ろへ回し直す
ui_frame() {
    ui_post /window/frame "{\"width\": $1, \"height\": $2}" >/dev/null
    ui_post /window/order '{"back": true}' >/dev/null
    sleep 1
}

# 窓を撮る（ほかの窓の後ろにあっても、窓の番号で撮れる）。2 つめの引数は窓の題の先頭（省くと主ウィンドウ）
ui_capture() {
    local wid
    read -r wid _ < <("$probe" window "$pid" ${2:+"$2"})
    screencapture -x -o -l "$wid" "$1"
}
