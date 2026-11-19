#!/usr/bin/env python3
"""App/Fixtures/perf-work.json を作る。work-graph.json の #301 を、依存のある 300 件（2 割が完了）にする（作業項目の欄の重さを測るため。scripts/ui/work-perf.py）。

作り直すときは `python3 scripts/fixtures/make-perf-work.py`。
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[2]
d = json.loads((root / "App/Fixtures/work-graph.json").read_text())
base = d["workItems"][0]
items = []
for i in range(300):
    deps = [x for x in ([i - 4 - (i % 3), i - 1 - (i % 4)] if i >= 4 else []) if x >= 0]
    item = dict(base)
    item.update({
        "itemID": 1000 + i, "taskNumber": 301, "title": f"項目 {i} の題をここに書く", "state": "done" if i % 5 == 0 else "todo",
        "dependsOn": [1000 + x for x in sorted(set(deps))], "position": i, "deliverableKind": None, "deliverableRef": "", "owner": "",
    })
    items.append(item)
d["workItems"] = items
d["tasks"] = [t for t in d["tasks"] if t["number"] == 301]
(root / "App/Fixtures/perf-work.json").write_text(json.dumps(d, ensure_ascii=False, indent=2))
