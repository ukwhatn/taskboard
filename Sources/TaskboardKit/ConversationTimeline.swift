import Foundation

/// アプリの手元に持つ 1 つの会話の発言。履歴のページ・購読の出来事・先に出した発言を 1 つの並びに重ねる。
/// 状態（`Conversation`）は持たない（状態の出来事で `MachineState.conversations` に届く）
public struct ConversationTimeline: Hashable, Sendable {
    /// 終わった発言（古い順）。id で重ならない
    public private(set) var messages: [ChatMessage] = []
    /// 生成中の block（始まった順）。終わった発言が届いたら消える
    public private(set) var streaming: [StreamingBlock] = []
    /// 送った（送っている）発言のうち、写しがまだ届いていないもの（送った順）
    public private(set) var outgoing: [Outgoing] = []
    /// ［取り消し］で捨てると決めた発言の `clientMessageID`
    private var discarding: Set<String> = []
    /// 会話の engine が生成中の発言を待ち行列に入れるか（`Conversation.Engine.queuesMessages`）。入れない engine では、生成中に送った発言も受付が来るまで「送信中」
    public var queuesMessages = true
    /// 最後に当てた出来事の seq と、それを振った daemon の起動の印。購読し直すときに `after`・`epoch` で送る
    public private(set) var seq = 0
    public private(set) var epoch: String?
    /// 手元の発言を読んだ transcript の Claude の会話 ID。履歴で違う ID が返ったら手元を捨てる
    public private(set) var agentSessionID: String?
    /// 次に読む古い方のページの cursor。`historyState` が `.more` のときだけ意味がある
    public private(set) var olderCursor: String?
    public private(set) var historyState: HistoryState = .notLoaded
    /// 終わった発言が変わった回数。画面はこれで並びを組み直すかを決める（発言の配列を比べない）
    public private(set) var messagesVersion = 0
    /// 最後の `subscribed` の through（daemon が控えに持つ最後の seq）
    private var subscribedThrough = 0
    /// daemon が控えを最初から流している間（through まで）の置き方
    private var replay: Replay?

    /// 控えの初めは履歴のページより古いことが多く、流れてくる順は古い順。流した発言は前に流した発言の後ろに置く（末尾に足すと、ページより古い発言がページの後ろに並んだ）
    private struct Replay: Hashable, Sendable {
        var through: Int
        /// 最後に置いた発言の id。まだ 1 つも置いていなければ nil
        var anchor: String?
    }

    public enum HistoryState: Hashable, Sendable {
        /// まだ 1 ページも読んでいない（`gap` の後も戻る）
        case notLoaded
        /// 古い方のページがまだある
        case more
        /// 先頭まで読んだ
        case complete
    }

    public struct StreamingBlock: Hashable, Sendable, Identifiable {
        public var messageID: String
        public var index: Int
        public var block: ConversationEvent.DeltaBlock
        public var toolName: String?
        public var text: String
        /// `blockStop` を受けた。`messages` で同じ message が届いたら消す
        public var stopped: Bool

        public var id: String { "\(messageID)#stream\(index)" }
    }

    public struct Outgoing: Hashable, Sendable, Identifiable {
        public enum State: Hashable, Sendable {
            /// 送っている（daemon の応答を待っている）
            case sending
            /// 受けたが、生成中なので CLI の待ち行列にある
            case queued
            /// CLI が受けた（写しが届くまで残る）
            case accepted
            /// 送れなかった。同じ `clientMessageID` で送り直す
            case failed
        }

        public var clientMessageID: String
        public var text: String
        public var attachmentCount: Int
        /// 画像でない添付のファイルの名前
        public var fileNames: [String]
        public var state: State
        public var at: Date
        /// 後で送る（`ConversationSendRequest.later`）。今のターンには入らず、応答が終わってから始まる
        public var later = false

        public var id: String { clientMessageID }
    }

    /// 出来事を当てたあとに、手元の外でやること
    public enum Effect: Hashable, Sendable {
        /// 手元の発言を捨てた。履歴を末尾から取り直す
        case reloadHistory
        /// 待ち行列の発言が取り消された。下書きに戻す
        case restoreDraft(Outgoing)
        /// `/` で使えるコマンドの一覧が変わった
        case commands([ConversationCommand])
        /// コードブロックの Run の出力と状態
        case run(ConversationRunUpdate)
    }

