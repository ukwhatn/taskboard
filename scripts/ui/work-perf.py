#!/usr/bin/env python3
"""作業項目の欄の重さを測る（CLAUDE.md「画面の滑らかさは -O のビルドで測る」）。fixtures の perf-work（#301 に依存のある 300 件）でタスクを中央モーダルに開き、
作業項目の欄を開く・項目の状態を変える（2 回）・右側の幅を動かす・欄の境目を動かすの間の /perf を取り、1 行 1 手順の JSON を出す。

    python3 scripts/ui/work-perf.py [回数]   既定 3 回（回ごとにアプリを起こし直す）。APP（既定 .build/DerivedDataOpt の -O のビルド）、PORT（既定 5795）
    SCENARIO（既定 perf-work）と ITEM（状態を変える作業項目の id。既定 1150）で別の fixtures も測れる

アプリは実行ファイルを裏で直に起こし、窓をほかの窓の後ろに回す（chat-perf.sh と同じ）。マウスとキーボードは動かさない。
窓が載る画面は回ごとに替わり、フレームの間隔の上限もその画面の更新の速さ（60 Hz なら 16.7 ms、120 Hz なら 8.3 ms）で替わる。比べるのは同じ間隔の回どうし。
境目を動かす手順は、取っ手のドラッグと同じ値（右側の幅、欄の高さの重み）を /defaults で 16 ms ごとに 60 回書く。
状態を変える手順は、fixtures に作業項目を変えた知らせを流す（/fixture/work）。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = os.environ.get("APP", str(root / ".build/DerivedDataOpt/Build/Products/Debug/Taskboard.app"))
port = os.environ.get("PORT", "5795")
scenario = os.environ.get("SCENARIO", "perf-work")
item = int(os.environ.get("ITEM", "1150"))
runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
base = f"http://127.0.0.1:{port}"


def post(path, body=None):
    request = urllib.request.Request(base + path, data=json.dumps(body or {}).encode(), method="POST")
    return json.loads(urllib.request.urlopen(request, timeout=60).read() or b"{}")


def panels(open_, weights=()):
    # SidePanelSet の JSON（weights は欄と重みを交互に並べた配列）
    return json.dumps({"open": open_, "weights": list(weights), "column": 0.5})


def launch():
    """アプリを裏で起こし、窓を 1600×1000 にする。
    --no-notifications は付けない（fixtures では効かない。-ApplePersistenceIgnoreState と一緒に付けると、裏で起こしたアプリが窓を作らなかった。2026-10-21 に実測）"""
    (root / ".build/ui").mkdir(parents=True, exist_ok=True)
    log = open(root / f".build/ui/work-perf-{port}.log", "w")
    process = subprocess.Popen(
        [f"{app}/Contents/MacOS/Taskboard", "--debug-port", port, "--scenario", scenario, "-ApplePersistenceIgnoreState", "YES"],
        stdout=log, stderr=log)
    # 窓が出るまで、/window/frame は（debug の口が開く前は接続できず、開いた後は 404 で）失敗する
    for _ in range(50):
        try:
            post("/window/frame", {"width": 1600, "height": 1000})
            return process
        except Exception:
            time.sleep(0.2)
    process.terminate()
    sys.exit("アプリの窓が 10 秒待っても出ませんでした")


def run(number):
    process = launch()
    try:
        post("/window/order", {"back": True})
        post("/presentation", {"mode": "modal"})
        post("/defaults", {"key": "taskPanel.sidePanels", "value": panels(["status"])})
        post("/navigate", {"url": f"taskboard://task/fixture-studio/301"})
        time.sleep(2)

        def measure(step, action, settle):
            post("/perf/start")
            action()
            time.sleep(settle)
            print(json.dumps({"run": number, "step": step, "result": post("/perf/stop")}, ensure_ascii=False), flush=True)

        def drag(key, value):
            for i in range(60):
                post("/defaults", {"key": key, "value": value(i % 30)})
                time.sleep(0.016)

        measure("open-work", lambda: post("/side-pane", {"tab": "work"}), 2)
        measure("state-change", lambda: post("/fixture/work", {"number": 301, "id": item, "state": "doing"}), 1.5)
        measure("state-change-2", lambda: post("/fixture/work", {"number": 301, "id": item, "state": "done"}), 1.5)
        measure("drag-side-width", lambda: drag("taskPanel.sideWidth", lambda i: 440 + i * 8), 1)
        measure("drag-panel-border", lambda: drag("taskPanel.sidePanels", lambda i: panels(["status", "work"], ["status", 0.5 + i / 30, "work", 1.5 - i / 30])), 1)
    finally:
        process.terminate()
        process.wait(timeout=10)


for number in range(1, runs + 1):
    run(number)
