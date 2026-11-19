import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話の / の候補")
struct ConversationSlashTests {
    private let commands = [
        ConversationCommand(name: "clear", description: "会話を消す", builtin: true, aliases: ["reset", "new"]),
        ConversationCommand(name: "model", description: "モデル", builtin: true),
        ConversationCommand(name: "effort", description: "effort", builtin: true),
        ConversationCommand(name: "mcp", description: "MCP", builtin: true),
        ConversationCommand(name: "context", description: "コンテキスト", builtin: true),
        ConversationCommand(name: "rewind", description: "巻き戻す", builtin: true, aliases: ["checkpoint"]),
        ConversationCommand(name: "yomiyasu", description: "推敲"),
        ConversationCommand(name: "日本語の手順", description: "CJK の名前"),
    ]

    @Test("名前の頭で引き、taskboard の操作を同じ並びに出す")
    func prefix() {
        let items = ConversationSlashItem.matching("sh", commands: commands)
        #expect(items.map(\.name) == ["shell"])
        #expect(items.first?.action == .taskboard(.shell))
        #expect(ConversationSlashItem.matching("yo", commands: commands).map(\.action) == [.send("yomiyasu")])
    }

    @Test("文の途中の / には、CLI に送る skill と command だけを出す（組み込み・欄・taskboard の操作は文の頭でしか効かない）")
    func midText() {
        #expect(ConversationSlashItem.matching("", commands: commands, leading: false).map(\.name) == ["yomiyasu", "日本語の手順"])
        #expect(ConversationSlashItem.matching("yo", commands: commands, leading: false).map(\.action) == [.send("yomiyasu")])
        #expect(ConversationSlashItem.matching("res", commands: commands, leading: false).isEmpty, "組み込みの alias も引かない")
        #expect(ConversationSlashItem.matching("sh", commands: commands, leading: false).isEmpty)
    }

    @Test("Codex の会話は、使えない操作（巻き戻し）と、使えない欄（モデルの一覧が無いマシンのモデル）を候補に出さない。Claude Code は今のまま")
    func codex() {
        let codex = ConversationSlashItem.matching("", commands: [], engine: .codex, limit: 99)
        #expect(!codex.contains { $0.name == "rewind" })
        #expect(codex.first { $0.name == "mcp" }?.action == .control(.mcp))
        #expect(codex.first { $0.name == "model" }?.action == .control(.model))
        #expect(codex.first { $0.name == "context" }?.action == .control(.context))
        #expect(codex.first { $0.name == "fork" }?.action == .taskboard(.fork))
        #expect(codex.first { $0.name == "usage" }?.action == .taskboard(.usage))
        let noModels = ConversationSlashItem.matching("", commands: [], engine: .codex, unavailableFields: [.model, .effort], limit: 99)
        #expect(!noModels.contains { $0.name == "model" || $0.name == "effort" })
        let claude = ConversationSlashItem.matching("", commands: commands, limit: 99)
        #expect(claude.first { $0.name == "rewind" }?.action == .taskboard(.rewind))
        #expect(claude.first { $0.name == "mcp" }?.action == .control(.mcp))
        #expect(ConversationSlashItem.matching("", commands: [], engine: .unknown, limit: 99).isEmpty)
    }

    @Test("/ の候補に会話を止める操作は無い（止めたいのは生成で、用済みは［終了］）")
    func hasNoStop() {
        #expect(ConversationTaskboardAction(rawValue: "stop") == nil)
        #expect(ConversationSlashItem.matching("sto", commands: commands).isEmpty)
        #expect(ConversationSlashItem.intercepted("/stop", engine: .claude) == nil)
    }

    @Test("alias でも引ける。引いた alias を添え、送るのは本当の名前")
    func alias() {
        let items = ConversationSlashItem.matching("RES", commands: commands)
        #expect(items.map(\.name) == ["clear"])
        #expect(items.first?.matchedAlias == "reset")
        #expect(items.first?.action == .send("clear"))
        // 名前と alias の両方に合っても 1 回だけ
        #expect(ConversationSlashItem.matching("c", commands: commands).filter { $0.name == "clear" }.count == 1)
    }

    @Test("model・effort・mcp・context は送らずに入力欄の下の欄を開く")
    func controls() {
        #expect(ConversationSlashItem.matching("model", commands: commands).first?.action == .control(.model))
        #expect(ConversationSlashItem.matching("eff", commands: commands).first?.action == .control(.effort))
        #expect(ConversationSlashItem.matching("mcp", commands: commands).first?.action == .control(.mcp))
        #expect(ConversationSlashItem.matching("context", commands: commands).first?.action == .control(.context))
    }

