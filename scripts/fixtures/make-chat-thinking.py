#!/usr/bin/env python3
"""思考の行を見る fixtures（chat-thinking.json）を作る。conversations.json に Claude Code の会話を足す。

- c-think: 動いている（返答待ち）会話。短い思考・長い思考（段落・リスト・コード）・ツールの間に挟まる思考・返答の前の思考が並ぶ。
  署名だけで中身の空の thinking は daemon が捨てるので、ここには置かない（Tests/TaskboardDaemonTests/TranscriptTests.swift）

作り直すときは `python3 scripts/fixtures/make-chat-thinking.py`。
"""
import copy
import json
import pathlib

root = pathlib.Path(__file__).resolve().parents[2]
base = json.loads((root / "App/Fixtures/conversations.json").read_text())
template = next(c for c in base["conversations"] if c["id"] == "c-tools")
at = "2026-10-23T09:20:00Z"

conversation = copy.deepcopy(template)
conversation.update({
    "id": "c-think", "agentSessionID": "agent-c-think", "title": "ログインの失敗を直す", "taskNumber": 137, "canUndoRewind": False,
    "runner": "host", "phase": "idle", "backgroundTasks": 0, "backgroundTasksKnown": True,
    "createdAt": "2026-10-23T09:15:00Z", "updatedAt": at,
})
conversation["stats"]["agentSessionID"] = "agent-c-think"
conversation.pop("backgroundTaskStates", None)


def said(mid, text):
    return {"id": mid, "role": "assistant", "kind": "text", "text": text, "isError": False, "at": at}


def thought(mid, text):
    return {**said(mid, text), "thinking": True}


def tool(tid, name, text, result):
    return [
        {"id": f"c-{tid}", "role": "assistant", "kind": "toolUse", "text": text, "isError": False, "at": at, "toolName": name, "toolID": tid},
        {"id": f"r-{tid}", "role": "user", "kind": "toolResult", "text": result, "isError": False, "at": at, "toolID": tid},
    ]


long_thought = """ログインの失敗は 2 通り考えられる。

- トークンの期限が切れているのに、**更新の呼び出し**が 1 回しか走らない
- 更新に失敗したあと、古いトークンで再試行している

先に更新の経路を読む。`AuthClient.refresh()` が返す値を、呼び出し側が捨てていないかを見る。

```swift
let token = try await client.refresh()
store.save(token)
```

保存の前に例外が出ると、次の呼び出しは古い値のままになる。"""

messages = [
    {"id": "u1", "role": "user", "kind": "text", "text": "ログインに失敗する原因を調べて直して", "isError": False, "at": at},
    thought("k1", "まずログを読んで、失敗の起点を探す。"),
    *tool("t1", "Bash", "rg -n \"login failed\" logs/", "logs/app.log:120: login failed: token expired"),
    thought("k2", long_thought),
    *tool("t2", "Read", "Sources/Auth/AuthClient.swift", "final class AuthClient { … }"),
    thought("k3", "更新の結果を保存する前に例外が出る。保存を先に済ませる形へ直す。"),
    *tool("t3", "Edit", "Sources/Auth/AuthClient.swift", "The file has been updated."),
    thought("k4", "直したので、テストを回して確かめる。"),
    said("a1", "原因は、更新したトークンを保存する前に例外が出る経路でした。保存を先にして直しました。"),
]

out = copy.deepcopy(base)
out["conversations"].append(conversation)
out["conversationChats"]["c-think"] = {"messages": messages}
(root / "App/Fixtures/chat-thinking.json").write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n")
