#!/usr/bin/env python3
"""xctrace の Time Profiler の記録で、ある関数を通った main の thread のサンプルを、その外側で一番近い画面のコードの関数ごとに数える。
SwiftUI のレイアウトや描画の関数には view の名前が出ないので、どの画面の部品の下で時間を使ったかをこれで見る。

    python3 scripts/perf/frame-owners.py run.trace --under 'SizeFittingState.applyChildren' [--module Taskboard] [--limit 30]
    python3 scripts/perf/frame-owners.py run.trace --count 'LazyVStack' --count 'NSTextView'   # その名前を含む関数を通ったサンプルの数（--under と組むと、その中で通った数）

--under を省くと、すべてのサンプルを葉に一番近い画面のコードの関数で数える。
"""

import argparse
import collections
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("trace")
parser.add_argument("--under", default=None)
parser.add_argument("--count", action="append", default=[])
parser.add_argument("--module", default="Taskboard")
parser.add_argument("--limit", type=int, default=30)
parser.add_argument("--chain", type=int, default=0, help="--under の一致から外側へ、この数の関数の並びをよく出る順に出す")
parser.add_argument("--thread", default="Main Thread")
parser.add_argument("--min-burst", type=float, default=0, help="主スレッドのサンプルが 2 ms より空かずに続いた区間のうち、この ms 以上のもの（引っかかり）だけを数える")
args = parser.parse_args()

with tempfile.TemporaryDirectory() as tmp:
    out = Path(tmp) / "profile.xml"
    subprocess.run(
        ["xcrun", "xctrace", "export", "--input", args.trace, "--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', "--output", str(out)],
        check=True, stdout=subprocess.DEVNULL)
    root = ET.parse(out).getroot()

by_id = {element.attrib["id"]: element for element in root.iter() if "id" in element.attrib}


def resolve(element):
    return by_id.get(element.attrib["ref"], element) if "ref" in element.attrib else element


rows = []
for row in root.iter("row"):
    thread = row.find("thread")
    if thread is None or args.thread not in resolve(thread).attrib.get("fmt", ""):
        continue
    time = row.find("sample-time")
    rows.append((int(resolve(time).text) if time is not None else 0, row))
rows.sort(key=lambda item: item[0])
# 続いた区間（隣のサンプルとの間が 2 ms 以下）ごとに長さを出し、--min-burst に満たない区間のサンプルを外す
kept_rows = []
bursts = 0
index = 0
while index < len(rows):
    end = index
    while end + 1 < len(rows) and rows[end + 1][0] - rows[end][0] <= 2_000_000:
        end += 1
    length = (rows[end][0] - rows[index][0]) / 1_000_000
    if length >= args.min_burst:
        bursts += 1
        kept_rows += [row for _, row in rows[index:end + 1]]
    index = end + 1

owners = collections.Counter()
chains = collections.Counter()
counts = collections.Counter()
total = matched = 0
for row in kept_rows:
    backtrace = row.find("tagged-backtrace")
    if backtrace is None:
        backtrace = row.find("backtrace")
    if backtrace is None:
        continue
    frames = []
    for frame in resolve(backtrace).findall("frame"):
        frame = resolve(frame)
        binary = frame.find("binary")
        frames.append((frame.attrib.get("name", "?"), resolve(binary).attrib.get("name", "") if binary is not None else ""))
    if not frames:
        continue
    total += 1
    # frames は葉が先頭。--under の一番内側の一致から外側（根の方）へ、最初の画面のコードの関数を探す
    start = 0
    if args.under:
        hits = [i for i, (symbol, _) in enumerate(frames) if args.under in symbol]
        if not hits:
            continue
        start = hits[0]
    matched += 1
    # --under があれば、その中（葉の側）で通ったものだけを数える
    inside = frames[:start + 1] if args.under else frames
    for name in args.count:
        if any(name in symbol for symbol, _ in inside):
            counts[name] += 1
    owner = next((symbol for symbol, binary in frames[start:] if args.module in binary and symbol not in ("main", "static TaskboardApp.$main()")), "(画面のコードの外)")
    owners[owner] += 1
    if args.chain:
        chains[" ← ".join(symbol[:70] for symbol, _ in frames[start:start + args.chain])] += 1

print(f"samples on {args.thread!r}: {total}" + (f", under {args.under!r}: {matched}" if args.under else "")
      + (f"（{args.min_burst:g} ms 以上続いた {bursts} 区間）" if args.min_burst else ""))
for name in args.count:
    print(f"{counts[name]:6d}  通った: {name}")
if not args.count:
    print("\n== 外側で一番近い画面のコード")
    for symbol, count in owners.most_common(args.limit):
        print(f"{count:6d}  {symbol[:160]}")
if args.chain:
    print("\n== 外側への並び")
    for chain, count in chains.most_common(8):
        print(f"{count:6d}  {chain}")
