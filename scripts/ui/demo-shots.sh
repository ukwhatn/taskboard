#!/bin/bash
# README の画面（docs/images）を、架空のデータの fixtures（scripts/fixtures/make-demo.py）で撮り直す。
# Mac はアプリの中で描く /screenshot で撮る（screencapture は画面収録の許可が要る）。/screenshot はサイドバーの material を描かないので、
# サイドバーが出ていて無地の帯になったときはその幅を切り落とす。iPhone はシミュレータで撮る。
#
#   scripts/ui/demo-shots.sh            先に scripts/build-mac.sh と iOS シミュレータのビルド（scripts/sync-strings.sh と同じ置き場）を済ませておく
#   SIMULATOR（既定 iPhone 18 Pro の名前）、WIDTH（既定 1760）、HEIGHT（既定 1000）
set -uo pipefail
export SCENARIO=demo+demo-laptop PORT=${PORT:-5793}
source "$(dirname "$0")/lib.sh"
images="$root/docs/images"

ui_launch >/dev/null 2>&1
ui_frame "${WIDTH:-1760}" "${HEIGHT:-1000}"
mac_shot() { # 名前 URL 外観
    ui_post /appearance "{\"scheme\": \"$3\"}" >/dev/null
    ui_post /navigate "{\"url\": \"$2\"}" >/dev/null
    sleep 1.5
    ui_post /screenshot >"$out/demo-raw.png"
    python3 - "$out/demo-raw.png" "$images/$1-$3.png" <<'EOF'
import sys
from PIL import Image, ImageStat
src, dst = sys.argv[1:]
im = Image.open(src).convert("RGB")
cut = 966  # サイドバーの幅（2 倍の画素）
band = im.crop((0, im.height // 4, cut - 20, im.height * 3 // 4))
(im.crop((cut, 0, im.width, im.height)) if max(ImageStat.Stat(band).stddev) < 3 else im).save(dst)
EOF
    echo "$images/$1-$3.png"
}
# 全体のボードはタスクを開く前に撮る（開いたタスクの選択の枠がボードに残る）
for scheme in light dark; do mac_shot board taskboard://boards "$scheme"; done
for scheme in light dark; do
    mac_shot task taskboard://task/demo-studio/214 "$scheme"
    mac_shot ask taskboard://conversation/demo-studio/d-rank "$scheme"
done
kill "$pid" 2>/dev/null

sim=$(xcrun simctl list devices available | sed -nE "s/^ *${SIMULATOR:-iPhone 18 Pro} \(([0-9A-F-]+)\).*/\1/p" | head -1)
ios_app="$root/.build/DerivedData-iOS/Build/Products/Debug-iphonesimulator/Taskboard.app"
xcrun simctl boot "$sim" 2>/dev/null
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl install "$sim" "$ios_app"
xcrun simctl terminate "$sim" uk.whatn.taskboard.ios 2>/dev/null
xcrun simctl launch "$sim" uk.whatn.taskboard.ios --scenario "$SCENARIO" --debug-port 5794 >/dev/null
sleep 4
ios_shot() { # 名前 URL（空ならそのまま）
    [ -n "$2" ] && curl -sf -XPOST localhost:5794/navigate -d "{\"url\": \"$2\"}" >/dev/null && sleep 3
    xcrun simctl io "$sim" screenshot "$out/demo-ios.png" 2>/dev/null
    sips -Z 1400 "$out/demo-ios.png" --out "$images/iphone-$1.png" >/dev/null
    echo "$images/iphone-$1.png"
}
ios_shot home ""
ios_shot chat taskboard://conversation/demo-studio/d-checkout
ios_shot ask taskboard://conversation/demo-studio/d-rank
xcrun simctl status_bar "$sim" clear
xcrun simctl shutdown "$sim"
