#!/usr/bin/env python3
"""2 台目のマシンの fixtures を作る（オーケストレーターの送り先と状態の確認用）。`--scenario stress+machine-second` のように足して使う。

- machine-second.json: オーケストレーターが動いていて、最後の返事がある
- machine-second-resident.json: 常駐がオンなのに起動していない（常駐の見張りが起こせなかった）
- machine-second-off.json: 常駐がオフで、オーケストレーターが起きていない

作り直すときは `python3 scripts/fixtures/make-second-machine.py`。
"""
import copy
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
base = json.loads((root / "App/Fixtures/sessions-basic.json").read_text())
machine = "fixture-second"
board_id = "second-board"

board = copy.deepcopy(base["boards"][0])
board.update({"id": board_id, "machine": machine, "name": "das"})

def task(number, column, title):
    return {
        "machine": machine, "number": number, "boardID": board_id, "columnID": column, "title": title, "note": "", "due": None,
        "links": [], "sessions": [], "importedID": None, "createdAt": "2026-09-30T10:00:00+09:00", "updatedAt": "2026-10-02T18:00:00+09:00",
    }

orchestrator_conversation = {
    "id": "c-orch-second", "machine": machine, "taskNumber": None, "engine": "claude", "agentSessionID": "sess-orch-second", "cwd": "/Users/ukwhatn",
    "model": "opus", "title": "オーケストレーター", "runner": "host", "phase": "idle", "pending": [], "backgroundTasks": 0, "backgroundTasksKnown": True,
    "purpose": "orchestrator", "createdAt": "2026-10-03T04:00:00Z", "updatedAt": "2026-10-03T04:52:00Z",
}

def snapshot(resident_only, off=False):
    if off:
        shot = snapshot(True)
        shot["settings"]["orchestrator"]["enabled"] = False
        shot["orchestrator"].update({"enabled": False, "lastError": None})
        return shot
    return {
        "generatedAt": base["generatedAt"],
        "machine": {"id": machine, "name": "Mac mini", "daemonVersion": "0.1.0"},
        "boards": [board],
        "tasks": [task(19, "todo", "通知の URL を差し替える"), task(20, "working", "管理画面の権限を分ける")],
        "workItems": [], "documents": [], "asks": [], "reviewRequests": [], "links": [], "schedules": [],
        "settings": {"orchestrator": {"enabled": True, "agentArgs": ["--model", "opus", "--effort", "medium"]}, "idleStopMinutes": 120},
        "orchestrator": {
            "enabled": True,
            "lastError": "conversation: start failed" if resident_only else None,
            "conversationID": None if resident_only else orchestrator_conversation["id"],
            "lastReply": None if resident_only else {
                "text": "#19 と #20 の進み具合を確かめました。#20 は作業中で、レビューの依頼はまだです。#19 は未着手のままなので、起動の候補にしました。",
                "at": "2026-10-03T04:52:00Z",
            },
        },
        "conversations": [] if resident_only else [orchestrator_conversation],
    }

for name, resident_only, off in [("machine-second", False, False), ("machine-second-resident", True, False), ("machine-second-off", True, True)]:
    (root / f"App/Fixtures/{name}.json").write_text(json.dumps(snapshot(resident_only, off), ensure_ascii=False, indent=1) + "\n")
    print(f"App/Fixtures/{name}.json")
