#!/bin/bash
# Mac アプリをビルドし、~/Applications に置く。
# symlink にしないのは、Spotlight が symlink の先（.build はドット始まりで索引の外）をたどらず、検索に出ないため
set -euo pipefail
cd "$(dirname "$0")/../App"
xcodegen generate >/dev/null
# Debug 構成のまま最適化する。-Onone のままだと、ボードのスクロールで引っかかりが 4 倍になった（フェーズ 6 の計測）。
# Release 構成にしないのは、debug server（--debug-port）を残すのと、署名の設定を Debug に持っているため。
# DerivedData を分けるのは、テストと -Onone のビルドの中間生成物を上書きし合わないようにするため
xcodebuild -project Taskboard.xcodeproj -scheme Taskboard -destination 'platform=macOS' -configuration Debug -derivedDataPath ../.build/DerivedDataOpt -quiet \
    SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s build
src=../.build/DerivedDataOpt/Build/Products/Debug/Taskboard.app
dst="$HOME/Applications/Taskboard.app"
mkdir -p "$HOME/Applications"
rm -rf "$dst"
ditto "$src" "$dst"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dst"
mdimport "$dst"
echo "$dst"
