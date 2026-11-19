#!/bin/bash
# 画面の文を String Catalog（App/Sources/Localizable.xcstrings）に集める（docs/ui-copy.md「String Catalog」）。
# コマンドラインのビルドは catalog を書き換えないので、Mac と iOS シミュレータ向けにビルドして抽出した .stringsdata を
# xcstringstool sync で入れる。`#if os(iOS)` の文は iOS のビルドにしか出てこないので、両方を合わせる。
# 使われなくなった文は catalog から消える（訳が無いため）
#
#   scripts/sync-strings.sh
set -euo pipefail
cd "$(dirname "$0")/.."
catalog=App/Sources/Localizable.xcstrings
log=.build/sync-strings.log
mkdir -p .build
: >"$log"

xcodebuild -project App/Taskboard.xcodeproj -scheme Taskboard -destination 'platform=macOS' -configuration Debug \
    -derivedDataPath .build/DerivedData -disableAutomaticPackageResolution -quiet build >>"$log" 2>&1 || { echo "Mac のビルドに失敗した（${log}）" >&2; exit 1; }
xcodebuild -project App/Taskboard.xcodeproj -scheme Taskboard -destination 'generic/platform=iOS Simulator' -configuration Debug \
    -derivedDataPath .build/DerivedData-iOS -disableAutomaticPackageResolution -quiet build >>"$log" 2>&1 || { echo "iOS のビルドに失敗した（${log}）" >&2; exit 1; }

# App と、画面に届く文を持つ Kit（Package.swift の defaultLocalization で Xcode が抜き出す）の両方を 1 つの catalog に入れる
files=()
for dir in .build/DerivedData/Build/Intermediates.noindex/Taskboard.build/Debug/Taskboard.build \
    .build/DerivedData/Build/Intermediates.noindex/Taskboard.build/Debug/TaskboardKit-t.build \
    .build/DerivedData-iOS/Build/Intermediates.noindex/Taskboard.build/Debug-iphonesimulator/Taskboard.build \
    .build/DerivedData-iOS/Build/Intermediates.noindex/Taskboard.build/Debug-iphonesimulator/TaskboardKit-t.build; do
    while IFS= read -r file; do files+=(--stringsdata "$file"); done < <(find "$dir/Objects-normal" -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata.stringsdata')
done
[ ${#files[@]} -gt 0 ] || { echo ".stringsdata が無い（SWIFT_EMIT_LOC_STRINGS を確かめる）" >&2; exit 1; }

xcrun xcstringstool sync "$catalog" "${files[@]}"
echo "$(xcrun xcstringstool print "$catalog" | grep -c '^') 件（${catalog}）"
