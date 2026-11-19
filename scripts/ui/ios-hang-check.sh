#!/bin/bash
# iPhone へ入れ替える前の関門（docs/development.md「iPhone へ入れる前の止まりの確認」）。会話の画面の止まりの再現条件
# （キーボードを出す・入力欄が伸びる・長い会話の生成中・会話の移り）を iOS シミュレータで回し、debug の口の応答で止まりを数える。
# 中身は ios-hang-check.py。シミュレータが起きていなければ起こし、終わったら起こした分だけ落とす。
#
#   scripts/ui/ios-hang-check.sh <udid> [port]   port の既定 5792（同じ Mac で並べて回すときは分ける。シミュレータはホストのポートを共有する）
#   ROUNDS（既定 5）は条件ごとの回数、CONDITIONS（既定は全部: gen-focus,ask-focus,files-3lines,limit-stream,tools-to-ask）、
#   APP（既定 .build/DerivedData-iOS の Debug-iphonesimulator のビルド。docs/development.md の -O のビルド）
#   終了コードは、止まりが 0 回なら 0、1 回でもあれば 1。1 回 1 行の JSON は .build/ui/ios-hang-<udid>.jsonl にも残す
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
udid=${1:?シミュレータの udid を渡す}
port=${2:-5792}
app=${APP:-$root/.build/DerivedData-iOS/Build/Products/Debug-iphonesimulator/Taskboard.app}
[ -d "$app" ] || { echo "ビルドが無い: $app" >&2; exit 2; }
mkdir -p "$root/.build/ui"
booted=
if ! xcrun simctl list devices | grep -q "$udid) (Booted)"; then
    xcrun simctl boot "$udid"
    booted=1
fi
trap '[ -n "$booted" ] && xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true' EXIT
python3 "$root/scripts/ui/ios-hang-check.py" "$udid" "$port" "$app" "${ROUNDS:-5}" \
    "${CONDITIONS:-gen-focus,ask-focus,files-3lines,limit-stream,tools-to-ask}" | tee "$root/.build/ui/ios-hang-$udid.jsonl"
