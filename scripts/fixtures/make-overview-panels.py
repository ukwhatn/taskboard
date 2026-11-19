#!/usr/bin/env python3
"""会話が登録する概況の部品を、全部の種類で並べた fixtures（overview-panels.json）を作る。

demo.json（架空の EC サイトの開発）を元に、#214「決済画面を新しい決済 API に移す」へ次を加える。
- 概況の部品: 計器（値と基準・紐づけ）、主表、計画（作業項目のまとまり）、図（流れ・時系列・比較・関係）、グラフ（折れ線・棒）、
  送る文面（承認待ち）、自由の HTML、紐づけた表（リンク・子のタスク）
- 作業項目のまとまり（M1〜M3）と番号（M2.3 など）、#215 の会話を #214 の会話の委譲先にする（子のタスク）

#214 の会話は止まった状態にし、開くと概況の面が主になるようにする。`--scenario overview-panels` で起こす。
作り直すときは `python3 scripts/fixtures/make-overview-panels.py`（先に make-demo.py を回した demo.json を読む）。
"""
import copy
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
data = json.loads((root / "App/Fixtures/demo.json").read_text())
MACHINE = data["machine"]["id"]
TASK = 214
DAY = "2026-10-30"


def at(hm, day=DAY):
    return f"{day}T{hm}:00+09:00"


# 作業項目: まとまり M1（済み）・M2（今）・M3（これから）と番号
template = next(w for w in data["workItems"] if w["taskNumber"] == TASK)
data["workItems"] = [w for w in data["workItems"] if w["taskNumber"] != TASK]
plan = [
    ("M1", "M1.1", "新しい API のクライアントと型", "done"),
    ("M1", "M1.2", "決済の結果をサーバーで確認する", "done"),
    ("M2", "M2.1", "カード入力の画面を差し替える", "done"),
    ("M2", "M2.2", "戻り先の画面", "doing"),
    ("M2", "M2.3", "3D セキュアの失敗時の表示", "todo"),
    ("M2", "M2.4", "加盟店の設定値の確認", "wait"),
    ("M3", "M3.1", "旧 API と並行して動かす", "todo"),
    ("M3", "M3.2", "旧 API の呼び出しを外す", "todo"),
]
for index, (group, code, title, state) in enumerate(plan):
    item = copy.deepcopy(template)
    item.update({
        "itemID": 100 + index, "title": title, "state": state, "group": group, "code": code, "position": index,
        "blockerKind": "external" if state == "wait" else None, "blockerText": "決済会社の回答待ち" if state == "wait" else "",
        "blockerTone": "dim" if state == "wait" else None, "deliverableKind": None, "deliverableRef": "",
        "updatedAt": at("11:20") if state != "done" else at("09:40"),
    })
    data["workItems"].append(item)

# #214 の会話は止まった状態（開くと概況が主になる）。#215 の会話は #214 の会話の委譲先（子のタスク）
for conversation in data["conversations"]:
    if conversation["id"] == "d-checkout":
        conversation["phase"] = "idle"
        conversation["pending"] = []
    if conversation["id"] == "d-search":
        conversation["parentConversationID"] = "d-checkout"


def part(spec, hm="11:30", turn=5, answer=None):
    value = {"spec": spec, "updatedAt": at(hm), "updatedTurn": turn}
    if answer:
        value["answer"] = answer
    return value


