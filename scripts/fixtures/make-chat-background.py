#!/usr/bin/env python3
"""裏のタスクの様子を見る fixtures（chat-background.json）を作る。conversations.json に Claude Code の会話を 2 つ足す。

- c-bg: 動いている会話。裏のタスクが 2 つ動いていて（1 つは続いたツールの組の中）、完了・失敗・停止・終了（daemon が覚えていない）の行がある
- c-bg-done: 止まった会話。裏に回した Bash は、daemon の記録が無くても終了と出る
- c-bg-perf・c-bg-perf-plain: 回る印が描く重さを比べる長い会話（Bash が 120 回。前者はどれも裏で動いていて、後者は同じ発言でふつうに終わっている）

作り直すときは `python3 scripts/fixtures/make-chat-background.py`。
"""
import copy
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
base = json.loads((root / "App/Fixtures/conversations.json").read_text())
machine = base["machine"]["id"]
template = next(c for c in base["conversations"] if c["id"] == "c-tools")
at = "2026-10-07T09:20:00Z"


def conversation(cid, title, running, states):
    c = copy.deepcopy(template)
    c.update({
        "id": cid, "agentSessionID": f"agent-{cid}", "title": title, "taskNumber": 137, "canUndoRewind": False,
        "runner": "host" if running else "none", "phase": "idle" if running else "stopped",
        "backgroundTasks": sum(1 for s in states or [] if s["status"] == "running"), "backgroundTasksKnown": True,
        "createdAt": "2026-10-07T09:15:00Z", "updatedAt": at,
    })
    c["stats"]["agentSessionID"] = f"agent-{cid}"
    if states is None:
        c.pop("backgroundTaskStates", None)
    else:
        c["backgroundTaskStates"] = states
    return c


def said(mid, text):
    return {"id": mid, "role": "assistant", "kind": "text", "text": text, "isError": False, "at": at}


def tool(tid, name, text, result, task=None, error=False):
    call = {"id": f"c-{tid}", "role": "assistant", "kind": "toolUse", "text": text, "isError": False, "at": at, "toolName": name, "toolID": tid}
    done = {"id": f"r-{tid}", "role": "user", "kind": "toolResult", "text": result, "isError": error, "at": at, "toolID": tid}
    if task:
        done["backgroundTaskID"] = task
    return [call, done]


def started(task):
    return f"Command running in background with ID: {task}. Output is being written to: /private/tmp/tasks/{task}.output"


running = [
    {"id": "user1", "role": "user", "kind": "text", "text": "テストとビルドを裏で回しながら直して", "isError": False, "at": at},
    said("s1", "テストを裏で回します。"),
    *tool("t1", "Bash", "swift test", started("b7test01"), task="b7test01"),
    said("s2", "リリースのビルドも裏で回します。"),
    *tool("t2", "Bash", "swift build -c release", started("b7build2"), task="b7build2"),
    said("s3", "lint を裏で回します。"),
    *tool("t3", "Bash", "swiftlint lint --strict", started("b7lint03"), task="b7lint03"),
    said("s4", "古い待ち受けを止めました。"),
    *tool("t4", "Bash", "taskboard serve --port 7611", started("b7serve4"), task="b7serve4"),
    said("s5", "前の回のサーバーです。"),
    *tool("t5", "Bash", "python3 -m http.server 8000", started("b7http05"), task="b7http05"),
    said("s6", "ファイルを読み、待ち時間を測ります。"),
    *tool("t6", "Read", "App/Sources/Views/ChatRows.swift", "import SwiftUI"),
    *tool("t7", "Bash", "sleep 20", started("b7sleep7"), task="b7sleep7"),
]
running_states = [
    {"id": "b7test01", "status": "running"},
    {"id": "b7sleep7", "status": "running"},
    {"id": "b7build2", "status": "completed"},
    {"id": "b7lint03", "status": "failed"},
    {"id": "b7serve4", "status": "stopped"},
]

stopped = [
    {"id": "user2", "role": "user", "kind": "text", "text": "ログを裏で見張って", "isError": False, "at": at},
    said("d1", "ログを裏で見張ります。"),
    *tool("d2", "Bash", "tail -f ~/Library/Logs/taskboard/daemon.log", started("b7tail01"), task="b7tail01"),
]


def long_chat(background):
    """回る印が描く重さを比べる長い会話。background なら Bash がどれも裏で動いていて、そうでなければ同じ発言でふつうに終わっている"""
    paragraph = "一覧の行は見えている所だけを置き、外れた行は使い回します。行の高さは測って覚え、測っていない行は見積もりで数えます。"
    messages = []
    for i in range(120):
        if i % 10 == 0:
            messages.append({"id": f"pu{i}", "role": "user", "kind": "text", "text": f"次の所を直してください。番号 {i}", "isError": False, "at": at})
        messages.append(said(f"pa{i}", f"手順 {i} を回します。"))
        task = f"b7perf{i:03d}"
        messages += tool(f"pt{i}", "Bash", f"swift test --filter Case{i}", started(task) if background else "Test Suite passed.", task=task if background else None)
        messages.append(said(f"pp{i}", paragraph))
    return messages


perf_states = [{"id": f"b7perf{i:03d}", "status": "running"} for i in range(120)]

out = copy.deepcopy(base)
out["conversations"] += [
    conversation("c-bg", "テストを裏で回す", True, running_states),
    conversation("c-bg-done", "ログを裏で見張る", False, None),
    conversation("c-bg-perf", "裏のテストを並べて回す", True, perf_states),
    conversation("c-bg-perf-plain", "テストを並べて回す", True, []),
]
out["conversationChats"]["c-bg"] = {"messages": running}
out["conversationChats"]["c-bg-done"] = {"messages": stopped}
out["conversationChats"]["c-bg-perf"] = {"messages": long_chat(True)}
out["conversationChats"]["c-bg-perf-plain"] = {"messages": long_chat(False)}
(root / "App/Fixtures/chat-background.json").write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
