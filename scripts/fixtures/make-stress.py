#!/usr/bin/env python3
"""App/Fixtures/stress.json を作る。sessions-basic.json に、崩れやすいデータを足す（docs/ui-system.md「確かめ方」）。

- 長い題のタスク、長い待ち理由の作業項目（パネルの見出しを押し広げた型）
- 62 枚のカードが入った列（Mac Studio の「デプロイ中」と同じ数）と、空の列
- リンクが 6 本あるタスク、長い案件の名前
- 定期起動の各回の結果（スキップ・起動失敗・起動中・未起動）、長い名前、カスタムの引数、58 分の cron、日曜を含む毎週
- 作業ディレクトリの候補（ブックマークと最近使ったもの）。定期起動の無い `no-schedules.json` も作る

作り直すときは `python3 scripts/fixtures/make-stress.py`。
"""
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
base = json.loads((root / "App/Fixtures/sessions-basic.json").read_text())
machine = base["machine"]["id"]
board = base["boards"][0]["id"]
base["boards"][0]["name"] = "とても長い案件の名前（崩れの確認用）とても長い案件の名前"

def task(number, column, title, updated="2026-09-01T10:00:00+09:00", links=None, note=""):
    return {
        "machine": machine, "number": number, "boardID": board, "columnID": column, "title": title, "note": note, "due": None,
        "links": links or [], "sessions": [], "importedID": None, "createdAt": "2026-09-01T10:00:00+09:00", "updatedAt": updated,
    }

def link(i, url, kind):
    return {"id": i, "url": url, "kind": kind, "note": "", "addedAt": "2026-09-20T10:00:00+09:00"}

# 空の列を作るため、計画の列のタスクを未着手へ移す
for t in base["tasks"]:
    if t["columnID"] == "planning":
        t["columnID"] = "todo"

long_title = "実機の iPhone で Mac Studio の QR コードを読んで接続できること、登録を解除した端末が接続できなくなることを確かめ、結果を報告書にまとめて添付する"
tasks = [
    task(200, "working", long_title, updated="2026-10-03T11:00:00+09:00",
         links=[link(i + 1, f"https://github.com/ukwhatn/taskboard/pull/{40 + i}", "github_pr") for i in range(4)]
         + [link(5, "https://example.atlassian.net/browse/PROJ-1297", "jira"), link(6, "https://example.com/a/very/long/path/to/a/document/that/does/not/fit", "other")]),
]
for i in range(62):
    title = ["短い題", "依存パッケージの更新", "API のエラーの形を揃え、画面の文をアプリで組む", "長めの題: 案件ごとの起動プロンプトを差し込む SessionStart hook と会話の題"][i % 4]
    tasks.append(task(300 + i, "deploying", f"{title} {i + 1}", updated=f"2026-09-{(i % 28) + 1:02d}T10:00:00+09:00"))
base["tasks"] += tasks

long_reason = "実機の iPhone で Mac Studio の QR を読んで繋がること・停止した端末が繋がらなくなることの確認（ユーザー）。実装・外部レビュー 2 回・Studio・Mac mini の入れ替えは済み"
base["workItems"] += [
    {"machine": machine, "itemID": 900, "taskNumber": 200, "title": "実機での確認", "state": "wait", "blockerKind": "approval",
     "blockerText": long_reason, "blockerTone": None, "dependsOn": [], "deliverableKind": None, "deliverableRef": "", "owner": "",
     "position": 0, "source": "session", "createdAt": "2026-10-01T10:00:00+09:00", "updatedAt": "2026-10-03T10:00:00+09:00"},
    {"machine": machine, "itemID": 901, "taskNumber": 200, "title": "報告書を書く", "state": "todo", "blockerKind": None,
     "blockerText": "", "blockerTone": None, "dependsOn": [900], "deliverableKind": None, "deliverableRef": "", "owner": "",
     "position": 1, "source": "session", "createdAt": "2026-10-01T10:00:00+09:00", "updatedAt": "2026-10-01T10:00:00+09:00"},
]

def schedule(sid, name, rule, kind="claude", args=None, cwd="/Users/ukwhatn/dev/8_tools/taskboard", task=None, enabled=True, last=None, overlap="skip", prompt=""):
    item = {
        "scheduleID": sid, "machine": machine, "name": name, "enabled": enabled, "rule": rule, "cwd": cwd, "kind": kind,
        "agentArgs": args or [], "prompt": prompt, "overlap": overlap, "createdAt": "2026-09-30T10:00:00+09:00", "updatedAt": "2026-10-02T10:00:00+09:00",
    }
    if task is not None:
        item["taskNumber"] = task
    if enabled:
        item["nextAt"] = "2026-10-03T23:58:00+09:00"
    if last is not None:
        item["lastRun"] = dict({"scheduleID": sid, "trigger": "schedule", "createdAt": last.get("scheduledAt", "2026-10-03T09:00:00+09:00")}, **last)
    return item

opus = ["--dangerously-skip-permissions", "--model", "claude-fable-5-1[1m]", "--effort", "xhigh"]
base["schedules"] += [
    schedule(3, "とても長い名前の定期起動（崩れの確認用）: 週の初めと終わりに依存パッケージの更新と脆弱性の確認をまとめて行う",
             {"cron": "30 8 * * 0,1"}, args=opus, task=200,
             last={"id": 31, "scheduledAt": "2026-10-03T08:30:00+09:00", "skipped": "前回の実行が終わっていません"},
             prompt="依存パッケージを更新し、脆弱性の報告があれば作業項目にしてください。"),
    schedule(4, "夜の掃除", {"cron": "58 23 * * *"}, args=["--model", "haiku", "--verbose"], cwd="",
             last={"id": 41, "scheduledAt": "2026-10-02T23:58:00+09:00", "stage": "failed", "error": "taskNotFound(140)"}),
    schedule(5, "90分おきの見回り", {"intervalMinutes": 90}, kind="codex", overlap="parallel",
             last={"id": 51, "scheduledAt": "2026-10-03T11:30:00+09:00", "requestID": "sched-5-51", "stage": "tab", "trigger": "manual"}),
    schedule(6, "月水金の朝会の準備", {"cron": "0 9 * * 1,3,5"}, enabled=False),
]
base["workdirs"] = {
    "bookmarks": [
        {"id": 1, "path": "/Users/ukwhatn/dev/8_tools/taskboard", "createdAt": "2026-09-30T10:00:00+09:00"},
        {"id": 2, "path": "/Users/ukwhatn/dev/0_sol/das/とても長い名前のディレクトリ/さらに深い階層/崩れの確認用", "createdAt": "2026-09-30T10:00:00+09:00"},
    ],
    "recent": ["/Users/ukwhatn/dev/wiki", "/Users/ukwhatn/dev/8_tools/taskboard", "/Users/ukwhatn/dev/0_sol/das"],
}

out = root / "App/Fixtures/stress.json"
out.write_text(json.dumps(base, ensure_ascii=False, indent=1) + "\n")
print(out, len(base["tasks"]), "tasks")

empty = json.loads((root / "App/Fixtures/sessions-basic.json").read_text())
empty["schedules"] = []
(root / "App/Fixtures/no-schedules.json").write_text(json.dumps(empty, ensure_ascii=False, indent=1) + "\n")
