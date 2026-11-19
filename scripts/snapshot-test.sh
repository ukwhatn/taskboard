#!/bin/bash
# 画面の snapshot test を回す（CLAUDE.md「規定コマンド」）。
# 失敗したときの画像は $TMPDIR/<Suite 名>/ に出て、同じ Mac で並べて回すと置き場を共有する。そこで lockf で 1 本ずつ回し、
# この回に出た画像だけを .build/snapshots-out/<Suite 名>/ に写す。画像を見てから App/Tests/__Snapshots__/<Suite 名>/ に写す
#
#   scripts/snapshot-test.sh [-only-testing:TaskboardTests/<Suite 名> …]   ログは .build/snap.log
#
# --ios <シミュレータの udid> を先頭に付けると、iPhone の幅の snapshot test（App/Tests/iOS。scheme TaskboardiOS）をそのシミュレータで回す。
# 失敗の画像は .build/snapshots-out/<ファイル名>/ に直接出す（シミュレータの $TMPDIR はアプリの container の中で、ここから探せない）。
# 参照は App/Tests/iOS/__Snapshots__/。シミュレータは iPhone を使う（iPad では AppModel.isPhone が偽になり、テストが落ちる）
#
#   scripts/snapshot-test.sh --ios <udid> [-only-testing:TaskboardiOSTests/<Suite 名> …]   ログは .build/snap-ios.log
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
if [ "${1:-}" = "--ios" ]; then
    udid=${2:?--ios にはシミュレータの udid を渡す}
    shift 2
    exec lockf -k /tmp/taskboard-snapshot.lock bash -c '
        set -uo pipefail
        udid=$1
        shift
        rm -rf .build/snapshots-out
        # TEST_RUNNER_ の付いた環境変数は、頭を外してテストのプロセスに渡る
        (cd App && xcodegen generate >/dev/null && TEST_RUNNER_SNAPSHOT_ARTIFACTS="$PWD/../.build/snapshots-out" xcodebuild -project Taskboard.xcodeproj \
            -scheme TaskboardiOS -destination "platform=iOS Simulator,id=$udid" -configuration Debug -derivedDataPath ../.build/DerivedData-iOSTests "$@" test) \
            > .build/snap-ios.log 2>&1
        status=$?
        grep -E "Test run with|TEST (SUCCEEDED|FAILED)" .build/snap-ios.log | tail -2
        [ -d .build/snapshots-out ] && find .build/snapshots-out -name "*.png" | sort
        exit $status
    ' bash "$udid" "$@"
fi
exec lockf -k /tmp/taskboard-snapshot.lock bash -c '
    set -uo pipefail
    marker=.build/snap.marker
    touch "$marker"
    (cd App && xcodegen generate >/dev/null && xcodebuild -project Taskboard.xcodeproj -scheme Taskboard -destination "platform=macOS" \
        -configuration Debug -derivedDataPath ../.build/DerivedData "$@" test) > .build/snap.log 2>&1
    status=$?
    rm -rf .build/snapshots-out
    tmp=${TMPDIR:-/tmp}
    find "${tmp%/}" -maxdepth 2 -path "*Tests/*.png" -newer "$marker" 2>/dev/null | while read -r file; do
        suite=$(basename "$(dirname "$file")")
        mkdir -p ".build/snapshots-out/$suite"
        cp "$file" ".build/snapshots-out/$suite/"
    done
    grep -E "Test run with|TEST (SUCCEEDED|FAILED)" .build/snap.log | tail -2
    [ -d .build/snapshots-out ] && find .build/snapshots-out -name "*.png" | sort
    exit $status
' bash "$@"
