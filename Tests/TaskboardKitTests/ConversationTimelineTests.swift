import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話の手元の発言")
struct ConversationTimelineTests {
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)

    func user(_ id: String, _ text: String) -> ChatMessage { ChatMessage(id: id, role: .user, kind: .text, text: text) }
    func assistant(_ id: String, _ text: String) -> ChatMessage { ChatMessage(id: id, role: .assistant, kind: .text, text: text) }

    func event(_ seq: Int, _ kind: ConversationEvent.Kind) -> ConversationEvent {
        ConversationEvent(seq: seq, conversationID: "c1", at: t0, kind: kind)
    }

    func page(_ messages: [ChatMessage], next: String?, session: String = "a1") -> ConversationHistoryResponse {
        ConversationHistoryResponse(messages: messages, nextCursor: next, agentSessionID: session)
    }

    @Test("履歴のページと購読の発言を id で重ね、古い順に並べる")
    func mergesByID() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        // 履歴を取っている間に購読で届いた発言（履歴の最後と重なる）
        _ = timeline.apply(event(1, .messages([assistant("m3", "三"), assistant("m4", "四")], apiMessageID: nil)))
        timeline.mergeHistory(page([user("m1", "一"), assistant("m2", "二"), assistant("m3", "三")], next: "c-old"), older: false)
        #expect(timeline.messages.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(timeline.historyState == .more)
        timeline.mergeHistory(page([user("m0", "零"), user("m1", "一")], next: nil), older: true)
        #expect(timeline.messages.map(\.id) == ["m0", "m1", "m2", "m3", "m4"])
        #expect(timeline.historyState == .complete)
        // 同じ id の発言が届いたら置き換える（並びは変えない）
        _ = timeline.apply(event(2, .messages([assistant("m2", "二（直した）")], apiMessageID: nil)))
        #expect(timeline.messages.map(\.text) == ["零", "一", "二（直した）", "三", "四"])
    }

    func messages(_ ids: [String]) -> ConversationEvent.Kind { .messages(ids.map { assistant($0, $0) }, apiMessageID: nil) }

    func toolUse(_ id: String, parent: String? = nil) -> ChatMessage {
        ChatMessage(id: "u-\(id)", role: .assistant, kind: .toolUse, text: "ls", toolName: "Bash", toolID: id, parentToolID: parent)
    }
    func toolResult(_ id: String, parent: String? = nil) -> ChatMessage {
        ChatMessage(id: "r-\(id)", role: .user, kind: .toolResult, text: "ok", toolID: id, parentToolID: parent)
    }

    @Test("応答を待っているだけか：書いている block も実行中のツールも無い間。書き終えた文は待ちのまま、ツールの入力と結果の来ていない呼び出しは待ちでない")
    func awaitingResponse() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        #expect(timeline.isAwaitingResponse, "何も来ていない")
        _ = timeline.apply(event(1, .messages([user("h1", "実行して"), assistant("a0", "前の回")], apiMessageID: nil)))
        #expect(timeline.isAwaitingResponse)

        // 書いている文
        _ = timeline.apply(event(2, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        #expect(!timeline.isAwaitingResponse)
        _ = timeline.apply(event(3, .blockStop(messageID: "msg1", index: 0)))
        #expect(timeline.isAwaitingResponse, "書き終えた文は、次の発言が届くまで残るだけ")

        // ツールの入力
        _ = timeline.apply(event(4, .blockStart(messageID: "msg1", index: 1, block: .toolInput, toolName: "Bash")))
        _ = timeline.apply(event(5, .blockStop(messageID: "msg1", index: 1)))
        #expect(!timeline.isAwaitingResponse, "呼び出しが届くまでの間もツールの回")

        // 呼び出しが届き、結果が来ていない間は実行中。サブエージェントの中の呼び出しは数えない
        _ = timeline.apply(event(6, .messages([toolUse("t1"), toolUse("s1", parent: "t1")], apiMessageID: "msg1")))
        #expect(!timeline.isAwaitingResponse)
        _ = timeline.apply(event(7, .messages([toolResult("s1", parent: "t1")], apiMessageID: nil)))
        #expect(!timeline.isAwaitingResponse, "親の呼び出しの結果がまだ")
        _ = timeline.apply(event(8, .messages([toolResult("t1")], apiMessageID: nil)))
        #expect(timeline.isAwaitingResponse, "結果の後の、次の応答の待ち")

        // 前の回の、結果の来なかった呼び出しは、次の人の発言の後には数えない
        _ = timeline.apply(event(9, .messages([toolUse("t0"), user("h2", "続けて")], apiMessageID: nil)))
        #expect(timeline.isAwaitingResponse)
    }

    @Test("開いたときに控えを最初から流しても、先に届いた履歴のページの前後に正しく並べる（流した古い発言を末尾に足さない）")
    func replayAfterPage() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 6)
        timeline.mergeHistory(page([assistant("m3", "m3"), assistant("m4", "m4"), assistant("m5", "m5")], next: "c-old"), older: false)
        _ = timeline.apply([
            event(1, messages(["m1"])), event(2, messages(["m2"])), event(3, messages(["m3"])), event(4, .notice("停止しました")),
            event(5, messages(["m4", "m5"])), event(6, messages(["m6"])),
        ])
        #expect(timeline.messages.map(\.id) == ["m1", "m2", "m3", "notice-e1-4", "m4", "m5", "m6"])
        // 流し終えた後の発言は末尾に足す
        _ = timeline.apply(event(7, messages(["m7"])))
        #expect(timeline.messages.map(\.id).suffix(2) == ["m6", "m7"])
    }

    @Test("流し直しの範囲（replayThrough）: 開いたときに控えを最初から流す間と、後から gap が来て流し直す間は through まで。流し終えたら nil")
    func replayThrough() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 2)
        #expect(timeline.replayThrough == 2, "手元に何も当てていなければ控えを最初から流す")
        _ = timeline.apply([event(1, messages(["m1"])), event(2, messages(["m2"]))])
        _ = timeline.apply(event(3, messages(["m3"])))
        #expect(timeline.replayThrough == nil)
        // 繋ぎ直し：手元に当てた出来事があるので、控えは続きからで流し直さない
        timeline.subscribed(epoch: "e1", through: 5)
        #expect(timeline.replayThrough == nil)
        // daemon が控えを落とした（gap）。続けて控えが最初から流れてくる
        _ = timeline.apply(event(4, .gap))
        #expect(timeline.replayThrough == 5)
        _ = timeline.apply([event(5, messages(["m1"])), event(6, messages(["m6"]))])
        #expect(timeline.replayThrough == nil)
    }

    @Test("控えを何回かに分けて当てても、前に流した発言の後ろに続けて置く")
    func replayInBatches() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 5)
        timeline.mergeHistory(page([assistant("m4", "m4"), assistant("m5", "m5")], next: "c-old"), older: false)
        _ = timeline.apply([event(1, messages(["m1"])), event(2, messages(["m2"]))])
        _ = timeline.apply([event(3, messages(["m3"]))])
        _ = timeline.apply([event(4, messages(["m4"])), event(5, messages(["m5"]))])
        #expect(timeline.messages.map(\.id) == ["m1", "m2", "m3", "m4", "m5"])
    }

    @Test("控えを流し終えてから履歴のページが届いても、どちらにもある発言を目印に並べる")
    func pageAfterReplay() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 3)
        // 控えは m4 から（上限で前が落ちた）。m6 はまだ transcript に無い
        _ = timeline.apply([event(1, messages(["m4"])), event(2, messages(["m5"])), event(3, messages(["m6"]))])
        timeline.mergeHistory(page([assistant("m2", "m2"), assistant("m3", "m3"), assistant("m4", "m4"), assistant("m5", "m5")], next: "c-old"), older: false)
        #expect(timeline.messages.map(\.id) == ["m2", "m3", "m4", "m5", "m6"])
        #expect(timeline.historyState == .more)
    }

    @Test("目印の無い発言は時刻で並べる（daemon が起き直して控えに知らせだけがある）")
    func ordersByTimeWithoutAnchor() {
        let older = ChatMessage(id: "m1", role: .user, kind: .text, text: "一", at: t0)
        let newer = ChatMessage(id: "m2", role: .assistant, kind: .text, text: "二", at: t0.addingTimeInterval(10))
        let notice = ConversationEvent(seq: 1, conversationID: "c1", at: t0.addingTimeInterval(20), kind: .notice("停止しました"))
        // ページが先
        var pageFirst = ConversationTimeline()
        pageFirst.subscribed(epoch: "e1", through: 1)
        pageFirst.mergeHistory(page([older, newer], next: nil), older: false)
        _ = pageFirst.apply([notice])
        #expect(pageFirst.messages.map(\.id) == ["m1", "m2", "notice-e1-1"])
        // 控えが先
        var replayFirst = ConversationTimeline()
        replayFirst.subscribed(epoch: "e1", through: 1)
        _ = replayFirst.apply([notice])
        replayFirst.mergeHistory(page([older, newer], next: nil), older: false)
        #expect(replayFirst.messages.map(\.id) == ["m1", "m2", "notice-e1-1"])
    }

    @Test("続きから購読し直したときに届く、切れていた間の発言は末尾に足す")
    func resumeAppends() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 0)
        timeline.mergeHistory(page([assistant("m1", "m1")], next: nil), older: false)
        _ = timeline.apply(event(1, messages(["m2"])))
        timeline.subscribed(epoch: "e1", through: 3)
        _ = timeline.apply([event(2, messages(["m3"])), event(3, messages(["m4"]))])
        #expect(timeline.messages.map(\.id) == ["m1", "m2", "m3", "m4"])
    }

    @Test("違う daemon の起動に購読し直したら、手元を捨てて履歴を取り直し、続く控えを最初から流したものとして並べる")
    func epochChangeReloads() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 0)
        timeline.mergeHistory(page([assistant("m1", "m1"), assistant("m2", "m2")], next: nil), older: false)
        _ = timeline.apply(event(5, messages(["m3"])))
        #expect(timeline.subscribed(epoch: "e2", through: 2) == [.reloadHistory])
        #expect(timeline.messages.isEmpty)
        #expect(timeline.historyState == .notLoaded)
        // daemon が送る gap（seq 0）は当てずに読み捨てる
        #expect(timeline.apply(event(0, .gap)).isEmpty)
        _ = timeline.apply([event(1, messages(["m3"])), event(2, messages(["m4"]))])
        timeline.mergeHistory(page([assistant("m2", "m2"), assistant("m3", "m3")], next: "c-old"), older: false)
        #expect(timeline.messages.map(\.id) == ["m2", "m3", "m4"])
    }

    @Test("gap の後に流れてくる控えは、最初から流したものとして並べる")
    func replayAfterGap() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1", through: 0)
        timeline.mergeHistory(page([assistant("m1", "m1")], next: nil), older: false)
        _ = timeline.apply(event(1, messages(["m2"])))
        timeline.subscribed(epoch: "e1", through: 9)
        #expect(timeline.apply(event(6, .gap)) == [.reloadHistory])
        // 取り直したページが先に届き、続けて控えが流れる
        timeline.mergeHistory(page([assistant("m8", "m8"), assistant("m9", "m9")], next: "c-old"), older: false)
        _ = timeline.apply([event(7, messages(["m7"])), event(8, messages(["m8"])), event(9, messages(["m9"]))])
        _ = timeline.apply(event(10, messages(["m10"])))
        #expect(timeline.messages.map(\.id) == ["m7", "m8", "m9", "m10"])
    }

    @Test("当てた seq 以前の出来事は読み捨て、違う起動の印なら seq を数え直す")
    func ignoresReplayedEvents() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(5, .messages([assistant("m1", "a")], apiMessageID: nil)))
        _ = timeline.apply(event(5, .messages([assistant("m1", "b")], apiMessageID: nil)))
        _ = timeline.apply(event(4, .notice("古い")))
        #expect(timeline.messages.map(\.text) == ["a"])
        #expect(timeline.seq == 5)
        timeline.subscribed(epoch: "e1")
        #expect(timeline.seq == 5)
        timeline.subscribed(epoch: "e2")
        #expect(timeline.seq == 0)
        #expect(timeline.epoch == "e2")
    }

    @Test("先に出した発言は、写し（id が clientMessageID か <clientMessageID>#<n>）が届いたら消える")
    func outgoingReplacedByEcho() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        timeline.addOutgoing(clientMessageID: "cm1", text: "こんにちは", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "look at this", attachmentCount: 1, at: t0)
        #expect(timeline.outgoing.map(\.state) == [.sending, .sending])
        timeline.markSent("cm1")
        #expect(timeline.outgoing.first?.state == .accepted)
        _ = timeline.apply(event(1, .messages([user("cm1", "こんにちは")], apiMessageID: nil)))
        #expect(timeline.outgoing.map(\.clientMessageID) == ["cm2"])
        // 画像つきの発言は block ごとに #<n> で届く
        _ = timeline.apply(event(2, .messages([user("cm2#0", "[image]"), user("cm2#1", "look at this")], apiMessageID: nil)))
        #expect(timeline.outgoing.isEmpty)
        #expect(timeline.messages.map(\.id) == ["cm1", "cm2#0", "cm2#1"])
        // assistant の発言の id が偶然同じ接頭辞でも消さない
        timeline.addOutgoing(clientMessageID: "cm3", text: "x", at: t0)
        _ = timeline.apply(event(3, .messages([assistant("cm3#0", "y")], apiMessageID: nil)))
        #expect(timeline.outgoing.map(\.clientMessageID) == ["cm3"])
    }

    @Test("写しが履歴のページで先に届いても、先に出した発言は消える")
    func outgoingReplacedByHistory() {
        var timeline = ConversationTimeline()
        timeline.addOutgoing(clientMessageID: "cm1", text: "hi", at: t0)
        timeline.mergeHistory(page([user("cm1", "hi")], next: nil), older: false)
        #expect(timeline.outgoing.isEmpty)
    }

    @Test("生成中に送った発言は待機中で出し、started で受けた、cancelled で下書きに戻す")
    func queuedWhileGenerating() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "次はこれ", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "then this", at: t0)
        #expect(timeline.outgoing.map(\.state) == [.queued, .queued])
        timeline.markSent("cm1")
        #expect(timeline.outgoing.first?.state == .queued)
        _ = timeline.apply(event(2, .accepted(clientMessageID: "cm1", state: "queued")))
        _ = timeline.apply(event(3, .accepted(clientMessageID: "cm1", state: "started")))
        #expect(timeline.outgoing.first?.state == .accepted)
        let effects = timeline.apply(event(4, .accepted(clientMessageID: "cm2", state: "cancelled")))
        #expect(effects.count == 1)
        guard case .restoreDraft(let restored) = effects.first else {
            Issue.record("下書きに戻す知らせが無い")
            return
        }
        #expect(restored.text == "then this")
        #expect(timeline.outgoing.map(\.clientMessageID) == ["cm1"])
    }

    @Test("discarded・refused（CLI が取り込まなかった発言）も、待機中から外して下書きに戻す")
    func notTakenRestored() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "捨てられた", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "断られた", at: t0)
        timeline.addOutgoing(clientMessageID: "cm3", text: "残る", at: t0)
        _ = timeline.apply(event(2, .accepted(clientMessageID: "cm1", state: "queued")))
        let discarded = timeline.apply(event(3, .accepted(clientMessageID: "cm1", state: "discarded")))
        let refused = timeline.apply(event(4, .accepted(clientMessageID: "cm2", state: "refused")))
        for (effects, text) in [(discarded, "捨てられた"), (refused, "断られた")] {
            guard case .restoreDraft(let restored) = effects.first, effects.count == 1 else {
                Issue.record("\(text): 下書きに戻す知らせが無い")
                continue
            }
            #expect(restored.text == text)
        }
        #expect(timeline.outgoing.map(\.clientMessageID) == ["cm3"])
    }

    @Test("ターンの途中に取り込まれた発言は、送った uuid（画像つきは <uuid>#<n>）の人の文で届き、待機中の発言を消す。履歴を読み直したときも消える")
    func absorbedMidTurnDropsQueued() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "2c910b4d-0000-4000-8000-000000000001", text: "途中で読んで", at: t0)
        timeline.addOutgoing(clientMessageID: "2c910b4d-0000-4000-8000-000000000002", text: "これも", attachmentCount: 1, at: t0)
        _ = timeline.apply(event(2, .accepted(clientMessageID: "2c910b4d-0000-4000-8000-000000000001", state: "queued")))
        _ = timeline.apply(event(3, .messages([user("2c910b4d-0000-4000-8000-000000000001", "途中で読んで")], apiMessageID: nil)))
        _ = timeline.apply(event(4, .accepted(clientMessageID: "2c910b4d-0000-4000-8000-000000000001", state: "started")))
        _ = timeline.apply(event(5, .accepted(clientMessageID: "2c910b4d-0000-4000-8000-000000000001", state: "completed")))
        #expect(timeline.outgoing.map(\.clientMessageID) == ["2c910b4d-0000-4000-8000-000000000002"])
        timeline.mergeHistory(page([user("2c910b4d-0000-4000-8000-000000000002#0", "[image]"), user("2c910b4d-0000-4000-8000-000000000002#1", "これも")], next: nil), older: false)
        #expect(timeline.outgoing.isEmpty)
    }

    @Test("［取り消し］で捨てると決めた発言は、取り消されても下書きに戻さない。決めていない発言（［編集］・生成の停止）は戻す")
    func discardedNotRestored() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "捨てる", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "直す", at: t0)
        timeline.addOutgoing(clientMessageID: "cm3", text: "取り消せなかった", at: t0)
        timeline.discard("cm1")
        timeline.discard("cm3")
        timeline.keep("cm3")
        #expect(timeline.apply(event(2, .accepted(clientMessageID: "cm1", state: "cancelled"))).isEmpty)
        let restored = timeline.apply(event(3, .accepted(clientMessageID: "cm2", state: "cancelled")))
        let restoredCm3 = timeline.apply(event(4, .accepted(clientMessageID: "cm3", state: "cancelled")))
        #expect(restored.count == 1)
        #expect(restoredCm3.count == 1)
        #expect(timeline.outgoing.isEmpty)
    }

    @Test("待ち行列を持つのは Claude と codex の会話（知らない engine は持たない）")
    func queuesMessages() {
        #expect(Conversation.Engine.claude.queuesMessages)
        #expect(Conversation.Engine.codex.queuesMessages)
        #expect(!Conversation.Engine.unknown.queuesMessages)
    }

    @Test("待ち行列の無い engine では、生成中に送った発言を待機中にせず、受付（started）が来るまで送信中にする。送り直しも送信中に戻す")
    func noQueueWhileGenerating() {
        var timeline = ConversationTimeline()
        timeline.queuesMessages = false
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "途中で読んで", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "これも", at: t0)
        #expect(timeline.outgoing.map(\.state) == [.sending, .sending])
        timeline.markSent("cm1")
        timeline.markFailed("cm2")
        timeline.markRetrying("cm2")
        #expect(timeline.outgoing.map(\.state) == [.sending, .sending])
        _ = timeline.apply(event(2, .accepted(clientMessageID: "cm1", state: "started")))
        #expect(timeline.outgoing.map(\.state) == [.accepted, .sending])
    }

    @Test("［今すぐ送る］で待っている発言が無かった（もう渡っていた）ら、待機中の発言を受けた印にする。送っている・送れなかった発言は替えない")
    func queuedMarkedAccepted() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "途中で取り込まれた", at: t0)
        timeline.addOutgoing(clientMessageID: "cm2", text: "送れない", at: t0)
        timeline.markFailed("cm2")
        timeline.markAccepted("cm1")
        timeline.markAccepted("cm2")
        timeline.markAccepted("none")
        #expect(timeline.outgoing.map(\.state) == [.accepted, .failed])
    }

    @Test("送れなかった発言は印を付け、送り直すと同じ id のまま送っている印に戻る")
    func failedAndRetried() {
        var timeline = ConversationTimeline()
        timeline.addOutgoing(clientMessageID: "cm1", text: "送れない", at: t0)
        timeline.markFailed("cm1")
        #expect(timeline.outgoing.first?.state == .failed)
        timeline.markRetrying("cm1")
        #expect(timeline.outgoing.first?.state == .sending)
        #expect(timeline.outgoing.first?.clientMessageID == "cm1")
        // 同じ id をもう一度足しても 2 つにしない
        timeline.addOutgoing(clientMessageID: "cm1", text: "送れない", at: t0)
        #expect(timeline.outgoing.count == 1)
    }

    @Test("差分を生成中の block に足し、block の終わりの後に同じ message の終わった発言が届いても置き換える")
    func deltasReplacedByMessages() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .thinking, toolName: nil)))
        _ = timeline.apply(event(2, .delta(messageID: "msg1", index: 0, block: .thinking, text: "考え")))
        _ = timeline.apply(event(3, .blockStop(messageID: "msg1", index: 0)))
        _ = timeline.apply(event(4, .blockStart(messageID: "msg1", index: 1, block: .text, toolName: nil)))
        _ = timeline.apply(event(5, .delta(messageID: "msg1", index: 1, block: .text, text: "こんに")))
        _ = timeline.apply(event(6, .delta(messageID: "msg1", index: 1, block: .text, text: "ちは, world")))
        #expect(timeline.streaming.map(\.text) == ["考え", "こんにちは, world"])
        #expect(timeline.isGenerating)
        _ = timeline.apply(event(7, .blockStop(messageID: "msg1", index: 1)))
        _ = timeline.apply(event(8, .messages([assistant("u1#1", "こんにちは, world")], apiMessageID: "msg1")))
        #expect(timeline.streaming.isEmpty)
        #expect(timeline.messages.map(\.text) == ["こんにちは, world"])
        _ = timeline.apply(event(9, .blockStart(messageID: "msg2", index: 0, block: .toolInput, toolName: "Bash")))
        _ = timeline.apply(event(10, .delta(messageID: "msg2", index: 0, block: .toolInput, text: "{")))
        #expect(timeline.streaming.first?.toolName == "Bash")
        _ = timeline.apply(event(11, .turn(ConversationTurn(isError: false, stopReason: nil, durationMs: nil, ttftMs: nil, costUSD: nil, outputTokens: nil))))
        #expect(timeline.streaming.isEmpty)
        #expect(!timeline.isGenerating)
    }

    @Test("終わった発言が block の終わりより先に届いても（Claude Code 2.1.303 の順）、その message の block を消す")
    func messageBeforeBlockStop() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .thinking, toolName: nil)))
        _ = timeline.apply(event(2, .delta(messageID: "msg1", index: 0, block: .thinking, text: "考え")))
        _ = timeline.apply(event(3, .blockStop(messageID: "msg1", index: 0)))
        _ = timeline.apply(event(4, .blockStart(messageID: "msg1", index: 1, block: .text, toolName: nil)))
        _ = timeline.apply(event(5, .delta(messageID: "msg1", index: 1, block: .text, text: "調べます")))
        _ = timeline.apply(event(6, .messages([assistant("u1#1", "調べます")], apiMessageID: "msg1")))
        #expect(timeline.streaming.isEmpty)
        _ = timeline.apply(event(7, .blockStop(messageID: "msg1", index: 1)))
        _ = timeline.apply(event(8, .blockStart(messageID: "msg2", index: 0, block: .toolInput, toolName: "Bash")))
        _ = timeline.apply(event(9, .delta(messageID: "msg2", index: 0, block: .toolInput, text: "{\"command\":\"ls\"}")))
        let call = ChatMessage(id: "u1#2", role: .assistant, kind: .toolUse, text: "ls", toolName: "Bash", toolID: "toolu_1")
        _ = timeline.apply(event(10, .messages([call], apiMessageID: "msg2")))
        _ = timeline.apply(event(11, .blockStop(messageID: "msg2", index: 0)))
        #expect(timeline.streaming.isEmpty)
        #expect(timeline.messages.map(\.id) == ["u1#1", "u1#2"])
        // ほかの message の生成中の block は残す
        _ = timeline.apply(event(12, .blockStart(messageID: "msg3", index: 0, block: .text, toolName: nil)))
        _ = timeline.apply(event(13, .messages([assistant("u1#3", "前の")], apiMessageID: "msg2")))
        #expect(timeline.streaming.map(\.messageID) == ["msg3"])
    }

    @Test("start より先に差分が届いても block を作る")
    func deltaWithoutStart() {
        var timeline = ConversationTimeline()
        _ = timeline.apply(event(1, .delta(messageID: "msg1", index: 0, block: .text, text: "abc")))
        #expect(timeline.streaming.map(\.text) == ["abc"])
    }

    @Test("gap を受けたら発言を捨てて履歴を取り直す（先に出した発言は残す）")
    func gapDiscards() {
        var timeline = ConversationTimeline()
        timeline.subscribed(epoch: "e1")
        timeline.mergeHistory(page([user("m1", "一")], next: "old"), older: false)
        _ = timeline.apply(event(1, .blockStart(messageID: "msg1", index: 0, block: .text, toolName: nil)))
        timeline.addOutgoing(clientMessageID: "cm1", text: "待って", at: t0)
        #expect(timeline.apply(event(2, .gap)) == [.reloadHistory])
        #expect(timeline.messages.isEmpty)
        #expect(timeline.streaming.isEmpty)
        #expect(timeline.historyState == .notLoaded)
        #expect(timeline.olderCursor == nil)
        #expect(timeline.outgoing.count == 1)
        #expect(timeline.seq == 2)
    }

    @Test("Claude の会話 ID が変わったら手元を捨て、古い方のページでは取り直しを求める")
    func agentSessionChange() {
        var timeline = ConversationTimeline()
        timeline.mergeHistory(page([user("m1", "一")], next: "old"), older: false)
        #expect(timeline.agentSessionID == "a1")
        let continued = timeline.mergeHistory(page([user("x0", "古い")], next: nil, session: "a2"), older: true)
        #expect(!continued)
        #expect(timeline.messages.isEmpty)
        #expect(timeline.historyState == .notLoaded)
        let merged = timeline.mergeHistory(page([user("n1", "/clear の後")], next: nil, session: "a2"), older: false)
        #expect(merged)
        #expect(timeline.messages.map(\.id) == ["n1"])
        #expect(timeline.agentSessionID == "a2")
        #expect(timeline.historyState == .complete)
    }

    @Test("空のページ・空の差分・知らせ")
    func boundaries() {
        var timeline = ConversationTimeline()
        #expect(timeline.isEmpty)
        timeline.mergeHistory(page([], next: nil), older: false)
        #expect(timeline.historyState == .complete)
        #expect(timeline.isEmpty)
        _ = timeline.apply(event(1, .delta(messageID: "m", index: 0, block: .text, text: "")))
        #expect(timeline.streaming.first?.text == "")
        _ = timeline.apply(event(2, .notice("読めない行がありました")))
        _ = timeline.apply(event(3, .notice("unreadable line")))
        #expect(timeline.messages.map(\.kind) == [.notice, .notice])
        #expect(Set(timeline.messages.map(\.id)).count == 2)
        // 状態は購読に入れない。届いたら読み捨てる（seq は進める）
        let conversation = Conversation(
            id: "c1", machine: MachineID(rawValue: "m"), taskNumber: nil, agentSessionID: "a1", cwd: "/", runner: .host, phase: .idle,
            createdAt: t0, updatedAt: t0)
        #expect(timeline.apply(event(4, .conversation(conversation))).isEmpty)
        #expect(timeline.messages.count == 2)
        #expect(timeline.seq == 4)
    }

    @Test("新しく開いた順に上限まで持ち、溢れたら古い方を落とす")
    func recentlyUsed() {
        var cache = RecentlyUsed<String, Int>(limit: 3)
        for (i, key) in ["a", "b", "c", "d"].enumerated() { _ = cache.use(key) { i } }
        #expect(cache.keys == ["d", "c", "b"])
        #expect(cache.use("b") { 99 } == 1)
        #expect(cache.keys == ["b", "d", "c"])
        cache.remove("d")
        #expect(cache.keys == ["b", "c"])
        #expect(cache.peek("a") == nil)
    }
}
