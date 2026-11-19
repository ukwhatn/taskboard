#!/usr/bin/env python3
"""xctrace の Time Profiler の記録から、main の thread で時間を使った関数を集計する。

    xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 15s --output run.trace
    python3 scripts/perf/top-frames.py run.trace [--module Taskboard] [--limit 40]

自分を含む時間（inclusive）と自分だけの時間（self）を、サンプルの数（1 サンプル = 1 ms）で並べる。
--module を渡すと、その名前を含む binary の関数だけを数える（SwiftUI の中の関数を除いて、どの画面のコードが重いかを見る）。
"""

import argparse
import collections
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("trace")
parser.add_argument("--module", default=None)
parser.add_argument("--limit", type=int, default=40)
parser.add_argument("--thread", default="Main Thread")
args = parser.parse_args()

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "profile.xml"
    subprocess.run(
        ["xcrun", "xctrace", "export", "--input", args.trace, "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", str(out)],
        check=True, stdout=subprocess.DEVNULL)
    root = ET.parse(out).getroot()

# xctrace は同じ要素を 2 回目から ref で指す
by_id = {}
for element in root.iter():
    if "id" in element.attrib:
        by_id[element.attrib["id"]] = element


def resolve(element):
    return by_id.get(element.attrib["ref"], element) if "ref" in element.attrib else element


inclusive = collections.Counter()
selfs = collections.Counter()
total = 0
for row in root.iter("row"):
    thread = row.find("thread")
    if thread is None:
        continue
    thread = resolve(thread)
    name = thread.attrib.get("fmt", "")
    if args.thread and args.thread not in name:
        continue
    backtrace = row.find("tagged-backtrace")
    if backtrace is None:
        backtrace = row.find("backtrace")
    if backtrace is None:
        continue
    backtrace = resolve(backtrace)
    frames = []
    for frame in backtrace.findall("frame"):
        frame = resolve(frame)
        binary = frame.find("binary")
        binary_name = resolve(binary).attrib.get("name", "") if binary is not None else ""
        frames.append((frame.attrib.get("name", "?"), binary_name))
    if not frames:
        continue
    total += 1
    seen = set()
    kept = [f for f in frames if args.module is None or args.module in f[1]]
    for symbol, _ in kept:
        if symbol not in seen:
            inclusive[symbol] += 1
            seen.add(symbol)
    if kept:
        selfs[kept[0][0]] += 1

print(f"samples on {args.thread!r}: {total}")
print("\n== inclusive")
for symbol, count in inclusive.most_common(args.limit):
    print(f"{count:6d}  {symbol[:160]}")
print("\n== self")
for symbol, count in selfs.most_common(args.limit):
    print(f"{count:6d}  {symbol[:160]}")
