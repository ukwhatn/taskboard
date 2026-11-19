#!/usr/bin/env python3
"""README と紹介用のスクリーンショットを撮るための、架空のデータの fixtures を作る。

- demo.json: Mac Studio。架空の EC サイトの開発（案件「ストアフロント」「社内ツール」）。会話・作業項目・PR・質問・定期起動・利用枠がある
- demo-laptop.json: 2 台目の MacBook Pro（案件「個人開発」）

`--scenario demo+demo-laptop` で起こす。人・リポジトリ・URL・パスはすべて架空で、本番のデータを含めない（最後に検査する）。
作り直すときは `python3 scripts/fixtures/make-demo.py`。
"""
import copy
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[2]
base = json.loads((root / "App/Fixtures/conversations.json").read_text())
columns = json.loads((root / "App/Fixtures/sessions-basic.json").read_text())["boards"][0]["columns"]

MACHINE = "demo-studio"
HOME = "/Users/demo"
DAY = "2026-10-30"


def at(hm, day=DAY):
    return f"{day}T{hm}:00+09:00"


def board(bid, machine, name, position):
    return {"id": bid, "machine": machine, "name": name, "position": position, "createdAt": at("09:00", "2026-09-01"),
            "columns": copy.deepcopy(columns),
            "promptTemplate": "タスク #{{id}} に着手してください。\n題: {{title}}\n列: {{status}}\n関連URL:\n{{links}}\n備考:\n{{note}}"}


def link(i, url, kind):
    return {"id": i, "url": url, "kind": kind, "note": "", "addedAt": at("10:00", "2026-10-20")}


def task(machine, number, board_id, column, title, links=(), note="", due=None, updated="10:00", day=DAY):
    return {"machine": machine, "number": number, "boardID": board_id, "columnID": column, "title": title, "note": note, "due": due,
            "links": [link(i + 1, u, k) for i, (u, k) in enumerate(links)], "sessions": [], "importedID": None,
            "createdAt": at("10:00", "2026-10-20"), "updatedAt": at(updated, day)}


def item(machine, iid, number, position, title, state, blocker=None, text="", deliverable=None, owner="", depends=()):
    return {"machine": machine, "itemID": iid, "taskNumber": number, "title": title, "state": state, "blockerKind": blocker,
            "blockerText": text, "blockerTone": None, "dependsOn": list(depends),
            "deliverableKind": deliverable[0] if deliverable else None, "deliverableRef": deliverable[1] if deliverable else "",
            "owner": owner, "position": position, "source": "session", "createdAt": at("10:00", "2026-10-28"), "updatedAt": at("11:00")}


def pr_state(url, state="OPEN", draft=False, checks="SUCCESS", review="REVIEW_REQUIRED"):
    return {"url": url, "fetchedAt": "2026-10-30T02:58:00Z", "pullRequest": {"state": state, "isDraft": draft, "checks": checks, "reviewDecision": review}}


def pull(url, title, author, category, checks="SUCCESS", draft=False, review=None, add=120, delete=30, files=6, reviewers=()):
    repo, number = re.match(r"https://github.com/(.+)/pull/(\d+)", url).groups()
    category = category or ("myDraft" if draft else "myReady")
    return {"machine": MACHINE, "host": "github.com", "account": "demo-user", "category": category, "url": url, "repository": repo,
            "number": int(number), "title": title, "author": author, "isDraft": draft, "headRef": f"feature/{number}",
            "createdAt": at("10:00", "2026-10-28"), "updatedAt": at("11:30"), "reviewDecision": review, "checks": checks,
            "additions": add, "deletions": delete, "changedFiles": files, "latestReviews": [], "requestedReviewers": list(reviewers)}


def message(mid, role, kind, text, hm, tool=None, tool_id=None):
    m = {"id": mid, "role": role, "kind": kind, "text": text, "isError": False, "at": at(hm)}
    if tool:
        m["toolName"] = tool
    if tool_id:
        m["toolID"] = tool_id
    return m


