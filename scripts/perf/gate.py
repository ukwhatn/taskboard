#!/usr/bin/env python3
"""性能の関門の手順（scripts/perf-gate.sh から呼ぶ）。回ごとに -O の fixtures のアプリを裏で起こし直し、debug の口を叩いて手順ごとに主スレッドの止まり
（/hitch、本番の main.hitch と同じ 100 ms 超え）を数え、スクロールの手順は表示の位置が期待どおり動いたかと、下端へ引き戻されないかを確かめる。

1 行 1 手順の JSON を標準出力に出し、最後に手順ごとの回をまたいだ要約を出す。止まりが 1 つでもあるか、位置の確かめが外れたら 1 で終わる。
"""
import argparse
import collections
import json
import pathlib
import statistics
import subprocess
import sys
import threading
import time
import urllib.request


class App:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"

    def post(self, path, body=None, timeout=600):
        data = json.dumps(body or {}).encode()
        request = urllib.request.Request(self.base + path, data=data, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")

    def get(self, path):
        with urllib.request.urlopen(self.base + path, timeout=60) as response:
            return json.loads(response.read() or b"{}")


def launch(bundle, port, log):
    """アプリを裏で直に起こし、窓ができたら後ろに回す。起こしたプロセスを返す。マウスとキーボードは動かさない"""
    executable = f"{bundle}/Contents/MacOS/Taskboard"
    process = subprocess.Popen(
        [executable, "--debug-port", str(port), "--scenario", "conversations", "-ApplePersistenceIgnoreState", "YES"],
        stdout=log, stderr=subprocess.STDOUT)
    app = App(port)

    def until(check):
        for _ in range(50):
            try:
                if check():
                    return True
            except OSError:
                pass
            time.sleep(0.2)
        return False

    def has_window():
        return bool(app.get("/menu")["windows"])

    try:
        if not until(lambda: app.get("/state") is not None):
            raise RuntimeError("測るアプリの debug の口が開かない")
        # 裏で直に起こしたアプリは最初の窓を作らない。前面に出さない open -g（reopen の知らせ）で作らせる
        subprocess.run(["open", "-g", "-a", bundle], check=True)
        until(has_window)
        # open -g が起こしたアプリを reopen の宛先と見なさないと、引数の無い 2 つ目を起こす。それはユーザーの設定と Keychain の接続先で本物の daemon に繋ぐので、
        # すぐ止めて失敗にする（Instruments が起こしたアプリで起きた）
        strays = subprocess.run(["pgrep", "-f", "-x", executable], capture_output=True, text=True).stdout.split()
        if strays:
            subprocess.run(["kill", *strays])
            raise RuntimeError(f"open -g が測るアプリでなく引数の無い 2 つ目（pid {' '.join(strays)}）を起こしたので止めた")
        if not has_window():
            raise RuntimeError("測るアプリに窓ができない")
        app.post("/window/order", {"back": True})
    except Exception:
        process.kill()
        process.wait()
        raise
    return process


class Gate:
    def __init__(self, app, args):
        self.app = app
        self.args = args
        self.rows = []

    def step(self, run, name, action):
        """action は (確かめの結果のリスト, 手順の生の結果) を返す。確かめの結果は (名前, 通ったか, 値)"""
        self.app.post("/hitch/start")
        started = time.monotonic()
        try:
            checks, detail = action()
        except Exception as error:  # 口が 404 などを返した。止まりの数は取り、手順は失敗にする
            checks, detail = [("action", False, str(error))], None
        elapsed = time.monotonic() - started
        hitch = self.app.post("/hitch/stop")
        failed = [c for c in checks if not c[1]]
        row = {
            "run": run, "step": name, "seconds": round(elapsed, 1),
            "hitches": hitch["count"], "maxMs": hitch["maxMs"], "longestMs": hitch["longestMs"][:5],
            "checks": {c[0]: {"ok": c[1], "value": c[2]} for c in checks},
            "ok": hitch["count"] == 0 and not failed,
        }
        if self.args.verbose and detail is not None:
            row["detail"] = detail
        self.rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
        return detail

    # MARK: 会話

    def prepare_conversation(self):
        """fixtures の差し替えと窓の大きさ・開き方。人の操作ではないので止まりを数えない"""
        self.app.post("/scenario", {"name": "conversations"})
        time.sleep(1.5)
        self.app.post("/window/frame", {"width": 1600, "height": 1000})
        self.app.post("/window/order", {"back": True})
        self.app.post("/presentation", {"mode": self.args.presentation})
        time.sleep(0.5)

    def open_conversation_cold(self):
        """起こし直した直後に初めて会話へ移る。型の情報・記号・部品をまだ一度も組んでいない回"""
        self.app.post("/navigate", {"url": f"taskboard://conversation/fixture-studio/{self.args.conversation}"})
        time.sleep(1.5)
        return [], None

    def open_conversation(self):
        self.app.post("/task/close")
        time.sleep(0.5)
        self.app.post("/navigate", {"url": f"taskboard://conversation/fixture-studio/{self.args.conversation}"})
        time.sleep(1.5)
        result = self.app.post("/bench/conversation", {"messages": self.args.messages, "chunk": 10, "streamSeconds": 0})
        # 流し込んだ後の下端への寄せが落ち着くまで
        time.sleep(2)
        return [("messages", result["messages"] >= self.args.messages, result["messages"])], result

    def scroll(self, **body):
        return self.app.post("/conversation/scroll", {"intervalMs": 8, "back": False, **body})

    # 端まではトラックパッドの速いなでで送る。phase の無いマウスのホイールは AppKit が動きつきで送り、動きを始めたときの枠で止まり先を決めて続けて回す間は
    # 決め直さないので、fixtures が一覧の上の帯（48 pt）を出し入れすると下端の 48 pt 手前で止まる回があった（回し直せば着く。マウスのホイールは small-wheel で見る）
    def scroll_to_top(self):
        result = self.scroll(dy=150, steps=6000, untilEdge=True, trackpad=True)
        before, turned = result["position"]["before"], result["position"]["turned"]
        return [
            ("moved", before["offset"] - turned["offset"] > 2000, round(before["offset"] - turned["offset"])),
            ("atTop", turned["offset"] <= 1, round(turned["offset"])),
        ], result

    def scroll_to_bottom(self):
        result = self.scroll(dy=-150, steps=6000, untilEdge=True, trackpad=True)
        before, turned = result["position"]["before"], result["position"]["turned"]
        return [
            ("moved", turned["offset"] - before["offset"] > 2000, round(turned["offset"] - before["offset"])),
            ("atBottom", turned["gap"] <= 1, round(turned["gap"])),
        ], result

    def settle_at_bottom(self):
        self.scroll(dy=-150, steps=400, untilEdge=True, trackpad=True)
        time.sleep(0.5)

    def small_wheel(self):
        """下端から、phase の無いホイールで 6 pt ずつ 10 回（60 pt）上へ送り、1 秒待っても戻されていないこと"""
        self.settle_at_bottom()
        result = self.scroll(dy=6, steps=10, intervalMs=16, settleMs=1000)
        position = result["position"]
        return [
            ("startAtBottom", position["before"]["gap"] <= 1, round(position["before"]["gap"])),
            ("moved", position["after"]["gap"] >= 50, round(position["after"]["gap"])),
            ("notPulledBack", position["settled"]["gap"] >= 50, round(position["settled"]["gap"])),
        ], result

    def small_trackpad(self):
        """下端から、トラックパッドの小さななで（3 pt の changed を 8 回と惰性。1 回で 40 pt ほど）を 6 回続けて入れ、どのなでの後も下端へ戻されず、離れていくこと。
        見るのは表示の位置（offset。上へ送るほど小さい）。下端までの距離は、fixtures が 2 秒ごとにセッションの状態を回して一覧の上の帯（48 pt）を出し入れすると、
        一覧の高さが替わって 40 pt ほど増減する（なでが帯の出し入れに重なると、戻されていないのに下端の近くに見えた）。引き戻されると offset が下端の値へ増える"""
        self.settle_at_bottom()
        results = []
        for _ in range(6):
            result = self.scroll(dy=3, steps=8, intervalMs=16, trackpad=True, settleMs=300)
            results.append(result["position"])
        offsets = [round(results[0]["before"]["offset"])] + [round(r["settled"]["offset"]) for r in results]
        time.sleep(1)
        final = round(self.app.post("/conversation/scroll", {"dy": 0, "steps": 0, "back": False})["position"]["before"]["offset"])
        return [
            ("startAtBottom", results[0]["before"]["gap"] <= 1, round(results[0]["before"]["gap"])),
            ("neverPulledBack", all(b <= a + 2 for a, b in zip(offsets, offsets[1:])), offsets),
            ("moved", offsets[0] - offsets[-1] >= 150, offsets[0] - offsets[-1]),
            ("notPulledBack", final <= offsets[-1] + 2, final),
        ], results

    def in_background(self, path, body):
        thread = threading.Thread(target=lambda: self.app.post(path, body), daemon=True)
        thread.start()
        return thread

    def scroll_while_streaming(self):
        """生成中の返答が流れている間に、上へ 2,400 pt 送って戻す"""
        self.settle_at_bottom()
        stream = self.in_background("/bench/stream", {"seconds": 8, "deltaMs": 50})
        time.sleep(1)
        result = self.app.post("/conversation/scroll", {"dy": 20, "steps": 120, "intervalMs": 16, "back": True})
        stream.join()
        before, turned = result["position"]["before"], result["position"]["turned"]
        return [("movedUp", before["offset"] - turned["offset"] >= 1800, round(before["offset"] - turned["offset"]))], result

    def mouse(self, region, streaming=False):
        stream = self.in_background("/bench/stream", {"seconds": 6, "deltaMs": 50}) if streaming else None
        result = self.app.post("/mouse/move", {"count": 600, "intervalMs": 8, "region": region})
        if stream:
            stream.join()
        return [("region", result["region"] == region, result["region"])], result

    def big_table(self):
        """入力欄にフォーカスを置いてから、50 行×6 列の表を含む発言を届け、会話の一覧の行に NSTextView が無いこと。一覧の行を組む途中で NSTextView を作ると、
        作るたびにフォーカスのある入力欄の入力メソッドと同期を取り、日本語入力の IMK の答えを待つ入れ子のループの中で止まった（升目ごとに作っていた）。
        fixtures のアプリは前面に出さず入力ソースも替えないので、止まり自体は起きない。起きる元の NSTextView の数で見る"""
        self.app.post("/conversation/composer", {"focus": True})
        result = self.app.post("/bench/table", {"rows": 50, "columns": 6})
        return [("noTextViewsInList", result["listTextViews"] == 0, result["listTextViews"])], result

    def composer(self, length):
        """入力欄に length 字の長い下書きを貼ったのと同じ経路（insertText）で入れ、続けて 3 字打つ。打った後の入力欄の字数を確かめ、入力欄を空に戻す"""
        line = ("長い下書きの文を入れて、入力欄が重くならないかを確かめる。" * 3)[:79] + "\n"
        draft = (line * (length // len(line) + 1))[:length]
        result = self.app.post("/conversation/fill", {"text": draft, "settleMs": 1500, "then": "足す文", "gapMs": 80, "insert": True, "keep": True})
        written = len(self.app.get("/conversation/composer").get("text", ""))
        self.app.post("/conversation/type", {"text": "", "gapMs": 0})
        return [("written", written >= length + 3, written)], result

    def split_open(self):
        """開いている長い会話の右に、同じタスクの別の会話を 2 つ目として並べる（札を ⌘ を押しながら押したのと同じ）。窓の会話の一覧が 2 つになること"""
        result = self.app.post("/task/split", {"conversation": self.args.second})
        time.sleep(1)
        return [("lists", result["lists"] == 2, result["lists"])], result

    def split_scroll(self):
        """2 つ並べたまま、左の長い会話を上の端まで送ってから下の端へ戻す（一覧が 2 つあっても、送る間に止まらないこと）"""
        up = self.scroll(dy=150, steps=6000, untilEdge=True, trackpad=True)
        down = self.scroll(dy=-150, steps=6000, untilEdge=True, trackpad=True)
        moved = up["position"]["before"]["offset"] - up["position"]["turned"]["offset"]
        return [
            ("moved", moved > 2000, round(moved)),
            ("atBottom", down["position"]["turned"]["gap"] <= 1, round(down["position"]["turned"]["gap"])),
        ], {"up": up, "down": down}

    # MARK: ボード

    def open_board(self):
        self.app.post("/scenario", {"name": "stress"})
        time.sleep(2)
        self.app.post("/task/close")
        # ボードの手順は列の形のホームで測る（/board/scroll は列の形の面を送る）
        self.app.post("/home/layout", {"layout": "columns"})
        self.app.post("/window/frame", {"width": 1512, "height": 945})
        self.app.post("/window/order", {"back": True})
        time.sleep(1.5)

    def bench(self, kind, count, board=None):
        result = self.app.post("/bench", {"kind": kind, "count": count, "gapMs": 300, **({"board": board} if board else {})})
        samples = result.get("count", 0) if kind != "open-close" else result["open"].get("count", 0)
        return [("samples", samples > 0, samples)], result

    def sidebar_toggle(self):
        """サイドバーを 5 回閉じて開き、毎回開閉が替わったこと"""
        states = [self.app.post("/sidebar/toggle")["collapsed"] for _ in range(10)]
        return [("toggled", all(a != b for a, b in zip(states, states[1:])), states)], None

    def sidebar_switch_many(self):
        """案件 8 つの fixtures で「すべての案件」→ 各案件 → 「すべての案件」と選ぶ（全部の帯を組む向きと 1 つに絞る向きの両方）"""
        self.app.post("/scenario", {"name": "perf-many"})
        time.sleep(3)
        self.app.post("/task/close")
        time.sleep(1)
        self.app.post("/hitch/start")  # 差し替えの分は数えない
        return self.bench("sidebar", 10)

    def board_scroll(self):
        self.app.post("/board/scroll", {"dy": 30, "steps": 120, "interval": 16})
        return [], None

    # MARK: 本番の量（prod-local+prod-studio+prod-third。scripts/fixtures/make-production.py が 3 台の state から作る）

    PROD = "prod-local+prod-studio+prod-third"

    def has_prod(self):
        """prod の fixtures は作者の Mac だけで作り、repo に入れない（.gitignore）。無ければ prod の手順を飛ばす"""
        fixtures = pathlib.Path(__file__).resolve().parents[2] / "App/Fixtures"
        missing = [f"{name}.json" for name in self.PROD.split("+") if not (fixtures / f"{name}.json").exists()]
        if missing:
            print(f"prod の手順を飛ばす: App/Fixtures に {', '.join(missing)} が無い（scripts/fixtures/make-production.py で作る）", file=sys.stderr)
        return not missing

    def prod_targets(self):
        """Studio の一番大きい案件と、会話の一番多いタスクの新しい会話"""
        studio = json.loads((pathlib.Path(__file__).resolve().parents[2] / "App/Fixtures/prod-studio.json").read_text())
        board = collections.Counter(t["boardID"] for t in studio["tasks"]).most_common(1)[0][0]
        by_task = collections.defaultdict(list)
        for c in studio["conversations"]:
            if c.get("taskNumber") is not None:
                by_task[c["taskNumber"]].append(c)
        task = max(by_task, key=lambda n: len(by_task[n]))
        conversation = max(by_task[task], key=lambda c: c["updatedAt"])["id"]
        return studio["machine"]["id"], board, conversation

    def open_prod(self):
        self.app.post("/scenario", {"name": self.PROD})
        time.sleep(4)
        self.app.post("/task/close")
        self.app.post("/window/frame", {"width": 1512, "height": 945})
        self.app.post("/window/order", {"back": True})
        # 本番の量はホームの既定の形（見張り盤）で測る
        self.app.post("/home/layout", {"layout": "conversations"})
        self.app.post("/navigate", {"url": "taskboard://boards"})
        time.sleep(3)

    def idle(self, seconds=12, stream=False):
        """人が画面を見ている間。受信箱の見回り（2 秒ごと）が回り、daemon の知らせが 1 秒に 2 通届き、stream なら開いている会話に生成中の差分が流れる"""
        before = self.app.get("/cpu")["ms"]
        threads = [self.in_background("/fixture/flow", {"seconds": seconds, "perSecond": 2})]
        if stream:
            threads.append(self.in_background("/bench/stream", {"seconds": seconds - 2, "deltaMs": 50}))
        for thread in threads:
            thread.join()
        # 止まりは閾値の近くで回ごとに数が揺れるので、直す前と後は主スレッドの CPU 時間でも比べる
        return [("cpuMs", True, round(self.app.get("/cpu")["ms"] - before))], None

    def open_prod_chat(self, presentation):
        """開き方を替えて、会話の多いタスクの会話を開き、600 件を流す（止まりを数えない）"""
        machine, _, conversation = self.prod_targets()
        self.app.post("/task/close")
        self.app.post("/presentation", {"mode": presentation})
        time.sleep(0.5)
        self.app.post("/navigate", {"url": f"taskboard://conversation/{machine}/{conversation}"})
        time.sleep(1.5)
        self.app.post("/bench/conversation", {"messages": 600, "chunk": 10, "streamSeconds": 0})
        time.sleep(2)

    def prod_chat(self, presentation):
        self.open_prod_chat(presentation)
        self.app.post("/hitch/start")  # 開いて流し込んだ分は数えない
        # 生成中の差分は流さない。流すと描き直しがまとまり、本番で会話を読んでいる間に出ていた止まりが出なくなる
        return self.idle()

    def run(self, run, only):
        """only は手順の名前の頭（chat・chat.scroll・board など）。合う手順だけを回し、その画面を開く手順は合う手順があるときだけ回す"""
        chat = [
            ("chat.scroll.top", self.scroll_to_top),
            ("chat.scroll.bottom", self.scroll_to_bottom),
            ("chat.scroll.small-wheel", self.small_wheel),
            ("chat.scroll.small-trackpad", self.small_trackpad),
            ("chat.scroll.streaming", self.scroll_while_streaming),
            ("chat.mouse", lambda: self.mouse("list")),
            ("chat.mouse.streaming", lambda: self.mouse("list", streaming=True)),
            ("chat.table", self.big_table),
            ("chat.composer.4000", lambda: self.composer(4000)),
            ("chat.composer.20000", lambda: self.composer(20000)),
            ("chat.split.open", self.split_open),
            ("chat.split.scroll", self.split_scroll),
        ]
        board = [
            ("board.mouse", lambda: self.mouse("window")),
            ("board.scroll", self.board_scroll),
            ("board.task-switch", lambda: self.bench("task-switch", 10)),
            ("board.open-close", lambda: self.bench("open-close", 10)),
            ("board.sidebar-switch", lambda: self.bench("sidebar", 12)),
            ("board.sidebar-toggle", self.sidebar_toggle),
            ("board.sidebar-switch.many", self.sidebar_switch_many),
        ]
        prod_board = lambda: self.prod_targets()[1]
        prod = [
            ("prod.board.idle", self.idle),
            ("prod.board.mouse", lambda: self.mouse("window")),
            ("prod.board.sidebar-switch", lambda: self.bench("sidebar", 12)),
            ("prod.board.task-switch", lambda: self.bench("task-switch", 10, board=prod_board())),
            ("prod.board.open-close", lambda: self.bench("open-close", 10, board=prod_board())),
            ("prod.task.full.chat", lambda: self.prod_chat("full")),
            ("prod.task.modal.chat", lambda: self.prod_chat("modal")),
            ("prod.task.side.chat", lambda: self.prod_chat("side")),
        ]
        chosen = lambda steps: [s for s in steps if s[0].startswith(only)]
        if chosen(chat) or "chat.open".startswith(only):
            self.prepare_conversation()
            self.step(run, "chat.open.cold", self.open_conversation_cold)
            self.step(run, "chat.open", self.open_conversation)
            for name, action in chosen(chat):
                self.step(run, name, action)
        if chosen(board):
            self.open_board()
            for name, action in chosen(board):
                self.step(run, name, action)
        if chosen(prod) and self.has_prod():
            self.open_prod()
            for name, action in chosen(prod):
                self.step(run, name, action)

    def summary(self):
        steps = list(dict.fromkeys(r["step"] for r in self.rows))
        failed = False
        print("\n手順                          判定  止まりの数（各回）   最大 ms（各回）      確かめ", file=sys.stderr)
        for step in steps:
            rows = [r for r in self.rows if r["step"] == step]
            ok = all(r["ok"] for r in rows)
            failed = failed or not ok
            verdict = "通過" if ok else "失敗"
            counts = ",".join(str(r["hitches"]) for r in rows)
            maxes = [r["maxMs"] for r in rows]
            spread = f"{','.join(map(str, maxes))}（中央 {statistics.median(maxes):g}）"
            broken = sorted({name for r in rows for name, c in r["checks"].items() if not c["ok"]})
            cpu = [r["checks"]["cpuMs"]["value"] for r in rows if "cpuMs" in r["checks"]]
            note = "外れ: " + ",".join(broken) if broken else f"主スレッドの CPU {','.join(map(str, cpu))} ms" if cpu else ""
            print(f"{step:30}{verdict:4}  {counts:18}  {spread:20} {note}", file=sys.stderr)
        return failed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="測る Taskboard.app")
    parser.add_argument("--log", required=True, help="アプリの出力を書くファイル")
    parser.add_argument("--port", type=int, default=5795)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--messages", type=int, default=1500)
    parser.add_argument("--conversation", default="c-tools")
    parser.add_argument("--second", default="c-gen", help="右に並べる会話（--conversation と同じタスクのもの）")
    parser.add_argument("--presentation", default="modal")
    parser.add_argument("--only", default="", help="この名前で始まる手順だけを回す（chat・chat.scroll・board など）")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    gate = Gate(App(args.port), args)
    with open(args.log, "w") as log:
        for run in range(1, args.runs + 1):
            # 回ごとに起こし直す（chat.open.cold を毎回、初めて組む回にする）
            process = launch(args.app, args.port, log)
            try:
                gate.run(run, args.only)
            finally:
                process.terminate()
                process.wait()
    sys.exit(1 if gate.summary() else 0)


if __name__ == "__main__":
    main()