parts = [
    part({"id": "merchant", "kind": "gauge", "label": "決済会社の回答", "value": "4", "amount": 4,
          "basis": {"kind": "denominator", "value": "6", "amount": 6}, "tone": "attention", "symbol": "mail", "note": "D5・D6 が未回答"}),
    part({"id": "m2", "kind": "gauge", "label": "M2 の進み", "bind": {"source": "work", "group": "M2"}}),
    part({"id": "mismatch", "kind": "gauge", "label": "不一致", "value": "2", "amount": 2,
          "basis": {"kind": "previous", "value": "5", "amount": 5}, "tone": "neutral", "note": "2 重決済の表示名ほか"}, hm="09:10", turn=2),
    part({"id": "launch", "kind": "gauge", "label": "旧 API の停止まで", "value": "62 日", "basis": {"kind": "deadline", "value": "12/31"},
          "symbol": "calendar", "note": "12 月上旬に並行運用"}),
    part({"id": "questions", "kind": "gauge", "label": "未回答の問い", "bind": {"source": "questions"}}),
    part({"id": "decisions", "kind": "table", "title": "判断事項（D）", "primary": True, "columns": ["番号", "状態", "内容", "出所"],
          "rows": [
              {"cells": ["D5", "回答待ち", "同じ注文の明細を合計で判定", "11/18 の定例"], "tone": "attention"},
              {"cells": ["D6", "回答待ち", "返金の締め時刻", "SHOP-128"], "tone": "attention"},
              {"cells": ["D3", "回答済み", "表示名は旧 API に合わせる", "SHOP-128 の回答"], "tone": "done"},
              {"cells": ["D1", "回答済み", "並行運用は 12 月上旬", "11/18 の定例"], "tone": "done"},
          ]}),
    part({"id": "plan", "kind": "plan", "title": "移行の計画"}),
    part({"id": "stages", "kind": "diagram", "style": "flow", "title": "移行の段階", "nodes": [
        {"label": "旧 API の挙動を記録", "tone": "done"},
        {"label": "同じ入力で突き合わせ", "tone": "attention", "note": "20 件中 12 件一致"},
        {"label": "並行運用"},
        {"label": "切り替え", "note": "12 月末まで"},
    ]}),
    part({"id": "schedule", "kind": "diagram", "style": "timeline", "title": "日程", "nodes": [
        {"at": "11/18", "label": "定例で D1 を決定", "tone": "done"},
        {"at": "11/27", "label": "D5・D6 の回答の期限", "tone": "attention"},
        {"at": "12/01", "label": "並行運用を開始"},
        {"at": "12/31", "label": "旧 API が停止"},
    ]}),
    part({"id": "inputs", "kind": "diagram", "style": "compare", "title": "突き合わせの入力", "columns": ["個人情報", "網羅"], "nodes": [
        {"label": "注文の記録", "values": ["含まない", "20 件"], "recommended": True},
        {"label": "本番の CSV", "values": ["含む", "全件"]},
        {"label": "手で作る見本", "values": ["含まない", "8 件"]},
    ]}),
    part({"id": "services", "kind": "diagram", "style": "relation", "title": "呼び出しの関係", "nodes": [
        {"id": "web", "label": "決済画面"}, {"id": "api", "label": "注文 API"}, {"id": "pay", "label": "決済 API", "tone": "waiting"},
        {"id": "old", "label": "旧 API", "tone": "done"},
    ], "edges": [
        {"from": "web", "to": "api", "label": "注文の作成"}, {"from": "api", "to": "pay", "label": "結果の確認"},
        {"from": "api", "to": "old", "label": "並行運用だけ"},
    ]}),
    part({"id": "match", "kind": "chart", "style": "line", "title": "一致したケースの推移", "unit": "件", "target": 20, "target_label": "全 20 件",
          "series": [{"name": "一致", "points": [{"x": "10/24", "y": 3}, {"x": "10/25", "y": 6}, {"x": "10/27", "y": 8}, {"x": "10/28", "y": 10},
                                                  {"x": "10/29", "y": 11}, {"x": "10/30", "y": 12}]}]}),
    part({"id": "latency", "kind": "chart", "style": "bar", "title": "決済の応答時間（中央値）", "unit": "ms",
          "series": [{"name": "旧 API", "points": [{"x": "カード", "y": 420}, {"x": "3D セキュア", "y": 1310}, {"x": "返金", "y": 380}]},
                     {"name": "新 API", "points": [{"x": "カード", "y": 260}, {"x": "3D セキュア", "y": 940}, {"x": "返金", "y": 300}]}]}),
    part({"id": "notice", "kind": "draft", "title": "決済会社への確認", "to": "決済会社のサポート窓口（メール、ストアフロントの開発チーム名義）",
          "body": "お世話になっております。ストアフロントの開発チームです。\n新しい決済 API への移行で、次の 2 点を確認させてください。\n1. 同じ注文の明細を合計で判定する場合の上限\n2. 返金の締め時刻\n11 月 27 日までにご回答いただけますと幸いです。",
          "checks": [{"label": "敬体", "ok": True}, {"label": "期限", "ok": True}, {"label": "社外秘", "ok": False, "note": "注文番号を含めない"}]}),
    part({"id": "risk", "kind": "html", "title": "切り替えの判定",
          "html": "<div class=\"tb-row\"><span class=\"tb-badge tb-attention\">要判断</span><span class=\"tb-muted\">不一致が 3 件を超えたら並行運用を 1 週延ばす</span></div>"
                  "<table class=\"tb-table\"><tr><th>不一致</th><th>並行運用</th><th>切り替え</th></tr>"
                  "<tr><td>3 件以下</td><td>12/1</td><td>12/15</td></tr><tr><td>4〜6 件</td><td>12/8</td><td>12/22</td></tr>"
                  "<tr><td>7 件以上</td><td colspan=\"2\">計画を見直す</td></tr></table>"}),
    part({"id": "links", "kind": "table", "title": "PR と課題", "bind": {"source": "links"}}),
    part({"id": "children", "kind": "table", "title": "子のタスク", "bind": {"source": "children"}}),
]
data["panels"] = [{"machine": MACHINE, "taskNumber": TASK, "parts": parts, "turn": 5, "updatedAt": at("11:30")}]

text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
FORBIDDEN = re.compile(r"ukwhatn|dena|scpwiki|watanabe|/Users/(?!demo\b)|fixture-|taskboard/pull|doorman|console", re.I)
leaks = sorted(set(m.group(0) for m in FORBIDDEN.finditer(text)))
if leaks:
    raise SystemExit(f"架空でない値が残っている: {leaks}")
(root / "App/Fixtures/overview-panels.json").write_text(text)
print("App/Fixtures/overview-panels.json")
