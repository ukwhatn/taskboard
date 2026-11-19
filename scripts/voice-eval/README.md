# voice-eval

会話の入力欄の音声入力の認識と校正を、同じ音声ファイルで比べる。比べるのは次の 3 つ。

- 置き換える前の Apple の `DictationTranscriber`（`apple`。入力欄と同じく 4096 フレームずつ実時間で流す）
- 端末の中の Whisper（`whisper`。アプリの `App/Sources/Voice/WhisperRecognizer.swift` と `VoiceAudioConverter.swift` を symlink で読む）
- Whisper の結果を daemon と同じ手順（`ClaudeDictationPolish`）で校正したもの（`polish`）

```sh
scripts/voice-eval/run.sh /tmp/voice-eval            # 全部の条件
scripts/voice-eval/run.sh /tmp/voice-eval mac polish # 条件を選ぶ
```

- `corpus.txt` の 1 行が 1 本の音声。`make-audio.sh` が `say -v Kyoko` で作り、`ffmpeg` で -30 dB にした小さい声の版も作る
- `context.json` は会話の文脈（タスクの題と番号、最近の発言）。Whisper の語彙と校正の文脈は、アプリと同じく `DictationVocabulary`・`DictationPolishRequest` で組む。発言には、corpus の技術語の半分ほど（Stop hook・ConversationService・snapshot test・AppDefaults・WebSocket・README）だけを入れてある
- モデルは作業ディレクトリの `models/` に取得する（アプリの置き場は使わない）
- CER は `score.py`。NFKC・小文字にそろえ、空白と句読点を除いた文字の編集距離を正解の字数で割る
- `polish` は `claude -p` を 1 本ずつ回すので、この Mac の Claude Code の利用枠を使う。校正の結果は回ごとに揺れるので、2 回以上回して比べる
- `endpoint` はハンズフリーの終わりの判定（`DictationEndpoint`）を、音声の後ろに 3 秒の無音を付けて流す

音声は合成音声なので、人の声・マイクの雑音・AirPods の通話用の形式での精度は測っていない。
