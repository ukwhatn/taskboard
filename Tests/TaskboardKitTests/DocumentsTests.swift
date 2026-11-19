import Foundation
import Testing

@testable import TaskboardKit

@Suite("文書・質問・フィードバックの整形と受信箱")
struct DocumentsTests {
    private let machine = MachineID(rawValue: "m1")
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)

    private func ask(_ id: Int64, questions: Int = 1, status: Ask.Status = .open, docID: Int64 = 7) -> Ask {
        Ask(
            machine: machine, askID: id, taskNumber: 1, docID: docID, status: status,
            questions: (1...questions).map { AskQuestion(id: "q\($0)", question: "質問 \($0)", options: [AskOption(label: "A"), AskOption(label: "B")]) },
            answers: status == .answered ? [AskAnswer(questionID: "q1", selected: ["A"], freeText: nil)] : nil, createdAt: t0,
            answeredAt: status == .answered ? t0 : nil)
    }

    @Test("質問の制約: 8 問まで・id 一意・文字数上限・選択肢 1〜8")
    func questionValidation() {
        let ok = AskQuestion(id: "q1", question: "どっち", header: "方式", options: [AskOption(label: "A", description: "説明")])
        #expect(AskQuestion.validate([ok]) == nil)
        #expect(AskQuestion.validate([ok, ok]) == "質問 id が重複している: q1")
        #expect(AskQuestion.validate(Array(repeating: ok, count: 9)) == "質問は 8 問まで")
        #expect(AskQuestion.validate([AskQuestion(id: "", question: "x", options: [AskOption(label: "A")])]) == "質問 id は 1〜64 文字")
        #expect(AskQuestion.validate([AskQuestion(id: "q", question: String(repeating: "あ", count: 4001), options: [AskOption(label: "A")])]) == "質問文は 1〜4000 文字")
        #expect(AskQuestion.validate([AskQuestion(id: "q", question: "x", header: String(repeating: "h", count: 33), options: [AskOption(label: "A")])]) == "header は 32 文字まで")
        #expect(AskQuestion.validate([AskQuestion(id: "q", question: "x", options: [])]) == "選択肢は 1〜8 個")
        #expect(AskQuestion.validate([AskQuestion(id: "q", question: "x", options: [AskOption(label: "")])]) == "選択肢の label は 1〜300 文字")
        #expect(DocPublishRequest.validateName("report.md") == nil)
        #expect(DocPublishRequest.validateName("..") != nil && DocPublishRequest.validateName("a/b") != nil && DocPublishRequest.validateName("") != nil)
        #expect(DocFormat.infer(fromName: "x.HTML") == .html && DocFormat.infer(fromName: "x.markdown") == .markdown && DocFormat.infer(fromName: "x.txt") == nil)
    }

    @Test("秘密の旗: true のときだけ書き、無い JSON は false で読む（前の版と同じ形）")
    func secretFlag() throws {
        let plain = AskQuestion(id: "q", question: "x", options: [AskOption(label: "A")])
        let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        #expect(plainJSON?.keys.sorted() == ["id", "multiSelect", "options", "question"])
        let secret = AskQuestion(id: "q", question: "x", options: [], isSecret: true)
        let secretJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(secret)) as? [String: Any]
        #expect(secretJSON?["isSecret"] as? Bool == true)
        #expect(try JSONDecoder().decode(AskQuestion.self, from: JSONEncoder().encode(secret)) == secret)
        #expect(try !JSONDecoder().decode(AskQuestion.self, from: Data(#"{"id":"q","question":"x","options":[]}"#.utf8)).isSecret)
    }

    @Test("選択肢の見本と推奨: 値があるときだけ書き、無い JSON は見本なし・推奨なしで読む。見本の長さは 20,000 字まで")
    func optionPreviewWire() throws {
        let plain = try JSONEncoder().encode(AskOption(label: "A", description: "説明"))
        #expect(String(decoding: plain, as: UTF8.self).contains("preview") == false)
        #expect(String(decoding: plain, as: UTF8.self).contains("recommended") == false)
        let old = try JSONDecoder().decode(AskOption.self, from: Data(#"{"label":"A"}"#.utf8))
        #expect(old.preview == nil && old.recommended == false)
        let rich = AskOption(label: "3 列", preview: "<div>見本</div>", recommended: true)
        #expect(try JSONDecoder().decode(AskOption.self, from: JSONEncoder().encode(rich)) == rich)
        #expect(AskOption(label: "A", preview: "  \n").preview == nil, "空白だけの見本は持たない")
        let long = AskQuestion(id: "q", question: "x", options: [AskOption(label: "A", preview: String(repeating: "あ", count: 20_001))])
        #expect(AskQuestion.validate([long]) == "選択肢の preview は 20000 文字まで")
        #expect(AskQuestion.validate([AskQuestion(id: "q", question: "x", options: [AskOption(label: "A", preview: String(repeating: "あ", count: 20_000))])]) == nil)
    }

    @Test("推奨の印: recommended か、label の末尾の (Recommended)・（推奨）。画面の名前からは印を外し、送る label は変えない")
    func recommendedMark() {
        let claude = AskOption(label: "3 列にする (Recommended)")
        #expect(claude.isRecommended && claude.displayLabel == "3 列にする" && claude.label == "3 列にする (Recommended)")
        #expect(AskOption(label: "残す（推奨）").displayLabel == "残す")
        #expect(AskOption(label: "keep (recommended) ").isRecommended)
        #expect(AskOption(label: "(Recommended)").displayLabel == "(Recommended)", "印だけの label はそのまま出す")
        #expect(!AskOption(label: "推奨しない").isRecommended)
        #expect(!AskOption(label: "(推奨) を外す").isRecommended, "末尾でない印は推奨にしない")
        #expect(AskOption(label: "A", recommended: true).isRecommended && AskOption(label: "A", recommended: true).displayLabel == "A")
        #expect(AskOption(label: "A", preview: "<!doctype html><p>x</p>").previewIsHTML)
        #expect(!AskOption(label: "A", preview: "| a | b |").previewIsHTML)
    }

    @Test("回答判定: 選択か自由記述のどちらかがあれば回答済み")
    func answered() {
        let a = ask(1, questions: 2)
        #expect(a.unanswered(in: []) == ["q1", "q2"])
        #expect(a.unanswered(in: [AskAnswer(questionID: "q1", selected: ["A"]), AskAnswer(questionID: "q2", selected: [], freeText: "別案")]).isEmpty)
        #expect(a.unanswered(in: [AskAnswer(questionID: "q1", selected: [], freeText: ""), AskAnswer(questionID: "q2", selected: ["B"])]) == ["q1"])
    }

    @Test("hook 本文は guidance + JSON。上限を超えたらレビューから落とし、質問の回答は最後まで残す")
    func hookText() {
        let review = Review(id: 3, taskNumber: 1, summary: "方向はよい", state: .submitted, createdAt: t0, submittedAt: t0)
        let comment = DocComment(id: 11, docID: 7, docName: "plan.md", rev: 2, anchor: CommentAnchor(exact: "ここ"), body: "曖昧", state: .open, reviewID: 3, createdAt: t0)
        let bundle = FeedbackBundle(reviews: [FeedbackBundle.ReviewEntry(review: review, comments: [comment], replies: [])], answeredAsks: [ask(5, status: .answered)])
        let full = FeedbackText.render(bundle)
        #expect(full.hasPrefix(FeedbackText.guidance))
        #expect(full.contains("\"commentId\" : 11") || full.contains("\"commentId\": 11"))
        #expect(full.contains("\"quote\" : \"ここ\"") || full.contains("\"quote\": \"ここ\""))
        #expect(full.contains("\"question\" : \"質問 1\"") || full.contains("\"question\": \"質問 1\""))
        #expect(!full.contains("deliveredAt") && !full.contains("askID"), "配信管理の欄は出さない")

        let whole = FeedbackText.forHook(bundle, limitChars: 10_000)
        #expect(!whole.clipped && whole.text == full)

        let clipped = FeedbackText.forHook(bundle, limitChars: full.count - 1)
        #expect(clipped.clipped)
        #expect(!clipped.text.contains("曖昧") && clipped.text.contains("質問 1"), "落とすのはレビューから")
        #expect(clipped.text.contains("feedback_list"))

        let tiny = FeedbackText.forHook(bundle, limitChars: 10)
        #expect(tiny.clipped && tiny.text == FeedbackText.guidance + FeedbackText.clipNotice)
    }

    @Test("hook の案内と省略の注記は日本語で、comment_reply・resolve・doc_publish・feedback_list の使い方を残す")
    func hookGuidanceText() {
        #expect(FeedbackText.guidance.hasPrefix("人のフィードバックが届いた。"))
        #expect(FeedbackText.guidance.contains("comment_reply") && FeedbackText.guidance.contains("commentId") && FeedbackText.guidance.contains("resolve=true") && FeedbackText.guidance.contains("doc_publish"))
        #expect(FeedbackText.clipNotice == "\n[taskboard] 抜粋のみ。長さの上限で残りを省いた。全文は feedback_list で取る\n")
    }

    @Test("pane に入れる文は人の答えの形（通知の頭の文と送り主は付けず、1 行目は見分ける印）。質問ごとの選択と補足、レビューの総括・コメント（commentId 付き）・返信")
    func promptText() {
        let review = Review(id: 3, taskNumber: 1, summary: "方向はよい", state: .submitted, createdAt: t0, submittedAt: t0)
        let comment = DocComment(id: 11, docID: 7, docName: "plan.md", rev: 2, anchor: CommentAnchor(exact: "ここ"), body: "曖昧", state: .open, reviewID: 3, createdAt: t0)
        let plain = DocComment(id: 12, docID: 7, docName: "plan.md", rev: 2, body: "全体に短く", state: .open, reviewID: 3, createdAt: t0)
        let reply = FeedbackBundle.ReplyEntry(
            reply: CommentReply(id: 1, commentID: 9, author: .human, body: "それでよい", state: .submitted, createdAt: t0), docName: "plan.md", commentBody: "案 B にした")
        var answered = ask(5, questions: 2, status: .answered)
        answered.answers = [AskAnswer(questionID: "q1", selected: ["A", "B"]), AskAnswer(questionID: "q2", selected: [], freeText: "別案")]
        let bundle = FeedbackBundle(reviews: [FeedbackBundle.ReviewEntry(review: review, comments: [comment, plain], replies: [reply])], answeredAsks: [answered])

        let prompt = FeedbackText.forPrompt(bundle)
        #expect(!prompt.clipped && prompt.included == bundle)
        #expect(
            prompt.text == """
                <!-- taskboard: answer task=1 ask=5 doc=7 -->
                taskboard で質問に答えました（#1）。
                - 「質問 1」→ A、B
                - 「質問 2」→ （選択なし）
                  - 補足: 別案

                taskboard でレビューしました（#1）。
                - 総括: 方向はよい
                - plan.md 第2版「ここ」（commentId 11）: 曖昧
                - plan.md 第2版（commentId 12）: 全体に短く
                - 返信（commentId 9、元のコメント「案 B にした」）: それでよい
                - 次の操作: コメントへの返信は comment_reply（commentId を渡す）、修正した版は doc_publish
                """)
        #expect(!prompt.text.contains("[taskboard]") && !prompt.text.contains("{"), "hook の形（JSON）ではない")
        #expect(!prompt.text.contains(TaskboardNotice.mark) && !prompt.text.contains("送り主"), "人の答えとして運ぶので、通知の印を付けない")

        let summaryOnly = FeedbackBundle(reviews: [FeedbackBundle.ReviewEntry(review: review, comments: [], replies: [])])
        let reviewOnly = FeedbackText.forPrompt(summaryOnly).text
        #expect(reviewOnly == "<!-- taskboard: review task=1 -->\ntaskboard でレビューしました（#1）。\n- 総括: 方向はよい", "コメントが無ければ comment_reply の案内は付けない")
        #expect(TaskboardNotice(text: prompt.text) == .answer && TaskboardNotice(text: reviewOnly) == .review)
        #expect(TaskboardNotice.answer.summary(of: prompt.text) == "タスク#1", "見出しは印を外した頭の文から読む")
    }

    @Test("済ませた手作業の知らせ: タスクごとに 1 段落、済ませた順に作業項目の題と頼んだ文。印は finished で、人の答えとして折りたたむ")
    func promptFinishedWork() {
        let bundle = FeedbackBundle(finishedWork: [
            FeedbackBundle.FinishedWork(itemID: 9, taskNumber: 172, title: "実機の確認", request: "iPhone をつなぐ", finishedAt: t0.addingTimeInterval(10)),
            FeedbackBundle.FinishedWork(itemID: 4, taskNumber: 172, title: "鍵の登録", request: "APNs の鍵を入れる", finishedAt: t0),
        ])
        let prompt = FeedbackText.forPrompt(bundle)
        #expect(
            prompt.text == """
                <!-- taskboard: finished task=172 work=9 -->
                taskboard で手作業を済ませました（#172）。
                - 作業項目 4「鍵の登録」: APNs の鍵を入れる
                - 作業項目 9「実機の確認」: iPhone をつなぐ
                - 次の操作: 作業項目は作業中に戻してある。結果を確認して続ける
                """)
        #expect(TaskboardNotice(text: prompt.text) == .finished)
        #expect(TaskboardNotice.finished.summary(of: prompt.text) == "タスク#172")
    }

    @Test("pane に入れる文の上限: レビューから項目ごとに落とし、載せた分だけを included に返す。1 件も入らなければ案内だけ")
    func promptClip() {
        let review = Review(id: 3, taskNumber: 1, summary: String(repeating: "長", count: 300), state: .submitted, createdAt: t0, submittedAt: t0)
        let bundle = FeedbackBundle(reviews: [FeedbackBundle.ReviewEntry(review: review, comments: [], replies: [])], answeredAsks: [ask(5, status: .answered)])
        let full = FeedbackText.forPrompt(bundle)
        #expect(!full.clipped)

        let clipped = FeedbackText.forPrompt(bundle, limitChars: full.text.count - 1)
        #expect(clipped.clipped && clipped.included.reviews.isEmpty && clipped.included.answeredAsks.count == 1)
        #expect(clipped.text.hasSuffix(FeedbackText.promptClipNotice) && clipped.text.contains("「質問 1」→ A") && !clipped.text.contains("長長"))
        #expect(clipped.text.count <= full.text.count - 1)

        let tiny = FeedbackText.forPrompt(bundle, limitChars: 10)
        #expect(tiny.clipped && tiny.included.isEmpty && tiny.text == FeedbackText.promptTooLong)
        #expect(FeedbackText.forPrompt(FeedbackBundle()).text.isEmpty)
    }

    @Test("受信箱: 対応待ち（質問・レビュー依頼・blocked）が先、お知らせ（新しい文書）は後。質問付きの文書はお知らせに重ねない")
    func inbox() {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let task = BoardTask(
            machine: machine, number: 1, boardID: "b", columnID: "planning", title: "設計",
            sessions: [TaskSessionRef(id: 1, agent: "claude", sessionID: "sess-1", cwd: "/repo", linkedAt: t0)], createdAt: t0, updatedAt: t0)
        state.tasks[task.id] = task
        let now = t0.addingTimeInterval(3600)
        let plan = Document(machine: machine, docID: 7, taskNumber: 1, name: "plan.md", format: .markdown, title: "計画", latestRev: 2, createdAt: t0, updatedAt: t0.addingTimeInterval(1800))
        let old = Document(machine: machine, docID: 8, taskNumber: 1, name: "old.md", format: .markdown, latestRev: 1, createdAt: t0, updatedAt: t0.addingTimeInterval(-2 * 86400))
        let withAsk = Document(machine: machine, docID: 9, taskNumber: 1, name: "q.md", format: .markdown, latestRev: 1, createdAt: t0, updatedAt: t0.addingTimeInterval(3000))
        for doc in [plan, old, withAsk] { state.documents[doc.id] = doc }
        state.asks[AskKey(machine: machine, id: 5)] = ask(5, questions: 2, docID: 9)
        state.asks[AskKey(machine: machine, id: 6)] = ask(6, status: .answered, docID: 7)
        state.reviewRequests[task.id] = ReviewRequest(machine: machine, taskNumber: 1, note: "2 章", requestedAt: t0.addingTimeInterval(100))
        state.workItems[WorkItemKey(machine: machine, id: 3)] = WorkItem(
            machine: machine, itemID: 3, taskNumber: 1, title: "移行", state: .wait, blockerKind: .approval, blockerText: "移行の承認", position: 0, source: "session",
            createdAt: t0, updatedAt: t0.addingTimeInterval(200))

        let items = state.inboxItems(now: now)
        #expect(items.map(\.localID) == ["review/1", "ask/5", "doc/7/2"], "作業項目の承認待ちは出さない: \(items.map(\.localID))")
        #expect(items.prefix(2).allSatisfy { $0.group == .waiting } && items.last?.group == .notice)
        #expect(items[1].title == "質問 1（2問）" && items[1].details == ["#1 設計", "q.md"])
        #expect(items[0].title == "2 章" && items[0].details == ["#1 設計", "文書3件"] && items[0].detail == "#1 設計・文書3件")
        #expect(items[2].title == "計画（第2版）")
        #expect(!items.contains { $0.localID.hasPrefix("doc/8") }, "24 時間より古い文書は出さない")
        #expect(!items.contains { $0.localID.hasPrefix("doc/9") }, "質問付きの文書は質問の行だけ")
    }

    @Test("受信箱: 手作業待ちの作業項目は手作業の依頼として対応待ちに出し、終わったタスクの分は出さない。頼む文が変われば別の依頼になる")
    func inboxManualWork() {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let open = BoardTask(machine: machine, number: 1, boardID: "b", columnID: "working", title: "設計", createdAt: t0, updatedAt: t0)
        let done = BoardTask(machine: machine, number: 2, boardID: "b", columnID: "done", title: "済み", createdAt: t0, updatedAt: t0)
        for task in [open, done] { state.tasks[task.id] = task }
        func manual(_ id: Int64, task: Int, text: String) -> WorkItem {
            WorkItem(
                machine: machine, itemID: id, taskNumber: task, title: "実機の確認", state: .wait, blockerKind: .manual, blockerText: text, position: 0,
                source: "session", createdAt: t0, updatedAt: t0)
        }
        state.workItems[WorkItemKey(machine: machine, id: 3)] = manual(3, task: 1, text: "iPhone をケーブルでつなぐ")
        state.workItems[WorkItemKey(machine: machine, id: 4)] = manual(4, task: 2, text: "古い依頼")
        state.workItems[WorkItemKey(machine: machine, id: 5)] = manual(5, task: 1, text: "")

        let items = state.inboxItems(now: t0.addingTimeInterval(60)).filter { $0.localID.hasPrefix("manual/") }.sorted { $0.localID < $1.localID }
        #expect(items.map(\.localID) == ["manual/3", "manual/5"], "終わったタスク #2 の待ちは出さない")
        #expect(items.allSatisfy { $0.group == .waiting && NotifyKind.of($0) == .question })
        #expect(items[0].title == "iPhone をケーブルでつなぐ" && items[0].details == ["#1 設計", "実機の確認"])
        #expect(items[1].title == "実機の確認" && items[1].details == ["#1 設計"], "頼む文が空なら作業項目の題")
        #expect(items[0].kind.label == "手作業の依頼")
        #expect(InboxNotification.url(for: items[0]) == TaskboardLink.task(TaskKey(machine: machine, number: 1)).url)

        var changed = state
        changed.workItems[WorkItemKey(machine: machine, id: 3)]?.blockerText = "iPad をつなぐ"
        let after = changed.inboxItems(now: t0.addingTimeInterval(60)).first { $0.localID == "manual/3" }
        #expect(after.map(\.revision) != items[0].revision, "無視した後に頼む文が変われば、また出る")
    }

    @Test("受信箱: PR の取得の失敗は gh の文を出さない")
    func inboxFallbacks() {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let now = t0.addingTimeInterval(3600)
        state.prs = PRSnapshot(
            accounts: [
                PRAccountStatus(host: "github.com", account: "a", fetchedAt: t0, error: "exit 1: HTTP 401: Bad credentials"),
                PRAccountStatus(host: "github.com", account: "b", fetchedAt: t0, error: "API rate limit exceeded", rateLimited: true),
            ], pullRequests: [], notices: [])
        let items = state.inboxItems(now: now)
        let failures = items.filter { $0.localID.hasPrefix("prsync/") }.sorted { $0.localID < $1.localID }
        #expect(failures.map(\.title) == [
            "PRを取得できませんでした。接続先のMacのghのログインと、ネットワークを確認してください。",
            "PRを取得できませんでした。GitHubの利用の上限に達しています。時間をおいて、再読み込みしてください。",
        ])
        #expect(failures.map(\.details) == [["a@github.com"], ["b@github.com"]])
        #expect(!items.contains { $0.detail.contains("Bad credentials") || $0.title.contains("rate limit") })
    }

    @Test("MachineState への適用: 受領済み・取り下げの質問は落ち、文書の削除で質問も消え、タスク削除で全部削除される")
    func applyEvents() {
        var state = MachineState(machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"))
        let doc = Document(machine: machine, docID: 7, taskNumber: 1, name: "a.md", format: .markdown, latestRev: 1, createdAt: t0, updatedAt: t0)
        state.apply(.docUpdated(doc))
        state.apply(.askUpdated(ask(1)))
        state.apply(.reviewRequestUpdated(ReviewRequest(machine: machine, taskNumber: 1, requestedAt: t0)))
        #expect(state.documents(forTask: 1).count == 1 && state.openAsk(forDoc: 7)?.askID == 1 && state.reviewRequests.count == 1)

        var delivered = ask(1, status: .answered)
        delivered.deliveredAt = t0
        state.apply(.askUpdated(delivered))
        #expect(state.asks.isEmpty, "受領済みは落ちる")
        state.apply(.askUpdated(ask(2, status: .cancelled)))
        #expect(state.asks.isEmpty)
        state.apply(.askUpdated(ask(3)))
        state.apply(.docRemoved(doc.id))
        #expect(state.documents.isEmpty && state.asks.isEmpty, "文書が消えれば質問も削除される")

        state.apply(.docUpdated(doc))
        state.apply(.askUpdated(ask(4)))
        state.apply(.taskRemoved(TaskKey(machine: machine, number: 1)))
        #expect(state.documents.isEmpty && state.asks.isEmpty && state.reviewRequests.isEmpty)
        state.apply(.reviewRequestRemoved(TaskKey(machine: machine, number: 1)))
    }

    @Test("snapshot と event の JSON は往復する")
    func wire() throws {
        let doc = Document(machine: machine, docID: 7, taskNumber: 1, name: "a.md", format: .html, title: "t", latestRev: 3, hasSourceFile: true, openComments: 1, createdAt: t0, updatedAt: t0)
        let snapshot = StateSnapshot(
            machine: MachineInfo(id: machine, name: "m", daemonVersion: "t"), documents: [doc], asks: [ask(1)],
            reviewRequests: [ReviewRequest(machine: machine, taskNumber: 1, note: "n", requestedAt: t0)], generatedAt: t0)
        let data = try WireJSON.encoder().encode(snapshot)
        let decoded = try WireJSON.decoder().decode(StateSnapshot.self, from: data)
        #expect(decoded.documents == [doc] && decoded.asks.count == 1 && decoded.reviewRequests.first?.note == "n")
        for event in [DaemonEvent.docUpdated(doc), .docRemoved(doc.id), .askUpdated(ask(1)), .reviewRequestUpdated(snapshot.reviewRequests[0]), .reviewRequestRemoved(TaskKey(machine: machine, number: 1))] {
            let round = try WireJSON.decoder().decode(DaemonEvent.self, from: try WireJSON.encoder().encode(event))
            #expect(round == event)
        }
        #expect(try WireJSON.decoder().decode(DaemonEvent.self, from: Data(#"{"event":"doc.removed","data":{"machine":"m1","id":7}}"#.utf8)) == .docRemoved(doc.id))
    }
}

