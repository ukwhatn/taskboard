#!/usr/bin/env python3
"""scripts/ui/chat-perf.sh の出力（1 行 1 手順の JSON）を、手順ごとに回の値を並べた表にする。

    scripts/ui/chat-perf-report.py before.jsonl [after.jsonl]

打鍵は 1 打鍵ごとの主スレッドの使用時間（p50・p95・最大）と body の回数、スクロールと待機は画面の更新間隔（p50・p95・最大）・引っかかり・主スレッドの使用率。
"""
import json
import sys


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def row(step, result):
    frames = result["frames"] if isinstance(result.get("frames"), dict) else result
    cells = []
    if "busy" in result and "perKeyP50Ms" in result["busy"]:
        b = result["busy"]
        cells.append(f"打鍵 {b['perKeyP50Ms']}/{b['perKeyP95Ms']}/{b['perKeyMaxMs']}")
    if "frameMs" in frames:
        cells.append(f"フレーム {frames['frameMs']}/{frames['p95Ms']}/{frames['maxMs']} 引っかかり {frames['hitches']}回 {frames['hitchRatio']}ms/s")
    busy = result.get("busy", {})
    overall = busy.get("overall", busy)
    if overall.get("durationMs"):
        cells.append(f"主スレッド {round(overall['busyMs'] / overall['durationMs'] * 100)}%")
    bodies = result.get("bodiesPerKey") or result.get("bodies")
    if bodies:
        cells.append("body " + " ".join(f"{k}={v}" for k, v in sorted(bodies.items()) if v))
    return " | ".join(cells)


def main():
    for path in sys.argv[1:]:
        print(f"## {path}")
        for entry in load(path):
            print(f"{entry['run']} {entry['step']:6} {row(entry['step'], entry['result'])}")


if __name__ == "__main__":
    main()