    public init() {}

    /// 終わった発言・生成中・先に出した発言のどれも無い
    public var isEmpty: Bool { messages.isEmpty && streaming.isEmpty && outgoing.isEmpty }

    /// 生成中の block があるか
    public var isGenerating: Bool { !streaming.isEmpty }

    /// 会話が生成中のとき、engine の最初の（または次の）応答を待っているだけか。書いている block が無く（書き終えた文・thinking は次の発言を待つ間も残る）、
    /// ツールの入力の block も、結果の来ていない呼び出しも無い。ツールの結果は同じ回（最後の人の発言から後）の主の流れだけを見る
    public var isAwaitingResponse: Bool {
        if streaming.contains(where: { !$0.stopped || $0.block == .toolInput }) { return false }
        var resolved: Set<String> = []
        for message in messages.reversed() {
            if message.isHumanPrompt { break }
            guard !message.isSubagent, let toolID = message.toolID else { continue }
            if message.kind == .toolResult {
                resolved.insert(toolID)
            } else if message.kind == .toolUse, !resolved.contains(toolID) {
                return false
            }
        }
        return true
    }

    // MARK: 履歴

    /// 履歴の 1 ページを重ねる。`older` は上へ戻して取った古い方のページ。
    /// Claude の会話 ID が手元と違えば（`/clear`）、手元を捨ててこのページを新しい手元にし、古い方のページなら false を返す（末尾から取り直す）
    @discardableResult
    public mutating func mergeHistory(_ page: ConversationHistoryResponse, older: Bool) -> Bool {
        if let current = agentSessionID, current != page.agentSessionID {
            discardMessages()
            if older { return false }
        }
        agentSessionID = page.agentSessionID
        let echoes = Dictionary(page.messages.filter { $0.role == .user }.map { (Self.sentID($0.lineID), $0) }, uniquingKeysWith: { a, _ in a })
        for i in messages.indices { if let echo = echoes[messages[i].id] { messages[i] = echo } }
        if older {
            let known = Set(messages.map(\.id))
            messages = page.messages.filter { !known.contains($0.id) } + messages
        } else {
            messages = Self.merged(messages, page.messages)
        }
        messagesVersion += 1
        olderCursor = page.nextCursor
        if older || historyState == .notLoaded || page.nextCursor == nil {
            historyState = page.nextCursor == nil ? .complete : .more
        }
        dropEchoed()
        return true
    }

    // MARK: 購読

    /// 購読を始めた（`subscribed`）。`through` は daemon が控えに持つ最後の seq。手元に当てた出来事が無ければ、daemon は控えを最初から流す。
    /// 違う daemon の起動に繋ぎ直したら、手元を捨てて履歴を取り直す（daemon が続けて送る `gap` は seq 0 で、当てた seq を数え直した後では当たらない）
    @discardableResult
    public mutating func subscribed(epoch: String, through: Int = 0) -> [Effect] {
        var effects: [Effect] = []
        if let current = self.epoch, current != epoch {
            seq = 0
            if !messages.isEmpty || historyState != .notLoaded {
                discardMessages()
                effects.append(.reloadHistory)
            }
        }
        self.epoch = epoch
        subscribedThrough = through
        replay = seq == 0 && through > 0 ? Replay(through: through) : nil
        return effects
    }

    /// daemon が控えを最初から流している途中なら、流し終える seq（その購読の through）。開いたときと、後から `gap` が来たときに入る
    public var replayThrough: Int? { replay?.through }

    /// 購読の出来事を当てる。当てた seq 以前の出来事（繋ぎ直しの重なり）は読み捨てる
    public mutating func apply(_ event: ConversationEvent) -> [Effect] {
        apply([event])
    }

