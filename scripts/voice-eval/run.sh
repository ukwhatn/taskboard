#!/bin/zsh
# 音声ファイルを作り、Apple の認識・Whisper（モデルと条件ごと）・Whisper ＋校正で文字にして CER を出す（README.md）
# 使い方: scripts/voice-eval/run.sh <作業ディレクトリ> [条件の名前...]
#   条件を省くと全部回す。モデルは <作業ディレクトリ>/models に取得する（アプリの置き場は使わない）
set -euo pipefail
here=${0:A:h}
work=${1:?作業ディレクトリ}
shift
mkdir -p "$work/results"
[[ -f "$work/audio/refs.tsv" ]] || "$here/make-audio.sh" "$work/audio"
(cd "$here" && swift build -c release -Xswiftc -enable-testing >/dev/null)
eval_bin="$here/.build/release/VoiceEval"
ctx="$here/context.json"
models="$work/models"
mac=openai_whisper-large-v3-v20240930
mobile=openai_whisper-large-v3-v20240930_626MB
conditions=("$@")
(( $#conditions )) || conditions=(apple mac mac-novocab mac-nonorm mobile small polish)

for c in $conditions; do
  for v in normal quiet; do
    out="$work/results/$c-$v.tsv"
    case $c in
      apple) "$eval_bin" apple "$work/audio/$v" "$ctx" > "$out" ;;
      mac) "$eval_bin" whisper "$work/audio/$v" "$ctx" --model $mac --models-dir "$models" > "$out" 2>"$out.log" ;;
      mac-novocab) "$eval_bin" whisper "$work/audio/$v" "$ctx" --model $mac --models-dir "$models" --no-vocabulary > "$out" 2>"$out.log" ;;
      mac-nonorm) "$eval_bin" whisper "$work/audio/$v" "$ctx" --model $mac --models-dir "$models" --no-normalize > "$out" 2>"$out.log" ;;
      mobile) "$eval_bin" whisper "$work/audio/$v" "$ctx" --model $mobile --models-dir "$models" > "$out" 2>"$out.log" ;;
      small) "$eval_bin" whisper "$work/audio/$v" "$ctx" --model openai_whisper-small --models-dir "$models" > "$out" 2>"$out.log" ;;
      polish) "$eval_bin" polish "$work/results/mac-$v.tsv" "$ctx" > "$out" 2>"$out.log" ;;
      *) print -u2 "知らない条件: $c"; exit 2 ;;
    esac
  done
done
python3 -I "$here/score.py" "$work/audio/refs.tsv" "$work"/results/*.tsv