def conversation(cid, number, title, phase, model="claude-opus-5-5[1m]", effort="high", engine="claude", cwd=f"{HOME}/dev/storefront",
                 pending=(), context=30, diff=None, cost=None, updated="11:40"):
    c = {"id": cid, "machine": MACHINE, "taskNumber": number, "engine": engine, "agentSessionID": f"agent-{cid}", "cwd": cwd,
         "model": model, "effort": effort, "permissionMode": "acceptEdits" if engine == "claude" else "default", "title": title,
         "customTitle": title, "runner": "host", "phase": phase, "pending": list(pending), "backgroundTasks": 0, "backgroundTasksKnown": True,
         "contextPercent": context, "createdAt": at("09:30"), "updatedAt": at(updated)}
    if diff:
        c["diff"] = {"isRepo": True, "branch": diff[0], "files": diff[1], "insertions": diff[2], "deletions": diff[3]}
    if cost is not None:
        c["stats"] = {"agentSessionID": c["agentSessionID"], "model": model, "engineVersion": "2.1.312", "costUSD": cost,
                      "tokens": {"input": 2310, "output": 24120, "cacheRead": 1820400, "cacheWrite": 96210},
                      "contextTokens": context * 6000, "contextWindow": 600000, "at": "2026-10-30T02:40:00Z"}
    return c


STORE, INTERNAL = "demo-store", "demo-internal"
gh = "https://github.com/acme"
tasks = [
    task(MACHINE, 214, STORE, "working", "決済画面を新しい決済 API に移す",
         [(f"{gh}/storefront/pull/412", "github_pr"), ("https://acme.atlassian.net/browse/SHOP-128", "jira")],
         note="旧 API は 12 月末で止まる。カード情報は画面に残さない", due="2026-11-06", updated="11:40"),
    task(MACHINE, 215, STORE, "working", "商品検索の応答を 200 ms 以内にする", [(f"{gh}/storefront/pull/418", "github_pr")], updated="11:35"),
    task(MACHINE, 216, STORE, "planning", "会員ランクの仕組みを設計する", updated="11:20"),
    task(MACHINE, 211, STORE, "review", "カートの数量の上限を直す", [(f"{gh}/storefront/pull/405", "github_pr")], updated="09:50"),
    task(MACHINE, 209, STORE, "review_req", "在庫 API のページングを見直す", [(f"{gh}/inventory/pull/88", "github_pr")], updated="10:10"),
    task(MACHINE, 217, STORE, "todo", "注文履歴を CSV で書き出せるようにする", due="2026-11-13", updated="09:00"),
    task(MACHINE, 218, STORE, "todo", "ヘッダのメニューをキーボードで操作できるようにする", updated="09:00"),
    task(MACHINE, 207, STORE, "deploying", "商品画像を遅延読み込みにする", [(f"{gh}/storefront/pull/398", "github_pr")], updated="08:40"),
    task(MACHINE, 203, STORE, "done", "ログインに二段階認証を足す", [(f"{gh}/storefront/pull/377", "github_pr")], updated="18:00", day="2026-10-27"),
    task(MACHINE, 201, STORE, "done", "送料の計算を地域ごとの表にする", updated="18:00", day="2026-10-24"),
    task(MACHINE, 302, INTERNAL, "working", "依存パッケージを上げて脆弱性の警告を消す", [(f"{gh}/admin/pull/57", "github_pr")], updated="11:10"),
    task(MACHINE, 303, INTERNAL, "todo", "社内 wiki の検索を作り直す", updated="09:00"),
    task(MACHINE, 301, INTERNAL, "done", "管理画面の権限を役割ごとに分ける", updated="18:00", day="2026-10-22"),
]
work = [
    item(MACHINE, 1, 214, 0, "新しい API のクライアントと型", "done", deliverable=("commit", "8c41e2a9d0b7")),
    item(MACHINE, 2, 214, 1, "決済画面のフォームを差し替える", "done", deliverable=("commit", "3fa09b6c1e52")),
    item(MACHINE, 3, 214, 2, "3D セキュアの戻り先の処理", "doing"),
    item(MACHINE, 4, 214, 3, "E2E テストを新しい API に向ける", "todo", depends=(3,)),
    item(MACHINE, 5, 214, 4, "ステージングで決済を通す", "todo", depends=(4,)),
    item(MACHINE, 6, 215, 0, "遅いクエリを洗い出す", "done", deliverable=("file", "docs/perf/search.md")),
    item(MACHINE, 7, 215, 1, "全文検索の index を足す", "wait", blocker="approval", text="ベンチマークの実行の許可を待っている"),
    item(MACHINE, 8, 215, 2, "結果をキャッシュする", "todo"),
    item(MACHINE, 9, 216, 0, "ランクの条件と特典の案をまとめる", "wait", blocker="approval", text="計画書の質問への回答待ち"),
    item(MACHINE, 10, 211, 0, "上限を設定から読む", "done", deliverable=("pr", f"{gh}/storefront/pull/405")),
    item(MACHINE, 11, 211, 1, "レビュー対応", "wait", blocker="review", text="mika さんのレビュー待ち"),
    item(MACHINE, 12, 302, 0, "patch と minor を上げる", "done", deliverable=("commit", "b77d0c3e19aa")),
    item(MACHINE, 13, 302, 1, "major の上げ方を調べる", "doing", owner="codex"),
]
links = [
    pr_state(f"{gh}/storefront/pull/412", draft=True, checks="PENDING", review=None),
    {"url": "https://acme.atlassian.net/browse/SHOP-128", "fetchedAt": "2026-10-30T02:58:00Z",
     "jira": {"key": "SHOP-128", "statusName": "進行中", "category": "indeterminate", "summary": "決済 API の移行"}},
    pr_state(f"{gh}/storefront/pull/418", draft=True, checks="SUCCESS", review=None),
    pr_state(f"{gh}/storefront/pull/405", checks="SUCCESS", review="REVIEW_REQUIRED"),
    pr_state(f"{gh}/inventory/pull/88", checks="FAILURE", review="REVIEW_REQUIRED"),
    pr_state(f"{gh}/storefront/pull/398", state="MERGED", review="APPROVED"),
    pr_state(f"{gh}/storefront/pull/377", state="MERGED", review="APPROVED"),
    pr_state(f"{gh}/admin/pull/57", checks="SUCCESS", review="APPROVED"),
]
pulls = [
    pull(f"{gh}/storefront/pull/412", "決済画面を新しい決済 API に移す", "demo-user", None, checks="PENDING", draft=True, add=640, delete=212, files=18),
    pull(f"{gh}/storefront/pull/418", "商品検索に全文検索の index を足す", "demo-user", None, draft=True, add=88, delete=12, files=4),
    pull(f"{gh}/storefront/pull/405", "カートの数量の上限を設定から読む", "demo-user", None, add=46, delete=9, files=3, reviewers=("mika",)),
    pull(f"{gh}/inventory/pull/88", "在庫 API のページングをカーソル方式にする", "mika", "reviewRequested", checks="FAILURE", add=310, delete=95, files=9, reviewers=("demo-user",)),
    pull(f"{gh}/admin/pull/57", "依存パッケージを上げる", "demo-user", None, review="APPROVED", add=420, delete=388, files=2),
    pull(f"{gh}/storefront/pull/421", "トップページのバナーを差し替える", "ken", "reviewRequested", add=24, delete=18, files=2, reviewers=("demo-user",)),
]

