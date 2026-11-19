#!/usr/bin/env python3
"""セッションの切替の速さを、アプリのイベントのログ（JSON Lines）から集計する。

使い方:
  scripts/perf/switch-report.py ~/Library/Application\\ Support/taskboard/logs/app-events*.jsonl
  scripts/perf/switch-report.py --since 2026-10-06T18:00 --slow 20 <ログ>...

`session.switch` の行を切替 1 回（id）ごとに束ね、開き方（terminal / chat）・マシン・持ち越したか（reused）ごとに、
段階ごとの「最初の行からの ms」（total_ms）の件数・p50・p95 を表にする。続けて、終わりの段階（terminal は first_draw、
chat は reloaded。届かなかった回は最後の段階）が組の p95 を超えた回を遅い順に並べる。標準ライブラリだけで書く。
"""

import argparse
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone

STAGES = ["requested", "opened", "shown_cached", "connected", "first_frame", "control_acquired", "first_draw", "reloaded"]
END_STAGE = {"terminal": "first_draw", "chat": "reloaded"}


def percentile(values, p):
    """最も近い順位の値（nearest-rank）。件数が少なくても補間しない"""
    ordered = sorted(values)
    rank = max(1, math.ceil(p / 100 * len(ordered)))
    return ordered[rank - 1]


def parse_time(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def read_switches(paths, since):
    switches = {}
    skipped = 0
    for path in paths:
        with open(path, encoding="utf-8") as file:
            for line in file:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1  # 回した瞬間に途中で切れた行
                    continue
                if event.get("type") != "session.switch":
                    continue
                at = parse_time(event["at"])
                if since and at < since:
                    continue
                entry = switches.setdefault(
                    event["id"],
                    {"id": event["id"], "at": at, "mode": event.get("mode", "?"), "machine": event.get("machine", "?"), "pane": event.get("pane", "?"), "reused": None, "stages": {}},
                )
                entry["at"] = min(entry["at"], at)
                if event.get("reused") is not None:
                    entry["reused"] = event["reused"]
                entry["stages"].setdefault(event.get("stage", "?"), event.get("total_ms", 0))
    return list(switches.values()), skipped


def end_of(switch):
    stage = END_STAGE.get(switch["mode"])
    if stage in switch["stages"]:
        return stage, switch["stages"][stage]
    last = max(switch["stages"].items(), key=lambda item: item[1])
    return last[0] + "（途中）", last[1]


def group_key(switch):
    reused = {True: "持ち越し", False: "新規", None: "?"}[switch["reused"]]
    return (switch["mode"], switch["machine"], reused)


def print_table(rows, headers):
    widths = [max(len(str(row[i])) for row in rows + [headers]) for i in range(len(headers))]
    print("  ".join(str(h).ljust(w) for h, w in zip(headers, widths)))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(str(c).rjust(w) if isinstance(c, (int, float)) else str(c).ljust(w) for c, w in zip(row, widths)))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help="app-events.jsonl（回した app-events.1.jsonl なども並べてよい）")
    parser.add_argument("--since", help="この時刻（ISO8601。タイムゾーンが無ければ UTC）より後の切替だけ")
    parser.add_argument("--slow", type=int, default=30, help="遅かった回の一覧に出す数の上限（既定 30）")
    args = parser.parse_args()

    since = None
    if args.since:
        since = parse_time(args.since)
        if since.tzinfo is None:
            since = since.replace(tzinfo=timezone.utc)

    switches, skipped = read_switches(args.paths, since)
    if not switches:
        print("session.switch の行がありません", file=sys.stderr)
        return 1

    groups = defaultdict(list)
    for switch in switches:
        groups[group_key(switch)].append(switch)

    print(f"切替 {len(switches)} 回（読めなかった行 {skipped}）\n")
    rows = []
    for key in sorted(groups):
        members = groups[key]
        for stage in STAGES:
            values = [m["stages"][stage] for m in members if stage in m["stages"]]
            if values:
                rows.append([*key, stage, len(values), percentile(values, 50), percentile(values, 95), max(values)])
    print("段階ごとの、最初の行からの ms")
    print_table(rows, ["開き方", "マシン", "接続", "段階", "件数", "p50", "p95", "最大"])

    slow = []
    for members in groups.values():
        ends = [(end_of(m), m) for m in members]
        threshold = percentile([total for (_, total), _ in ends], 95)
        over = [(total, m, stage, threshold) for (stage, total), m in ends if total > threshold]
        # 20 回に満たない組は nearest-rank の p95 が最大と同じになり、超える回が出ない。最も遅い回を出す
        if not over and len(members) > 1:
            (stage, total), m = max(ends, key=lambda item: item[0][1])
            over = [(total, m, stage, threshold)]
        slow += over
    slow.sort(key=lambda item: -item[0])
    print("\n遅かった回（組の p95 を超えた回。20 回に満たない組は最も遅い回）")
    if not slow:
        print("（なし）")
        return 0
    rows = []
    for total, member, stage, threshold in slow[: args.slow]:
        steps = " ".join(f"{s}={member['stages'][s]}" for s in STAGES if s in member["stages"])
        rows.append([member["at"].astimezone().strftime("%m-%d %H:%M:%S"), member["id"], *group_key(member), member["pane"], stage, total, threshold, steps])
    print_table(rows, ["時刻", "id", "開き方", "マシン", "接続", "pane", "終わり", "ms", "p95", "段階"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