    /// 届いた順の出来事をまとめて当てる（1 件ずつ当てると、そのたびに並びを組み直した）
    public mutating func apply(_ events: [ConversationEvent]) -> [Effect] {
        var effects: [Effect] = []
        // 発言が届いたときだけ作る（作るたびに全発言の索引を組むので、生成中の差分だけの回では作らない）
        var placer: MessagePlacer?
        for event in events {
            guard event.seq > seq else { continue }
            seq = event.seq
            if let replay, event.seq > replay.through { self.replay = nil }
            switch event.kind {
            case .conversation, .unsupported:
                // 状態は状態の出来事で届く
                break
            case .blockStart(let messageID, let index, let block, let toolName):
                upsertBlock(messageID: messageID, index: index) { $0.block = block; $0.toolName = toolName } create: {
                    StreamingBlock(messageID: messageID, index: index, block: block, toolName: toolName, text: "", stopped: false)
                }
            case .delta(let messageID, let index, let block, let text):
                upsertBlock(messageID: messageID, index: index) { $0.text += text } create: {
                    StreamingBlock(messageID: messageID, index: index, block: block, toolName: nil, text: text, stopped: false)
                }
            case .blockStop(let messageID, let index):
                if let i = streaming.firstIndex(where: { $0.messageID == messageID && $0.index == index }) { streaming[i].stopped = true }
            case .messages(let incoming, let apiMessageID):
                place(incoming, with: &placer)
                // CLI は block ごとに、終わった発言を block の終わり（blockStop）より先に送る。次の block はその後に始まるので、
                // 届いた時点で同じ message の block はどれも終わっている
                if let apiMessageID { streaming.removeAll { $0.messageID == apiMessageID } }
            case .accepted(let clientMessageID, let state):
                guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { break }
                switch state {
                case "queued": outgoing[i].state = .queued
                // discarded・refused は CLI が取り込まなかった発言。取り消しと同じに外し、下書きへ戻す（daemon は cancelled にして送るが、直に流れてきても同じに読む）
                case "cancelled", "discarded", "refused":
                    let removed = outgoing.remove(at: i)
                    if discarding.remove(clientMessageID) == nil { effects.append(.restoreDraft(removed)) }
                case "started", "completed":
                    // CLI がターンに取り込んだ位置に置く。写しが来ないまま末尾に残ると、後のツールの行の下に出続けた（中断の直後に送った発言）
                    let sent = outgoing.remove(at: i)
                    place([ChatMessage(id: Self.sentID(sent.clientMessageID), role: .user, kind: .text, text: sent.text, at: event.at)], with: &placer)
                default: outgoing[i].state = .accepted
                }
            case .turn:
                streaming.removeAll()
            case .gap, .reset:
                discardMessages()
                placer = nil
                // gap の後には控えが最初から流れてくる。reset（巻き戻し）の後は新しい出来事だけ
                if case .gap = event.kind { replay = Replay(through: subscribedThrough) }
                effects.append(.reloadHistory)
            case .commands(let commands):
                effects.append(.commands(commands))
            case .run(let update):
                effects.append(.run(update))
            case .notice(let text):
                place([ChatMessage(id: "notice-\(epoch ?? "")-\(event.seq)", role: .assistant, kind: .notice, text: text, at: event.at)], with: &placer)
            }
        }
        if var placer, placer.changed {
            messages = placer.finish()
            messagesVersion += 1
            dropEchoed()
        }
        return effects
    }

    /// 受けた時点で置いた発言の id。写しの id は engine で違う（Claude は `uuid#0`、Codex は `uuid`）ので、`lineID` で写しと結ぶ
    static func sentID(_ clientMessageID: String) -> String { "\(clientMessageID)#sent" }

    private mutating func place(_ incoming: [ChatMessage], with placer: inout MessagePlacer?) {
        if placer == nil { placer = MessagePlacer(messages) }
        for message in incoming {
            if message.role == .user { placer?.rename(Self.sentID(message.lineID), to: message.id) }
            if var replay {
                placer?.place(message, after: &replay.anchor)
                self.replay = replay
            } else {
                placer?.upsert(message)
            }
        }
    }

    // MARK: 先に出す発言

    /// 送る前に出す。待ち行列のある engine が生成中なら、受けるまで待ち行列にあるので「待機中」で出す
    public mutating func addOutgoing(clientMessageID: String, text: String, attachmentCount: Int = 0, fileNames: [String] = [], later: Bool = false, at: Date) {
        guard !outgoing.contains(where: { $0.clientMessageID == clientMessageID }) else { return }
        outgoing.append(
            Outgoing(
                clientMessageID: clientMessageID, text: text, attachmentCount: attachmentCount, fileNames: fileNames, state: isGenerating ? waitingState : .sending, at: at,
                later: later))
    }

