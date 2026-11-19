#!/usr/bin/env python3
"""App/Fixtures/stress.json を元に、案件とタスクを増やした App/Fixtures/perf-many.json を作る（タスクの切替やボードの描画を、本番に近いカードの数で測るため）。

    python3 scripts/perf/make-many-fixture.py [--boards 8] [--tasks 600]

案件は stress の案件の列を写して増やし、タスクは stress のタスクを順に写して番号と案件を振り直す。
セッション・作業項目・文書などは元の番号のタスクに付いたまま残す（元の 72 件の番号は変えない）。
"""

import argparse
import copy
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = root / "App/Fixtures/stress.json"
target = root / "App/Fixtures/perf-many.json"

parser = argparse.ArgumentParser()
parser.add_argument("--boards", type=int, default=8)
parser.add_argument("--tasks", type=int, default=600)
args = parser.parse_args()

state = json.loads(source.read_text())
base_board = state["boards"][0]
boards = [base_board]
for index in range(1, args.boards):
    board = copy.deepcopy(base_board)
    board["id"] = f"perf-board-{index}"
    board["name"] = f"計測用の案件 {index}"
    board["position"] = index
    boards.append(board)

originals = state["tasks"]
tasks = list(originals)
next_number = max(task["number"] for task in originals) + 1
while len(tasks) < args.tasks:
    template = originals[(len(tasks) - len(originals)) % len(originals)]
    task = copy.deepcopy(template)
    task["number"] = next_number
    task["boardID"] = boards[next_number % len(boards)]["id"]
    task["title"] = f"{template['title']}（{next_number}）"
    # 写したタスクにセッションとリンクを持たせない（元のセッションが何十ものタスクに結ばれた形にしない）
    task["sessions"] = []
    task["links"] = []
    tasks.append(task)
    next_number += 1

state["boards"] = boards
state["tasks"] = tasks
target.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
print(f"{target.relative_to(root)}: boards {len(boards)}, tasks {len(tasks)}")
