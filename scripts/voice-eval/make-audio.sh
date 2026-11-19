#!/bin/zsh
# corpus.txt の 1 行ごとに say -v Kyoko で音声を作る。normal/NN.wav（そのままの音量）と quiet/NN.wav（-30 dB）、refs.tsv（番号と正解の文）
# 使い方: scripts/voice-eval/make-audio.sh <出力ディレクトリ>
set -euo pipefail
here=${0:A:h}
out=${1:?出力ディレクトリ}
mkdir -p "$out/normal" "$out/quiet"
: > "$out/refs.tsv"
n=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  n=$((n + 1))
  id=$(printf %02d $n)
  say -v Kyoko -o "$out/normal/$id.wav" --data-format=LEI16@22050 "$line"
  ffmpeg -loglevel error -y -i "$out/normal/$id.wav" -af volume=-30dB "$out/quiet/$id.wav"
  print -r -- "$id	$line" >> "$out/refs.tsv"
done < "$here/corpus.txt"
print "$n 本を $out に作った"