    /// ［今すぐ送信］を受けた後で送る発言は、今のターンに入れる発言になる
    public mutating func markSooner(_ clientMessageID: String) {
        guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { return }
        outgoing[i].later = false
    }

    /// 送信の応答を受けた。写しか `accepted` が先に届いていれば何もしない
    public mutating func markSent(_ clientMessageID: String) {
        guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }), outgoing[i].state == .sending || outgoing[i].state == .failed else { return }
        outgoing[i].state = isGenerating ? waitingState : .accepted
    }

    /// ［取り消し］で捨てる発言。取り消された（`accepted` の cancelled）ときに下書きに戻さない
    public mutating func discard(_ clientMessageID: String) {
        discarding.insert(clientMessageID)
    }

    /// 捨てるのをやめた（取り消せなかった・送れなかった）
    public mutating func keep(_ clientMessageID: String) {
        discarding.remove(clientMessageID)
    }

    /// 待機中の発言がもう CLI に渡っていた（［今すぐ送る］の `nothing_waiting`）。写しか `accepted` を待たずに受けた印にする
    public mutating func markAccepted(_ clientMessageID: String) {
        guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }), outgoing[i].state == .queued else { return }
        outgoing[i].state = .accepted
    }

    public mutating func markFailed(_ clientMessageID: String) {
        guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { return }
        outgoing[i].state = .failed
    }

    /// 送り直す前に、送っている印に戻す
    public mutating func markRetrying(_ clientMessageID: String) {
        guard let i = outgoing.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { return }
        outgoing[i].state = isGenerating ? waitingState : .sending
    }

    // MARK: 内側

    /// 生成中に送った発言の、受付が来るまでの印
    private var waitingState: Outgoing.State { queuesMessages ? .queued : .sending }

    /// 発言を捨てる（`gap`・Claude の会話 ID の変化）。先に出した発言は送った結果を待つので残す
    private mutating func discardMessages() {
        messages = []
        messagesVersion += 1
        streaming = []
        olderCursor = nil
        historyState = .notLoaded
        agentSessionID = nil
        replay = nil
    }

    /// 手元（購読で届いた順）に最初のページ（transcript の順）を重ねる。どちらにもある発言を目印にし、目印の間はそれぞれの順を保って時刻で混ぜる。
    /// 同じ id は手元の方を残す
    static func merged(_ local: [ChatMessage], _ page: [ChatMessage]) -> [ChatMessage] {
        let positions = MessagePlacer.index(local)
        var result: [ChatMessage] = []
        result.reserveCapacity(local.count + page.count)
        var next = 0
        var onlyPage: [ChatMessage] = []
        for message in page {
            guard let k = positions[message.id] else {
                onlyPage.append(message)
                continue
            }
            // 手元で先に置いた（2 つの順が食い違う）発言は、手元の位置のまま
            guard k >= next else { continue }
            result += interleaved(local[next..<k], onlyPage[...])
            onlyPage = []
            result.append(local[k])
            next = k + 1
        }
        result += interleaved(local[next...], onlyPage[...])
        return result
    }

    /// 2 つの古い順の並びを、どちらも時刻が分かる所だけ時刻で混ぜる（分からなければ手元を先に）
    private static func interleaved(_ local: ArraySlice<ChatMessage>, _ page: ArraySlice<ChatMessage>) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var i = local.startIndex
        var j = page.startIndex
        while i < local.endIndex, j < page.endIndex {
            if let a = local[i].at, let b = page[j].at, b < a {
                result.append(page[j])
                j += 1
            } else {
                result.append(local[i])
                i += 1
            }
        }
        return result + local[i...] + page[j...]
    }

    private mutating func upsertBlock(messageID: String, index: Int, update: (inout StreamingBlock) -> Void, create: () -> StreamingBlock) {
        if let i = streaming.firstIndex(where: { $0.messageID == messageID && $0.index == index }) {
            update(&streaming[i])
        } else {
            streaming.append(create())
        }
    }

    /// 写しが届いた先に出した発言を外す。写しの id は `clientMessageID` か `<clientMessageID>#<n>`
    private mutating func dropEchoed() {
        guard !outgoing.isEmpty else { return }
        let ids = Set(messages.filter { $0.role == .user }.map(\.lineID))
        outgoing.removeAll { ids.contains($0.clientMessageID) }
    }
}

