#!/usr/bin/env python3
"""本物の codex app-server にサブエージェントを起こさせ（子と孫）、受けた電文を控え（Tests/TaskboardDaemonTests/CodexWire/subagent.jsonl）に書く。

モデルを呼ぶ（短い turn を 1 つ）。作った thread は最後に thread/archive で codex の一覧から外す。
控えの 1 行は {"kind": "notification", "line": <受けた行>} か {"kind": "items", "threadId": ..., "line": <thread/items/list の応答>}。
受けた行は書き換えず、次だけを外す:
- 通知は item/started・item/completed・turn/started・turn/completed 以外
- item の reasoning（暗号化された中身）と、a.txt 以外を読んだ commandExecution（ユーザーの指示ファイルを読むことがある）
外した通知も含め、受けた通知の method と threadId の数は stderr に出す（子の thread の通知がこの接続に届くかを見る）

使い方: scripts/fixtures/record-codex-subagent.py [codex の実行ファイル]
"""
import collections
import json
import pathlib
import subprocess
import sys
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "Tests/TaskboardDaemonTests/CodexWire/subagent.jsonl"
KEPT = {"item/started", "item/completed", "turn/started", "turn/completed"}
PROMPT = (
    "サブエージェントを1つ起こしてください。そのサブエージェントには、さらにサブエージェントを1つ起こさせ、その孫に a.txt を読ませて内容を1行で要約させてください。"
    "あなたと子は a.txt を読まず、下の答えを待ってから、その1行をそのまま返してください。"
)


def keeps(item):
    if item.get("type") == "reasoning":
        return False
    if item.get("type") == "commandExecution":
        return "a.txt" in json.dumps(item.get("command"), ensure_ascii=False)
    return True


class Server:
    def __init__(self, codex, cwd):
        self.process = subprocess.Popen([codex, "app-server"], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.next = 0
        self.notifications = []

    def send(self, method, params=None):
        self.next += 1
        message = {"id": self.next, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        return self.next

    def notify(self, method):
        self.process.stdin.write(json.dumps({"method": method}) + "\n")
        self.process.stdin.flush()

    def read(self, until):
        """until(line) が真になる行まで読み、通知はためる。サーバーからの要求（承認）は断る"""
        for raw in self.process.stdout:
            line = json.loads(raw)
            if "method" in line and "id" in line:
                self.process.stdin.write(json.dumps({"id": line["id"], "error": {"code": -32601, "message": "not handled"}}) + "\n")
                self.process.stdin.flush()
                continue
            if "method" in line:
                self.notifications.append(line)
            if until(line):
                return line
        raise SystemExit("app-server が終わった")

    def call(self, method, params=None):
        request = self.send(method, params)
        line = self.read(lambda l: l.get("id") == request)
        if "error" in line:
            raise SystemExit(f"{method}: {line['error']}")
        return line

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)


def main():
    codex = sys.argv[1] if len(sys.argv) > 1 else "codex"
    with tempfile.TemporaryDirectory(prefix="tb-codex-subagent-") as cwd:
        pathlib.Path(cwd, "a.txt").write_text("検索の index を作り直すには、まず古い index を消し、次に taskboard index rebuild を実行する。\n", encoding="utf-8")
        server = Server(codex, cwd)
        server.call("initialize", {"clientInfo": {"name": "taskboard-record", "title": "taskboard", "version": "0"}, "capabilities": {"experimentalApi": True}})
        server.notify("initialized")
        thread = server.call("thread/start", {"cwd": cwd, "approvalPolicy": "never", "sandbox": "read-only"})["result"]["thread"]["id"]
        server.call("turn/start", {"threadId": thread, "clientUserMessageId": str(uuid.uuid4()), "input": [{"type": "text", "text": PROMPT}]})
        server.read(lambda l: l.get("method") == "turn/completed" and l["params"].get("threadId") == thread)
        children = [
            n["params"]["item"]["agentThreadId"] for n in server.notifications
            if n["method"] == "item/completed" and n["params"]["item"].get("type") == "subAgentActivity" and n["params"]["item"].get("kind") == "started"
        ]
        lists = {t: server.call("thread/items/list", {"threadId": t, "limit": 200, "sortDirection": "desc"}) for t in [thread, *children]}
        # 子を外すと孫も外れ、孫の archive は「no rollout found」で断られる。断りは止めずに出す
        for t in [*children, thread]:
            line = server.read(lambda l, r=server.send("thread/archive", {"threadId": t}): l.get("id") == r)
            if "error" in line:
                print(f"thread/archive {t}: {line['error']['message']}", file=sys.stderr)
        server.close()

    seen = collections.Counter((n["method"], "main" if n.get("params", {}).get("threadId") == thread else "child" if n.get("params", {}).get("threadId") in children else n.get("params", {}).get("threadId")) for n in server.notifications)
    for (method, where), count in sorted(seen.items(), key=lambda x: (str(x[0][1]), x[0][0])):
        print(f"{where}\t{method}\t{count}", file=sys.stderr)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as out:
        for n in server.notifications:
            if n["method"] not in KEPT or ("item" in n["params"] and not keeps(n["params"]["item"])):
                continue
            out.write(json.dumps({"kind": "notification", "line": n}, ensure_ascii=False) + "\n")
        for t, line in lists.items():
            line["result"]["data"] = [e for e in line["result"]["data"] if keeps(e["item"])]
            out.write(json.dumps({"kind": "items", "threadId": t, "line": line}, ensure_ascii=False) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} (main {thread}, children {children})", file=sys.stderr)


if __name__ == "__main__":
    main()