checkout_messages = [
    message("u1", "user", "text", "#214 の続き。3D セキュアから戻ってきたときの処理を作って", "11:30"),
    message("a1#0", "assistant", "text", "戻り先の画面と、決済の結果を確かめる API の呼び出しを作ります。まず今の画面の作りを読みます。", "11:30"),
    message("a1#1", "assistant", "toolUse", "app/checkout/confirm/page.tsx", "11:30", tool="Read", tool_id="t1"),
    message("u2#0", "user", "toolResult", "142 行を読みました", "11:31", tool_id="t1"),
    message("a2#0", "assistant", "toolUse", "app/checkout/return/page.tsx", "11:33", tool="Write", tool_id="t2"),
    message("u3#0", "user", "toolResult", "書き込みました", "11:33", tool_id="t2"),
    message("a3#0", "assistant", "toolUse", "pnpm test checkout", "11:35", tool="Bash", tool_id="t3"),
    message("u4#0", "user", "toolResult", "Tests  24 passed (24)\nDuration  3.81s", "11:36", tool_id="t3"),
    message("a4#0", "assistant", "text",
            "戻り先の画面を足し、テストが 24 件通りました。\n\n"
            "- 決済の結果は戻り先の URL の値を信じず、サーバーから決済 API に問い合わせて決める\n"
            "- 認証に失敗したときは、カートを残したまま決済画面に戻す\n\n"
            "```ts\nconst result = await payments.retrieve(session.paymentId)\nif (result.status !== \"succeeded\") redirect(\"/checkout?error=auth\")\n```",
            "11:37"),
    message("u5", "user", "text", "いいね。E2E も新しい API に向けて", "11:39"),
]
checkout_events = [
    {"blockStart": {"messageID": "msg_9", "index": 0, "block": "thinking", "toolName": None}},
    {"delta": {"messageID": "msg_9", "index": 0, "block": "thinking", "text": "E2E は決済 API のテスト用のカード番号で通す。"}},
    {"blockStop": {"messageID": "msg_9", "index": 0}},
    {"blockStart": {"messageID": "msg_9", "index": 1, "block": "text", "toolName": None}},
    {"delta": {"messageID": "msg_9", "index": 1, "block": "text", "text": "E2E のシナリオを新しい API のテスト用のカードで通るように書き換えます。対象は購入・3D セキュア・失敗の 3 本で、"}},
]

