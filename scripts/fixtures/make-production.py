#!/usr/bin/env python3
"""本番の 3 台（この Mac・Studio・Mac mini）の `/v1/state` から、量と形が同じで中身を伏せた fixtures を作る（性能の関門の prod の手順）。

- App/Fixtures/prod-local.json・prod-studio.json・prod-third.json。`--scenario prod-local+prod-studio+prod-third` で 3 台として並ぶ
- 数と、id・状態・時刻・番号・つながり（タスクと作業項目・会話・PR のリンク、受信箱の既読の項目の id）はそのまま残す
- 人の書いた文（題・メモ・本文・名前・パス・URL の中身・アカウント名）は同じ長さの別の文にする。空白・改行・数字・ASCII の記号は残し
  （Markdown の形と行の数が同じになる）、ASCII の英字は英字に、それ以外の字は仮名に替える。同じ文は同じ文になるので、URL とアカウント名の
  突き合わせ（PR とリンク、既読の項目の id）は崩れない
- マシンの id は prod-local・prod-studio・prod-third に、名前は MacBook・Mac Studio・Mac mini にする
- state に秘密（トークン・鍵）は無い。書き出す前に、元の state にあったメールとトークンの頭が出力に残っていないかを確かめ、あれば止まる

作り直すときは、3 台の state を取ってから渡す（取るのは読むだけ）:

    taskboard debug state > /tmp/local.json
    ssh <Studio の host> '~/.local/bin/taskboard debug state' > /tmp/studio.json
    ssh <3 台目の host> '~/.local/bin/taskboard debug state' > /tmp/third.json
    python3 scripts/fixtures/make-production.py local=/tmp/local.json studio=/tmp/studio.json third=/tmp/third.json
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parents[2]
NAMES = {"local": "MacBook", "studio": "Mac Studio", "third": "Mac mini"}
ASCII_FILL = "loremipsumdolorsitametconsecteturadipiscingelit"
KANA_FILL = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをん"

# 人の書いた文でない欄（id・状態・版・列の id など）。中の URL だけ伏せる
KEEP_KEYS = {
    "id", "itemID", "requestID", "toolUseID", "agentSessionID", "sessionID", "conversationID",
    "docID", "askID", "status", "state", "phase", "engine", "runner", "kind", "format", "effort", "model", "permissionMode",
    "purpose", "category", "checks", "reviewDecision", "blockerKind", "blockerTone", "deliverableKind", "source", "mergeTarget",
    "overlap", "trigger", "stage", "ending", "events", "engineVersion", "daemonVersion", "newest", "using",
    "failedVersion", "host", "agent", "columnID", "boardID", "cron", "revision", "machine", "statusName",
}
KEEP_PATHS = [re.compile(p) for p in (
    r"^\.boards\[\]\.columns\[\]",  # 列の名前と説明は既定の列の文
    r"^\.boards\[\]\.promptTemplate$",
    r"\.(agentArgs|launchArgs)\[\]$",
)]
ISO = re.compile(r"^\d{4}-\d\d-\d\dT")
URL = re.compile(r"https?://[^\s\"'<>()\]#]+")
URL_KEEP = {"https:", "http:", "", "github.com", "pull", "pulls", "issues", "browse", "commit", "tree", "blob"}
LEAK = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}|ghp_|gho_|github_pat_|sk-[A-Za-z0-9]|xox[bp]-|AKIA[0-9A-Z]{8}")


def fill(text):
    out = []
    for i, ch in enumerate(text):
        if ch.isspace() or ch.isdigit() or (ord(ch) < 128 and not ch.isalpha()):
            out.append(ch)
        elif ord(ch) < 128:
            c = ASCII_FILL[(i + ord(ch)) % len(ASCII_FILL)]
            out.append(c.upper() if ch.isupper() else c)
        else:
            out.append(KANA_FILL[(i + ord(ch)) % len(KANA_FILL)])
    return "".join(out)


def mask_segment(segment):
    """URL と owner/repo の区切り 1 つ。リンクの種類を決める区切り（github.com・pull など）と atlassian.net は残す"""
    if segment in URL_KEEP:
        return segment
    if segment.endswith(".atlassian.net"):
        return fill(segment[: -len(".atlassian.net")]) + ".atlassian.net"
    return fill(segment)


def mask_path(text):
    return "/".join(mask_segment(s) for s in text.split("/"))


def mask_urls(text):
    return URL.sub(lambda m: mask_path(m.group(0)), text)


def mask_text(text):
    parts, last = [], 0
    for m in URL.finditer(text):
        parts += [fill(text[last:m.start()]), mask_path(m.group(0))]
        last = m.end()
    parts.append(fill(text[last:]))
    return "".join(parts)


def walk(value, path, key, machines):
    if isinstance(value, dict):
        return {k: walk(v, f"{path}.{k}", k, machines) for k, v in value.items()}
    if isinstance(value, list):
        return [walk(v, f"{path}[]", key, machines) for v in value]
    if not isinstance(value, str):
        return value
    if value in machines:
        return machines[value]
    if ISO.match(value):
        return value
    if key in {"repository", "repo"}:
        return mask_path(value)
    if key == "itemID" and value.startswith("prsync/"):  # prsync/<host>|<アカウント>。アカウントは account の欄と同じ文にする
        host, _, account = value.partition("|")
        return f"{host}|{fill(account)}"
    if key in KEEP_KEYS or any(p.search(path) for p in KEEP_PATHS):
        if path.endswith(("agentArgs[]", "launchArgs[]")) and value.startswith(("/", "~")):
            return fill(value)
        return mask_urls(value)
    return mask_text(value)


def main():
    inputs = dict(arg.split("=", 1) for arg in sys.argv[1:])
    if set(inputs) != set(NAMES):
        sys.exit("使い方: make-production.py local=<state.json> studio=<state.json> third=<state.json>")
    states = {name: json.loads(pathlib.Path(path).read_text()) for name, path in inputs.items()}
    machines = {state["machine"]["id"]: f"prod-{name}" for name, state in states.items()}
    for name, state in states.items():
        out = walk(state, "", "", machines)
        out["machine"]["name"] = NAMES[name]
        text = json.dumps(out, ensure_ascii=False, indent=1, sort_keys=True)
        if leaks := [m for m in set(LEAK.findall(json.dumps(state, ensure_ascii=False))) if m in text]:
            sys.exit(f"prod-{name}: 元の state のメールかトークンが {len(leaks)} 件残っている")
        (root / f"App/Fixtures/prod-{name}.json").write_text(text + "\n")
        print(f"prod-{name}.json", {k: len(v) for k, v in out.items() if isinstance(v, list)})


if __name__ == "__main__":
    main()
