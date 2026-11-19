#!/bin/bash
# ビルドした taskboard を support ディレクトリの bin/ に写して署名し、launchd の job（daemon・agent host）と ~/.local/bin/taskboard をそこへ向けて、daemon を起こし直す。
# 使い方: scripts/install-cli.sh [実行ファイル（既定 .build/debug/taskboard）]
# 写すのは、repo のビルド（swift test でも作り直される）で動いている daemon の実行ファイルが替わらないようにするため。
# 署名は team の証明書（無ければ ad hoc）。再起動の後の LaunchAgent は BTM が実行ファイルの署名に結んだ起動の制約を持ち、
# ad hoc ではハッシュに結ばれて、ビルドし直すたびに起動を断られる（docs/daemon.md「起動を断られ続ける job の登録し直し」）
set -euo pipefail
cd "$(dirname "$0")/.."
src="${1:-.build/debug/taskboard}"
src="$(cd "$(dirname "$src")" && pwd -P)/$(basename "$src")"
dest="$HOME/Library/Application Support/taskboard/bin"
mkdir -p "$dest"
work="$(mktemp -d "$dest/.new.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$src" "$work/taskboard"
for bundle in "$(dirname "$src")"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$work/"; done
identity="${TASKBOARD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -1)}"
codesign --force --sign "${identity:--}" --identifier uk.whatn.taskboard.cli "$work/taskboard"
echo "signed with ${identity:-ad hoc}"
for bundle in "$work"/*.bundle; do
  [ -e "$bundle" ] || continue
  rm -rf "$dest/$(basename "$bundle")"
  mv "$bundle" "$dest/"
done
# 動いている daemon と host は前の inode を開いたままなので、置き換えても止まらない
mv -f "$work/taskboard" "$dest/taskboard"
mkdir -p "$HOME/.local/bin"
ln -sfn "$dest/taskboard" "$HOME/.local/bin/taskboard"

plist="$HOME/Library/LaunchAgents/uk.whatn.taskboardd.plist"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist" 2>/dev/null)" != "$dest/taskboard" ]; then
  # 初めて写しに向ける：plist を書き直して登録し直す（会話を持っている agent host は install-launchd が入れ替えない）
  "$dest/taskboard" install-launchd
else
  launchctl kickstart -k "gui/$(id -u)/uk.whatn.taskboardd" 2>/dev/null || launchctl kickstart -k "user/$(id -u)/uk.whatn.taskboardd"
fi