@Suite struct InboxItemIDTests {
    @Test func idIncludesMachineSoTwoMachinesDoNotCollide() {
        let a = InboxItem(id: "ask/7", kind: .prSync(PRAccountStatus(host: "github.com", account: "a")), group: .waiting, machine: MachineID(rawValue: "m1"), taskNumber: nil, title: "", details: [], at: Date())
        var b = a
        b.machine = MachineID(rawValue: "m2")
        #expect(a.localID == b.localID)
        #expect(a.id != b.id)
        #expect(a.id == "m1/ask/7")
    }

    @Test("受信箱の並び: 同じ時刻の項目は、渡した順によらず id の順")
    func sameTimeIsOrderedByID() {
        let at = Date(timeIntervalSince1970: 1_000)
        func item(_ id: String, _ machine: String) -> InboxItem {
            InboxItem(id: id, kind: .prSync(PRAccountStatus(host: "github.com", account: id)), group: .notice, machine: MachineID(rawValue: machine), taskNumber: nil, title: "", details: [], at: at)
        }
        let items = [item("pr/b", "m2"), item("pr/a", "m2"), item("pr/c", "m1")]
        let ids = ["m1/pr/c", "m2/pr/a", "m2/pr/b"]
        #expect(items.sorted(by: InboxItem.inboxOrder).map(\.id) == ids)
        #expect(items.reversed().sorted(by: InboxItem.inboxOrder).map(\.id) == ids)
    }
}
