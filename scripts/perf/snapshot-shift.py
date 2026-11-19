#!/usr/bin/env python3
"""snapshot の失敗の画像（.build/snapshots-out）を記録の画像（App/Tests/__Snapshots__）と比べ、行（横 1 列の画素）ごとに、
ずらさずに同じ行があるか、上下に何 px ずらすと同じ行があるかを数える。一覧の作りを替えて中身が上下にずれただけかを、1 枚ずつ見る前に分ける。

    python3 scripts/perf/snapshot-shift.py [--max 80] [--new DIR] [--old DIR]   既定は .build/snapshots-out と App/Tests/__Snapshots__

出力は 1 枚 1 行で「同じ行の割合、ずれた行のずれ（px）ごとの数、どちらでも合わない行の数」。合わない行が 0 なら、上下のずれだけ。
"""
import argparse
import collections
from pathlib import Path

import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("--max", type=int, default=80, help="探すずれの上限（px）")
parser.add_argument("--new", default=None, help="新しい画像の置き場（Suite 名のフォルダの親）")
parser.add_argument("--old", default=None, help="比べる元の画像の置き場")
parser.add_argument("--only", default=None, help="比べる画像の一覧（1 行 1 つ、<Suite>/<名前>.png）")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
new_dir = Path(args.new) if args.new else root / ".build/snapshots-out"
old_dir = Path(args.old) if args.old else root / "App/Tests/__Snapshots__"
failures = [new_dir / line.strip() for line in open(args.only) if line.strip()] if args.only else sorted(new_dir.rglob("*.png"))
for failure in failures:
    reference = old_dir / failure.parent.name / failure.name
    if not reference.exists():
        print(f"{failure.parent.name}/{failure.name}: 記録が無い")
        continue
    new = np.asarray(Image.open(failure).convert("RGB")).astype(np.int16)
    old = np.asarray(Image.open(reference).convert("RGB")).astype(np.int16)
    if new.shape != old.shape:
        print(f"{failure.parent.name}/{failure.name}: 大きさが違う {old.shape} → {new.shape}")
        continue
    height = new.shape[0]
    # 行を比べやすい形にする（差が 8 以下の画素は同じとみなす）
    def same(a, b):
        return np.abs(a - b).max() <= 8
    shifts = collections.Counter()
    unmatched = 0
    kept = 0
    for y in range(height):
        if same(new[y], old[y]):
            kept += 1
            continue
        # 一色の行（地だけ）はどこにでも合うので数えない
        if np.abs(new[y] - new[y][0]).max() <= 8:
            kept += 1
            continue
        found = None
        for distance in range(1, args.max + 1):
            for dy in (distance, -distance):
                source = y - dy
                if 0 <= source < height and same(new[y], old[source]):
                    found = dy
                    break
            if found is not None:
                break
        if found is None:
            unmatched += 1
        else:
            shifts[found] += 1
    top = ", ".join(f"{dy:+d}px×{count}" for dy, count in shifts.most_common(3))
    print(f"{failure.parent.name}/{failure.name}: 同じ {kept}/{height} ずれ [{top}] 合わない {unmatched}")