question = {"id": "req-q", "kind": "question", "toolName": "AskUserQuestion", "toolUseID": "toolu_q1",
            "waiting": {"id": "toolu_q1", "since": "2026-10-30T02:20:00Z", "questions": [
                {"id": "q0", "question": "ランクを決める期間はどちらにしますか？", "header": "期間", "multiSelect": False,
                 "options": [{"label": "直近 12 か月", "description": "毎月入れ替わる。下がることもある"},
                             {"label": "年度ごと", "description": "4 月にまとめて決める"}]}]}}
permission = {"id": "req-p", "kind": "permission", "toolName": "Bash", "toolUseID": "toolu_p1",
              "waiting": {"id": "toolu_p1", "since": "2026-10-30T02:35:00Z",
                          "permission": {"tool": "Bash", "summary": "pnpm run bench:search", "detail": "検索のベンチマークを回す"}}}

conversations = [
    conversation("d-checkout", 214, "3D セキュアの戻り先", "running", context=41, diff=("feature/412-payments", 7, 318, 64), cost=3.42),
    conversation("d-search", 215, "全文検索の index を足す", "waiting", pending=[permission], context=27, diff=("feature/418-search", 4, 88, 12), updated="11:35"),
    conversation("d-rank", 216, "会員ランクの計画", "waiting", pending=[question], context=18, updated="11:20"),
    conversation("d-review", 209, "在庫 API の PR をレビュー", "idle", model="claude-sonnet-5-5", effort="medium", cwd=f"{HOME}/dev/inventory", context=22, updated="10:10"),
    conversation("d-deps", 302, "major の上げ方を調べる", "running", engine="codex", model="gpt-5.5-codex", effort="medium", cwd=f"{HOME}/dev/admin", context=35, updated="11:10"),
    conversation("d-orch", None, "オーケストレーター", "idle", effort="medium", cwd=HOME, context=12, updated="09:05"),
]
conversations[-1]["purpose"] = "orchestrator"
# ホームの会話の形の計画の承認待ち（#217）
plan = {"id": "req-plan", "kind": "plan", "toolName": "ExitPlanMode", "toolUseID": "toolu_pl1",
        "waiting": {"id": "toolu_pl1", "since": "2026-10-30T02:45:00Z"},
        "plan": "1. 注文履歴の画面に［CSV を書き出す］を追加する\n2. 期間の指定は今の絞り込みをそのまま使う\n3. 列は注文番号・日付・金額・状態\n"
                "4. 1 万件を超えたら分けて書き出す\n5. 文字コードは UTF-8（BOM 付き）\n6. テストを足す"}
conversations.insert(3, conversation("d-csv", 217, "注文履歴を CSV で書き出せるようにする", "waiting", pending=[plan], context=9, updated="11:45"))
# ホームの会話の形が出す、ターンの始まりと最後の応答の頭
turns = {"d-checkout": "11:39", "d-deps": "11:09"}
replies = {
    "d-checkout": ("戻り先の画面を足し、テストが 24 件通りました。決済の結果は戻り先の URL の値を信じず、サーバーから決済 API に問い合わせて決めます。", "11:37"),
    "d-search": ("遅いのは商品名の部分一致で、全件を読んでいました。全文検索の index を足し、前後でベンチマークを比べます。", "11:34"),
    "d-rank": ("計画書の下書きを #216 に載せました。ランクを決める期間だけは方針が分かれるので、先に決めてください。", "11:20"),
    "d-review": ("レビューを書きました。CI の失敗は、カーソルの値を URL に載せるときに base64 の + が崩れているためです。修正の案をコメントに付けています。", "10:10"),
    "d-orch": ("応答を待っているのは 2 件です。#215 はベンチマークの実行の許可、#216 は計画書の質問への回答です。", "09:05"),
}
for c in conversations:
    if c["id"] in turns:
        c["turnStartedAt"] = at(turns[c["id"]])
    if c["id"] in replies:
        text, hm = replies[c["id"]]
        c["lastReply"] = {"text": text[:200], "at": at(hm)}