    @Test("status・cost・usage は CLI に送らず、［情報］を開く操作にする（CLI に同じ名前があっても）")
    func info() {
        let cli = commands + [ConversationCommand(name: "status", description: "状態", builtin: true), ConversationCommand(name: "usage", description: "利用枠", builtin: true)]
        #expect(ConversationSlashItem.matching("status", commands: cli).map(\.action) == [.taskboard(.status)])
        #expect(ConversationSlashItem.matching("usage", commands: cli).map(\.action) == [.taskboard(.usage)])
        #expect(ConversationSlashItem.matching("cost", commands: cli).map(\.action) == [.taskboard(.cost)])
    }

    @Test("CLI と同じ名前の taskboard の操作は 1 つにまとめ、taskboard の操作にする（TUI の画面を出すコマンドは会話で使えない）")
    func taskboardWins() {
        let items = ConversationSlashItem.matching("rewind", commands: commands)
        #expect(items.map(\.name) == ["rewind"])
        #expect(items.first?.action == .taskboard(.rewind))
        // CLI の alias で引いても taskboard の操作は出ない（alias は CLI の rewind のもの）
        #expect(ConversationSlashItem.matching("checkpoint", commands: commands).isEmpty)
    }

    @Test("CJK の名前も頭と途中で引ける。途中に含むものは後")
    func cjk() {
        #expect(ConversationSlashItem.matching("日本", commands: commands).map(\.name) == ["日本語の手順"])
        #expect(ConversationSlashItem.matching("手順", commands: commands).map(\.name) == ["日本語の手順"])
        let mixed = ConversationSlashItem.matching("e", commands: commands).map(\.name)
        #expect(mixed.prefix(1) == ["effort"])
        #expect(mixed.contains("rewind"))
    }

    @Test("空なら先頭から上限まで。合わなければ空。一覧が無くても taskboard の操作は出る")
    func edges() {
        #expect(ConversationSlashItem.matching("", commands: commands, limit: 3).count == 3)
        #expect(ConversationSlashItem.matching("zzz", commands: commands).isEmpty)
        #expect(ConversationSlashItem.matching("fo", commands: []).map(\.action) == [.taskboard(.fork)])
        // Claude には taskboard の圧縮・名前の変更・新しい thread・レビューが無い（CLI の `/compact`・`/rename`・`/clear`・`/review` を送る）
        #expect(ConversationSlashItem.matching("", commands: [], limit: 50).count == ConversationTaskboardAction.allCases.count - 4)
    }
}

@Suite("発言のメニューの対象")
struct ConversationMessageTargetTests {
    private func message(_ id: String, _ role: ChatMessage.Role, _ kind: ChatMessage.Kind, _ text: String = "x") -> ChatMessage {
        ChatMessage(id: id, role: role, kind: kind, text: text)
    }

    @Test("巻き戻せるのは人が送った文だけ（ツールの結果・知らせ・Claude の発言は除く）")
    func rewind() {
        #expect(message("u1", .user, .text, "直して").isRewindTarget)
        #expect(message("u2#0", .user, .text, "画像の後の文").isRewindTarget)
        #expect(message("u3", .user, .text, "日本語の指示").isRewindTarget)
        #expect(!message("u4#1", .user, .toolResult).isRewindTarget)
        #expect(!message("u5", .user, .notice, "中断しました").isRewindTarget)
        #expect(!message("a1#0", .assistant, .text).isRewindTarget)
        #expect(!message("a1#1", .assistant, .toolUse).isRewindTarget)
    }

    @Test("taskboard が入れた知らせは巻き戻しの対象にしない。人が taskboard の画面で答えた回答は人の発言として残す")
    func rewindSkipsTaskboardNotices() {
        let delegate = message("u6", .user, .text, "taskboard: 委譲先の会話 221737fa（#172）がターンを終えました。最後の返事:\n終わりました")
        let resume = message("u7", .user, .text, "利用枠が戻ったので、止まったところから続けてください。")
        let review = message("u8", .user, .text, "taskboard でレビューしました（#90）。\n総括: よい")
        let answer = message("u9", .user, .text, "taskboard で質問に答えました（#172）。\n「問い」→ 答え")
        #expect(!delegate.isRewindTarget && !resume.isRewindTarget && !review.isRewindTarget)
        #expect(answer.isRewindTarget)
        #expect(delegate.taskboardNotice == .delegate && answer.taskboardNotice == .answer)
        #expect(message("u1", .user, .text, "直して").taskboardNotice == nil)
        // Claude の発言と差し込みの文は、同じ文でも知らせにしない
        #expect(message("a2", .assistant, .text, "利用枠が戻ったので、止まったところから続けてください。").taskboardNotice == nil)
    }

