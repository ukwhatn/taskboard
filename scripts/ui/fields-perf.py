#!/usr/bin/env python3
"""複数行の欄に長い文を入れたときの主スレッドの止まりを、欄ごとに測る（docs/development.md「アプリの動作確認」）。

fixtures のアプリを裏で直に起こし（前面に出さない）、欄を開いて POST /field/fill で文（docs/development.md を繰り返した、改行の混ざった文）を
貼り付けと同じ経路で一度に入れ、続けて 3 字を 80 ms おきに打つ（フォーカスは入れる 1.5 秒前に置き、キーボードが出る間を数えない）。欄は GET /fields の並び順で選ぶ（直す前の TextField は名前を持たないので、前後の版で同じ欄を選べる）。
fixtures で書き込めず開けない欄（題とメモのその場の編集・コメント・返信・待ち理由）は、部品のまま載せた測りの欄の窓（POST /lab/field）で測る。
--simulator を渡すと iPhone・iPad のシミュレータで測る（--app を入れてから起こす。Form の一覧は画面に出た行の欄しか作らないので、下の欄は POST /field/scroll で送りながら探す。
文書の画面の質問とレビューの総括は、iPhone と iPad ではシートの先で debug の口から開けないので測らない）。

  python3 scripts/ui/fields-perf.py [--app APP] [--port 5799] [--sizes 4000,20000] [--rounds 1] [--only 欄の名前,…] [--simulator UDID]

1 行 1 回の JSON（欄・字数・fillMaxMs は一番長くふさがった時間・fillBusyMs は入れてからの 3 秒の使用時間・keyMaxMs と keyP50Ms は打鍵ごと）を出し、
最後に欄と字数ごとの中央値の表を出す。-O のビルドの値を比べるときは、ほかのビルドが動いていない時に回す。
"""

import argparse
import json
import os
import statistics
import subprocess
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