chats = {
    "d-checkout": {"messages": checkout_messages, "events": checkout_events},
    "d-search": {"messages": [
        message("u1", "user", "text", "検索が遅い原因を調べて、直せるなら直して", "11:00"),
        message("a1#0", "assistant", "text", "遅いのは商品名の部分一致で、全件を読んでいました。全文検索の index を足し、前後でベンチマークを比べます。", "11:34"),
    ]},
    "d-rank": {"messages": [
        message("u1", "user", "text", "会員ランクの計画書を作って。決めることがあれば聞いて", "11:10"),
        message("a1#0", "assistant", "text", "計画書の下書きを #216 に載せました。ランクを決める期間だけは方針が分かれるので、先に決めてください。", "11:20"),
    ]},
    "d-review": {"messages": [
        message("u1", "user", "text", "inventory#88 をレビューして", "10:00"),
        message("a1#0", "assistant", "text", "レビューを書きました。CI の失敗は、カーソルの値を URL に載せるときに base64 の `+` が崩れているためです。修正の案をコメントに付けています。", "10:10"),
    ]},
    "d-deps": {"messages": [
        message("u1", "user", "text", "major を上げるときに壊れるところを洗い出して", "11:00"),
        message("a1#0", "assistant", "text", "変更履歴を読み、使っている API の変わったところを一覧にしています。", "11:10"),
    ]},
    "d-orch": {"messages": [
        message("u1", "user", "text", "今朝の様子を教えて", "09:00"),
        message("a1#0", "assistant", "text", "応答を待っているのは 2 件です。#215 はベンチマークの実行の許可、#216 は計画書の質問への回答です。inventory#88 は CI が落ちています。", "09:05"),
    ]},
}