/// 1 回に当てる出来事の発言を並びに置く。続けて途中へ差し込む発言はまとめて差し込む（1 件ずつ差し込むと、位置を数え直すのが発言の数の 2 乗になる）
struct MessagePlacer {
    private var messages: [ChatMessage]
    private var positions: [String: Int]
    /// まだ差し込んでいない発言（続けて置いた順）と、差し込む位置
    private var pending: [ChatMessage] = []
    private var pendingIDs: [String: Int] = [:]
    private var pendingAt = 0
    private(set) var changed = false

    init(_ messages: [ChatMessage]) {
        self.messages = messages
        positions = Self.index(messages)
    }

    static func index(_ messages: [ChatMessage]) -> [String: Int] {
        Dictionary(messages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// 置いてある発言の id を替える（受けた時点で置いた発言を、写しの id にして写しで置き換えさせる）
    mutating func rename(_ id: String, to newID: String) {
        if let i = pendingIDs.removeValue(forKey: id) {
            pending[i].id = newID
            pendingIDs[newID] = i
        } else if let i = positions.removeValue(forKey: id) {
            changed = true
            messages[i].id = newID
            positions[newID] = i
        }
    }

    /// 同じ id は置き換え、新しい id は末尾に足す
    mutating func upsert(_ message: ChatMessage) {
        changed = true
        if let i = pendingIDs[message.id] {
            pending[i] = message
            return
        }
        flush()
        if let i = positions[message.id] {
            messages[i] = message
        } else {
            positions[message.id] = messages.count
            messages.append(message)
        }
    }

    /// 同じ id は置き換え、新しい id は `anchor`（前に置いた発言）のすぐ後ろに置く。置いた発言を次の `anchor` にする。
    /// まだ 1 つも置いていなければ、時刻の分かる発言は時刻の位置に、分からなければ先頭に置く
    mutating func place(_ message: ChatMessage, after anchor: inout String?) {
        changed = true
        defer { anchor = message.id }
        if let i = pendingIDs[message.id] {
            pending[i] = message
            return
        }
        if positions[message.id] != nil {
            flush()
            if let i = positions[message.id] { messages[i] = message }
            return
        }
        if pending.isEmpty || anchor != pending.last?.id {
            flush()
            pendingAt = anchor.flatMap { positions[$0] }.map { $0 + 1 } ?? firstPosition(after: message.at)
        }
        pendingIDs[message.id] = pending.count
        pending.append(message)
    }

    mutating func finish() -> [ChatMessage] {
        flush()
        return messages
    }

    /// 時刻がこれより後の発言の最初の位置。時刻が分からなければ先頭
    private func firstPosition(after date: Date?) -> Int {
        guard let date else { return 0 }
        return messages.firstIndex { ($0.at ?? .distantPast) > date } ?? messages.count
    }

    private mutating func flush() {
        guard !pending.isEmpty else { return }
        messages.insert(contentsOf: pending, at: pendingAt)
        positions = Self.index(messages)
        pending = []
        pendingIDs = [:]
    }
}

/// 新しく開いた順に `limit` 個まで持つ入れ物（会話の手元・チャットの feed）
public struct RecentlyUsed<Key: Hashable, Value> {
    public let limit: Int
    private var entries: [(key: Key, value: Value)] = []

    public init(limit: Int) {
        self.limit = limit
    }

    public var keys: [Key] { entries.map(\.key) }

    public func peek(_ key: Key) -> Value? {
        entries.first { $0.key == key }?.value
    }

    /// 取り出して先頭に置く。無ければ `make` で作る。溢れた分は古い方から落とす
    public mutating func use(_ key: Key, make: () -> Value) -> Value {
        let value: Value
        if let index = entries.firstIndex(where: { $0.key == key }) {
            value = entries.remove(at: index).value
        } else {
            value = make()
        }
        entries.insert((key, value), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        return value
    }

    public mutating func remove(_ key: Key) {
        entries.removeAll { $0.key == key }
    }
}