class App:
    def __init__(self, path, port):
        self.path, self.base, self.process = path, f"http://127.0.0.1:{port}", None
        self.port = port

    def wait(self, scenario):
        # ほかのビルドが動いていると起動が数十秒かかることがある
        for _ in range(300):
            try:
                self.get("/state")
                return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.2)
        raise RuntimeError(f"{scenario} のアプリが 60 秒で起きない")

    def post(self, route, body=None, timeout=60):
        request = urllib.request.Request(self.base + route, data=json.dumps(body or {}).encode(), method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read()
        return json.loads(data) if data else None

    def get(self, route):
        with urllib.request.urlopen(self.base + route, timeout=60) as response:
            return json.loads(response.read())

    def launch(self, scenario):
        self.stop()
        log = open(os.path.join(ROOT, ".build", "ui", f"fields-perf-{self.port}.log"), "w")
        self.process = subprocess.Popen(
            [os.path.join(self.path, "Contents/MacOS/Taskboard"), "--debug-port", str(self.port), "--scenario", scenario, "--no-notifications", "-ApplePersistenceIgnoreState", "YES"], stdout=log, stderr=subprocess.STDOUT)
        self.wait(scenario)
        self.post("/window/order", {"back": True})
        self.post("/window/frame", {"width": 1600, "height": 1000})
        self.post("/window/order", {"back": True})
        time.sleep(1.5)

    def stop(self):
        if self.process:
            self.process.terminate()
            self.process.wait()
            self.process = None

    def fields(self):
        return self.get("/fields")["fields"]


class SimulatorApp(App):
    """シミュレータのアプリ。起こすたびに前のプロセスを止めて同じ bundle を起こし直す"""

    BUNDLE = "uk.whatn.taskboard.ios"

    def __init__(self, path, port, udid):
        super().__init__(path, port)
        self.udid = udid
        subprocess.run(["xcrun", "simctl", "install", udid, path], check=True)

    def launch(self, scenario):
        subprocess.run(
            ["xcrun", "simctl", "launch", "--terminate-running-process", self.udid, self.BUNDLE, "--debug-port", str(self.port), "--scenario", scenario,
             "--no-notifications"], check=True, stdout=subprocess.DEVNULL)
        time.sleep(1)
        self.wait(scenario)
        time.sleep(2)

    def stop(self):
        subprocess.run(["xcrun", "simctl", "terminate", self.udid, self.BUNDLE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def open_new_task(app):
    app.post("/new-task", {"title": "長い文の確かめ"})
    time.sleep(1.2)


def open_settings(app):
    app.post("/settings", {"section": "boards", "board": "fixture-board"})
    time.sleep(2)


def open_document(app):
    app.post("/presentation", {"mode": "modal"})
    app.post("/navigate", {"url": "taskboard://task/fixture-studio/120"})
    time.sleep(1.5)
    app.post("/doc/open", {"id": 1, "number": 120})
    time.sleep(2.5)


def open_conversation(app):
    app.post("/navigate", {"url": "taskboard://conversation/fixture-studio/c-gen"})
    time.sleep(4)


def open_lab(kind):
    def open_field(app):
        app.post("/lab/field", {"kind": kind, "width": 400})
        time.sleep(0.5)
    return open_field


def nth(index):
    return lambda app: index


def lab_field(app):
    return next(i for i, f in enumerate(app.fields()) if f["window"] == "測りの欄")


# iPhone・iPad の複数行の欄の種類（直す前の縦に伸びる TextField の中身と、MultilineTextField の UITextView）
VERTICAL = {"VerticalTextView", "MultilineUITextView"}


def first_vertical(app):
    """iPhone・iPad の複数行の欄の一番上"""
    return next(i for i, f in enumerate(app.fields()) if f["kind"] in VERTICAL)


def scrolled(chars):
    """iPhone・iPad で、字数が chars の複数行の欄（fixtures の起動プロンプトの既定の文）が出るまで下へ送る"""
    def pick(app):
        for _ in range(30):
            found = [i for i, f in enumerate(app.fields()) if f["kind"] in VERTICAL and f["chars"] == chars]
            if found:
                # 見える所まで送るだけだと、iPad では欄が下の帯（キャンセル・保存）の裏に残ってフォーカスを置けない。上の方まで送る
                app.post("/field/scroll", {"index": found[0], "dy": app.fields()[found[0]]["frame"]["y"] - 200})
                return next(i for i, f in enumerate(app.fields()) if f["kind"] in VERTICAL and f["chars"] == chars)
            app.post("/field/scroll", {"dy": 400})
        raise RuntimeError(f"{chars} 字の欄が出ない")
    return pick


# (欄の名前, scenario, 開き方, 欄の選び方)。並び順は直す前と後で同じ（GET /fields の並び）
CASES = [
    ("起票のメモ", "stress", open_new_task, nth(2)),
    ("起票の起動プロンプト", "stress", open_new_task, nth(4)),
    ("列の説明", "stress", open_settings, nth(2)),
    ("案件の起動プロンプト", "stress", open_settings, nth(17)),
    ("列の起動プロンプト", "stress", open_settings, nth(18)),
    ("文書の質問の自由記述", "stress", open_document, nth(0)),
    ("レビューの総括", "stress", open_document, nth(2)),
    ("題のその場の編集", "stress", open_lab("title"), lab_field),
    ("メモのその場の編集", "stress", open_lab("memo"), lab_field),
    ("コメント", "stress", open_lab("comment"), lab_field),
    ("返信", "stress", open_lab("reply"), lab_field),
    ("待ち理由", "stress", open_lab("blocker"), lab_field),
    ("会話の入力欄", "conversations", open_conversation, nth(0)),
]

# iPhone・iPad。設定の列の説明は iPhone では区画ごとの欄、iPad では Mac と同じ表の欄
IOS_CASES = [
    ("起票のメモ", "stress", open_new_task, first_vertical),
    ("起票の起動プロンプト", "stress", open_new_task, scrolled(147)),
    ("列の説明", "stress", open_settings, first_vertical),
    ("案件の起動プロンプト", "stress", open_settings, scrolled(147)),
    ("列の起動プロンプト", "stress", open_settings, scrolled(38)),
    ("題のその場の編集", "stress", open_lab("title"), lab_field),
    ("メモのその場の編集", "stress", open_lab("memo"), lab_field),
    ("コメント", "stress", open_lab("comment"), lab_field),
    ("返信", "stress", open_lab("reply"), lab_field),
    ("待ち理由", "stress", open_lab("blocker"), lab_field),
    ("会話の入力欄", "conversations", open_conversation, nth(0)),
]


def measure(app, open_field, pick, text):
    open_field(app)
    index = pick(app)
    # 先にフォーカスを置いてキーボードが出きるのを待つ（iPhone・iPad はキーボードが出る間の画面の組み直しが 100〜170 ms あり、文の長さによらない）
    app.post("/field/focus", {"index": index})
    time.sleep(1.5)
    result = app.post("/field/fill", {"index": index, "text": text, "settleMs": 3000, "then": "あいう", "gapMs": 80}, timeout=1800)
    fill, typed = result["fill"], result["typed"]
    return {
        "kind": result["kind"], "chars": result["chars"], "fillMaxMs": fill.get("spanMaxMs"), "fillBusyMs": fill.get("busyMs"),
        "fillWallMs": result["fillWallMs"], "keyMaxMs": typed.get("perKeyMaxMs"), "keyP50Ms": typed.get("perKeyP50Ms"),
    }


def main():
    parser = argparse.ArgumentParser()
    # 省くと -O のビルド（Mac は .build/DerivedDataOpt、シミュレータは .build/DerivedData-iOS）
    parser.add_argument("--app", default="")
    parser.add_argument("--port", type=int, default=5799)
    parser.add_argument("--sizes", default="4000,20000")
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--only", default="")
    parser.add_argument("--simulator", default="")
    args = parser.parse_args()
    if not args.app:
        products = ".build/DerivedData-iOS/Build/Products/Debug-iphonesimulator" if args.simulator else ".build/DerivedDataOpt/Build/Products/Debug"
        args.app = os.path.join(ROOT, products, "Taskboard.app")
    os.makedirs(os.path.join(ROOT, ".build", "ui"), exist_ok=True)
    unit = open(os.path.join(ROOT, "docs", "development.md")).read()
    sizes = [int(s) for s in args.sizes.split(",")]
    only = [s for s in args.only.split(",") if s]
    cases = [c for c in (IOS_CASES if args.simulator else CASES) if not only or c[0] in only]
    app = SimulatorApp(args.app, args.port, args.simulator) if args.simulator else App(args.app, args.port)
    rows = []
    try:
        for round_ in range(args.rounds):
            for name, case_scenario, open_field, pick in cases:
                for size in sizes:
                    # 欄ごとに起こし直す（前の欄の文と開いた画面を残さない）
                    app.launch(case_scenario)
                    row = {"round": round_ + 1, "field": name, "size": size, **measure(app, open_field, pick, (unit * (size // len(unit) + 1))[:size])}
                    rows.append(row)
                    print(json.dumps(row, ensure_ascii=False), flush=True)
    finally:
        app.stop()
    print("欄\t字数\tfillMaxMs\tfillBusyMs\tkeyMaxMs\t回数")
    for name, *_ in cases:
        for size in sizes:
            picked = [r for r in rows if r["field"] == name and r["size"] == size]
            med = lambda key: statistics.median(r[key] or 0 for r in picked)
            print(f"{name}\t{size}\t{med('fillMaxMs'):.0f}\t{med('fillBusyMs'):.0f}\t{med('keyMaxMs'):.0f}\t{len(picked)}")


if __name__ == "__main__":
    main()