    @Test("フォークできるのは transcript に行のある発言（手元で作った知らせと省いた印は除く）")
    func fork() {
        #expect(message("a1#0", .assistant, .text).isForkTarget)
        #expect(message("a1#1", .assistant, .toolUse).isForkTarget)
        #expect(message("u4#1", .user, .toolResult).isForkTarget)
        #expect(message("u5", .user, .notice, "中断しました").isForkTarget)
        #expect(!message("notice-e1-3", .assistant, .notice).isForkTarget)
        #expect(!message("large-12", .user, .notice).isForkTarget)
        #expect(!message("line-4", .user, .text).isForkTarget)
    }
}

@Suite("Run の出力の手元")
struct ConversationRunStoreTests {
    private func run(_ id: String, message: String? = "a1", code: String = "ls", status: ConversationRun.Status = .running, output: String = "") -> ConversationRun {
        ConversationRun(
            id: id, conversationID: "c1", messageID: message, language: "bash", code: code, status: status, output: output, startedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("流れてきた続きを足し、状態と終了コードを替える")
    func chunks() {
        var store = ConversationRunStore()
        store.started(run("r1"))
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .running, chunk: "one\n", truncated: false))
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .running, chunk: "二行目\n", truncated: false))
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .failed, exitCode: 2, chunk: "", truncated: true))
        let shown = store.latest(messageID: "a1", code: "ls")
        #expect(shown?.output == "one\n二行目\n")
        #expect(shown?.status == .failed)
        #expect(shown?.exitCode == 2)
        #expect(shown?.truncated == true)
    }

    @Test("始めた応答より先に出力が届いても失わない")
    func updateBeforeStart() {
        var store = ConversationRunStore()
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .running, chunk: "early", truncated: false))
        store.started(run("r1"))
        #expect(store.latest(messageID: "a1", code: "ls")?.output == "early")
        #expect(store.latest(messageID: "a1", code: "ls")?.code == "ls")
    }

    @Test("全部の出力で置き換える（開き直したとき）")
    func replace() {
        var store = ConversationRunStore()
        store.started(run("r1"))
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .running, chunk: "部分", truncated: false))
        store.replace(run("r1", status: .succeeded, output: "全部の出力"))
        #expect(store.latest(messageID: "a1", code: "ls")?.output == "全部の出力")
        #expect(store.latest(messageID: "a1", code: "ls")?.status == .succeeded)
    }

    @Test("同じブロックを何度か動かしたら新しい方を出す。ほかのブロックとは混ぜない")
    func latest() {
        var store = ConversationRunStore()
        store.started(run("r1", status: .succeeded))
        store.started(run("r2", code: "pwd"))
        store.started(run("r3"))
        #expect(store.latest(messageID: "a1", code: "ls")?.id == "r3")
        #expect(store.latest(messageID: "a1", code: "pwd")?.id == "r2")
        #expect(store.latest(messageID: "a2", code: "ls") == nil)
        #expect(store.latest(messageID: nil, code: "ls") == nil)
    }

    @Test("始めた応答の出力が空でも、届いた出力を消さない。終わった状態は応答で戻さない")
    func startedKeepsProgress() {
        var store = ConversationRunStore()
        store.apply(ConversationRunUpdate(id: "r1", messageID: "a1", status: .succeeded, exitCode: 0, chunk: "done", truncated: false))
        store.started(run("r1", status: .running))
        #expect(store.latest(messageID: "a1", code: "ls")?.status == .succeeded)
        #expect(store.latest(messageID: "a1", code: "ls")?.output == "done")
    }
}

@Suite("巻き戻しで手元を捨てる")
struct ConversationResetTests {
    @Test("reset の出来事で発言を捨て、履歴を取り直す。先に出した発言は残す")
    func reset() {
        var timeline = ConversationTimeline()
        timeline.mergeHistory(
            ConversationHistoryResponse(messages: [ChatMessage(id: "u1", role: .user, kind: .text, text: "前の指示")], nextCursor: nil, agentSessionID: "a1"),
            older: false)
        timeline.subscribed(epoch: "e")
        timeline.addOutgoing(clientMessageID: "o1", text: "送っている", at: Date(timeIntervalSince1970: 0))
        let effects = timeline.apply(ConversationEvent(seq: 1, conversationID: "c1", at: Date(timeIntervalSince1970: 0), kind: .reset))
        #expect(effects == [.reloadHistory])
        #expect(timeline.messages.isEmpty)
        #expect(timeline.historyState == .notLoaded)
        #expect(timeline.outgoing.map(\.clientMessageID) == ["o1"])
        // 巻き戻した後の新しい Claude の会話 ID の履歴をそのまま受ける
        timeline.mergeHistory(ConversationHistoryResponse(messages: [], nextCursor: nil, agentSessionID: "a2"), older: false)
        #expect(timeline.agentSessionID == "a2")
    }
}
