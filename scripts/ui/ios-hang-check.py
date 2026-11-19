#!/usr/bin/env python3
"""iOS シミュレータで、会話の画面の止まりの再現条件を回し、止まった回を数える（ios-hang-check.sh から呼ぶ）。

使い方: ios-hang-check.py <udid> <port> <app> <回数> <条件,…>
条件:
  gen-focus     生成中の会話（c-gen）を開き、入力欄にフォーカスしてキーボードを出す
  ask-focus     問いのある会話（c-ask）で同じ
  files-3lines  c-files で入力欄に 1 行ずつ足して 3 行目まで伸ばす
  limit-stream  c-limit に 1,500 件を流し込み、フォーカスしてから 30 秒間生成中の差分を流す
  tools-to-ask  c-tools でフォーカスした後に c-ask へ移ってフォーカスする
判定: 操作の 15 秒後から 5 秒の間に主スレッドの CPU 時間が 3,500 ms 以上増えたか、debug の口が 3 秒で答えなければ止まり。
1 回ずつアプリを起動し直す。1 回 1 行の JSON と、条件ごとの集計の行を出す。止まりが 1 回でもあれば終了コード 1
"""
import json
import subprocess
import sys
import threading
import time
import urllib.request

BUNDLE = "uk.whatn.taskboard.ios"
CONDITIONS = ["gen-focus", "ask-focus", "files-3lines", "limit-stream", "tools-to-ask"]


class Check:
    def __init__(self, udid, port):
        self.udid = udid
        self.port = port
        self.base = f"http://127.0.0.1:{port}"
        self.extra = {}

    def call(self, path, body=None, timeout=10):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method="POST" if data else "GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")

    def wait_up(self):
        for _ in range(60):
            try:
                self.call("/cpu", timeout=1)
                return
            except Exception:
                time.sleep(0.5)
        raise RuntimeError("アプリの debug の口が開かない")

    def open_conversation(self, conversation):
        self.call("/navigate", {"url": f"taskboard://conversation/fixture-studio/{conversation}"})
        time.sleep(2)

    def composer(self):
        fields = self.call("/fields", timeout=5)["fields"]
        # 問いのカードの「自由記述」も複数行の欄なので、読み上げの名前で入力欄を選ぶ
        return next(i for i, field in enumerate(fields) if field["kind"].startswith("Multiline") and field["name"] == "メッセージ")

    def focus(self):
        self.call("/field/focus", {"index": self.composer()})

    def stream_quietly(self):
        # 次の回でアプリを落とすと接続が切れる。判定は /cpu で行うので、切れたことは捨てる
        try:
            self.call("/bench/stream", {"seconds": 30, "deltaMs": 50}, timeout=60)
        except Exception:
            pass

    def act(self, condition):
        if condition == "gen-focus":
            self.open_conversation("c-gen")
            self.focus()
        elif condition == "ask-focus":
            self.open_conversation("c-ask")
            self.focus()
        elif condition == "files-3lines":
            self.open_conversation("c-files")
            index = self.composer()
            self.call("/field/focus", {"index": index})
            # /field/fill は欄の全体を置き換え、keep が無ければ測った後に空へ戻す。折り返しで 1 行ずつ伸ばす
            line = "入力欄が折り返して次の行に伸びる"
            for n in (1, 2, 3):
                self.call("/field/fill", {"index": index, "text": line * n, "settleMs": 800, "keep": True}, timeout=30)
            self.extra["fieldHeight"] = self.call("/fields", timeout=5)["fields"][index]["frame"]["height"]
        elif condition == "limit-stream":
            self.open_conversation("c-limit")
            self.call("/bench/conversation", {"messages": 1500, "chunk": 10, "streamSeconds": 1, "deltaMs": 50}, timeout=300)
            self.focus()
            # /bench/stream は流し終えるまで答えないので、流している最中に判定するよう別のスレッドで送る
            threading.Thread(target=self.stream_quietly, daemon=True).start()
        elif condition == "tools-to-ask":
            self.open_conversation("c-tools")
            self.focus()
            time.sleep(1)
            self.open_conversation("c-ask")
            self.focus()
        else:
            raise SystemExit(f"知らない条件: {condition}")

    def trial(self, condition):
        self.extra = {}
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, BUNDLE], capture_output=True)
        subprocess.run(
            ["xcrun", "simctl", "launch", self.udid, BUNDLE, "--scenario", "conversations", "--debug-port", str(self.port), "--no-notifications",
             "--watchdog"],
            check=True, capture_output=True)
        self.wait_up()
        try:
            self.act(condition)
        except Exception as error:
            return {"hang": True, "stage": "action", "error": str(error)}
        time.sleep(15)
        try:
            before = self.call("/cpu", timeout=3)["ms"]
            time.sleep(5)
            after = self.call("/cpu", timeout=3)["ms"]
        except Exception as error:
            return {"hang": True, "stage": "probe", "error": str(error)}
        events = self.call("/state", timeout=5).get("events", [])
        count = lambda kind: sum(1 for event in events if event.get("type") == kind)
        # followLimit は下端への送り直しの往復を止めた回数（ChatTranscript の chat.follow_limit）、stalls は見張りが数えた 1.5 秒以上の止まり（起動中を含む）
        return {"hang": after - before >= 3500, "cpu5s": round(after - before), "followLimit": count("chat.follow_limit"),
                "stalls": count("main.stall"), **self.extra}


def main():
    udid, port, app, rounds, conditions = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5].split(",")
    unknown = [c for c in conditions if c not in CONDITIONS]
    if unknown:
        raise SystemExit(f"知らない条件: {','.join(unknown)}（{','.join(CONDITIONS)}）")
    check = Check(udid, port)
    subprocess.run(["xcrun", "simctl", "install", udid, app], check=True)
    total = 0
    try:
        for condition in conditions:
            hangs = 0
            for n in range(rounds):
                result = check.trial(condition)
                result.update(cond=condition, round=n + 1)
                print(json.dumps(result, ensure_ascii=False), flush=True)
                hangs += result["hang"]
            print(json.dumps({"cond": condition, "hangs": hangs, "rounds": rounds}), flush=True)
            total += hangs
    finally:
        subprocess.run(["xcrun", "simctl", "terminate", udid, BUNDLE], capture_output=True)
    print(json.dumps({"hangs": total, "conditions": len(conditions), "rounds": rounds}), flush=True)
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