demo = copy.deepcopy(base)
demo.update({
    "generatedAt": "2026-10-30T03:00:00Z",
    "machine": {**base["machine"], "id": MACHINE, "name": "Mac Studio"},
    "chatFiles": {},
    "boards": [board(STORE, MACHINE, "ストアフロント", 0), board(INTERNAL, MACHINE, "社内ツール", 1)],
    "tasks": tasks, "workItems": work, "links": links,
    "documents": [{"machine": MACHINE, "docID": 1, "taskNumber": 216, "name": "member-rank-plan.md", "format": "markdown", "title": "会員ランクの計画",
                   "latestRev": 2, "hasSourceFile": True, "openComments": 1, "draftComments": 0, "createdAt": at("11:15"), "updatedAt": at("11:20")}],
    "asks": [{"machine": MACHINE, "askID": 1, "taskNumber": 216, "docID": 1, "status": "open", "questions": [
        {"id": "q1", "question": "ランクの特典に送料無料を入れるか", "header": "特典",
         "options": [{"label": "入れる", "description": "最上位のランクだけ"}, {"label": "入れない", "description": "ポイントの倍率だけにする"}], "multiSelect": False}],
        "answers": None, "createdAt": at("11:20"), "answeredAt": None, "deliveredAt": None}],
    "reviewRequests": [],
    "prs": {"accounts": [{"host": "github.com", "account": "demo-user", "fetchedAt": at("11:58"), "error": None, "rateLimited": False, "nextFetchAt": at("12:03")}],
            "pullRequests": pulls,
            "notices": [{"id": f"{gh}/admin/pull/57#approved#1", "machine": MACHINE, "url": f"{gh}/admin/pull/57", "label": "acme/admin#57",
                         "title": "依存パッケージを上げる", "kind": "approved", "detail": "ken", "at": at("11:00")}]},
    "conversations": conversations, "conversationChats": chats,
    "usage": {"claude": {"fiveHour": {"usedPercent": 38, "resetsAt": "2026-10-30T05:00:00Z", "windowSeconds": 18000},
                         "sevenDay": {"usedPercent": 46, "resetsAt": "2026-11-02T00:00:00Z", "windowSeconds": 604800}, "at": "2026-10-30T02:59:00Z"},
              "codex": {"primary": {"usedPercent": 12, "resetsAt": "2026-10-30T06:10:00Z", "windowSeconds": 18000},
                        "secondary": {"usedPercent": 28, "resetsAt": "2026-11-03T09:00:00Z", "windowSeconds": 604800}, "fetchedAt": "2026-10-30T02:55:00Z"},
              "contexts": []},
    "schedules": [
        {"scheduleID": 1, "machine": MACHINE, "name": "朝の PR 棚卸し", "enabled": True, "rule": {"cron": "0 9 * * 1-5"}, "cwd": HOME, "kind": "claude",
         "agentArgs": ["--model", "sonnet"], "prompt": "自分宛てのレビュー依頼と自分の PR の CI を見て、今日やることを 3 行で残して", "overlap": "skip",
         "nextAt": "2026-10-31T09:00:00+09:00", "lastRun": {"id": 21, "scheduleID": 1, "scheduledAt": at("09:00"), "trigger": "schedule", "requestID": "sched-1-21",
                                                           "stage": "done", "createdAt": at("09:00")},
         "createdAt": at("10:00", "2026-10-01"), "updatedAt": at("10:00", "2026-10-01")},
        {"scheduleID": 2, "machine": MACHINE, "name": "週次の依存更新", "enabled": True, "rule": {"cron": "0 10 * * 1"}, "cwd": f"{HOME}/dev/admin", "kind": "codex",
         "agentArgs": [], "prompt": "依存パッケージの更新を調べ、patch と minor を上げる PR を作って", "taskNumber": 302, "overlap": "skip",
         "nextAt": "2026-11-02T10:00:00+09:00", "createdAt": at("10:00", "2026-10-01"), "updatedAt": at("10:00", "2026-10-01")},
    ],
    "orchestrator": {**base["orchestrator"], "conversationID": "d-orch"},
})

LAPTOP = "demo-laptop"
laptop = {
    "generatedAt": demo["generatedAt"],
    "machine": {"id": LAPTOP, "name": "MacBook Pro", "daemonVersion": "0.1.0"},
    "boards": [board("demo-personal", LAPTOP, "個人開発", 0)],
    "tasks": [task(LAPTOP, 41, "demo-personal", "working", "ブログの記事の OGP 画像を自動で作る", [("https://github.com/demo-user/blog/pull/23", "github_pr")], updated="11:30"),
              task(LAPTOP, 42, "demo-personal", "todo", "家計簿アプリの CSV 取り込み", updated="08:00"),
              task(LAPTOP, 40, "demo-personal", "done", "dotfiles を整理する", updated="21:00", day="2026-10-28")],
    "workItems": [item(LAPTOP, 1, 41, 0, "画像のテンプレート", "done", deliverable=("commit", "51c2d8e0f3a4")),
                  item(LAPTOP, 2, 41, 1, "ビルドで画像を書き出す", "doing")],
    "documents": [], "asks": [], "reviewRequests": [], "schedules": [],
    "links": [pr_state("https://github.com/demo-user/blog/pull/23", draft=True, review=None)],
    "settings": {"orchestrator": {"enabled": False, "agentArgs": []}, "idleStopMinutes": 120},
}

# 雛形から持ち越した値に、本物の人・リポジトリ・パスが残っていないかを確かめる
FORBIDDEN = re.compile(r"ukwhatn|dena|scpwiki|watanabe|/Users/(?!demo\b)|fixture-|taskboard/pull|doorman|console", re.I)
for name, data in [("demo", demo), ("demo-laptop", laptop)]:
    text = json.dumps(data, ensure_ascii=False, indent=1) + "\n"
    leaks = sorted(set(m.group(0) for m in FORBIDDEN.finditer(text)))
    if leaks:
        raise SystemExit(f"{name}: 架空でない値が残っている: {leaks}")
    (root / f"App/Fixtures/{name}.json").write_text(text)
    print(f"App/Fixtures/{name}.json")
