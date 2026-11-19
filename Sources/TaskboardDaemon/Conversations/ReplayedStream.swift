import TaskboardKit

/// 控えの読み直しの間に受けた、主の流れの block（始めた順）。読み直しの差分は流さず、読み終えた時点で終わった発言が届いていない block だけを
/// 届いた分の文ごとに出す（daemon の入れ替えの後に開いた画面に、過去の発言が 1 文字ずつ流れ込まないように）
struct ReplayedStream {
    struct Block: Equatable {
        let messageID: String
        let index: Int
        let block: ConversationEvent.DeltaBlock
        let toolName: String?
        var text = ""
        var stopped = false
        /// 終わった発言が届いた（`ConversationEventLog.messageFinished` と同じく、その時点で始まっていた block は終わった扱い）
        var finished = false
    }

    private var blocks: [Block] = []

    mutating func start(messageID: String, index: Int, block: ConversationEvent.DeltaBlock, toolName: String? = nil) {
        blocks.append(Block(messageID: messageID, index: index, block: block, toolName: toolName))
    }

    mutating func append(messageID: String, index: Int, text: String) {
        update(messageID, index) { $0.text += text }
    }

    mutating func stop(messageID: String, index: Int) {
        update(messageID, index) { $0.stopped = true }
    }

    mutating func finish(messageID: String) {
        for position in blocks.indices where blocks[position].messageID == messageID { blocks[position].finished = true }
    }

    mutating func clear() { blocks.removeAll() }

    /// 読み終えた：出す block を返して空にする
    mutating func release() -> [Block] {
        defer { blocks.removeAll() }
        return blocks.filter { !$0.finished }
    }

    private mutating func update(_ messageID: String, _ index: Int, _ change: (inout Block) -> Void) {
        guard let position = blocks.lastIndex(where: { $0.messageID == messageID && $0.index == index }) else { return }
        change(&blocks[position])
    }
}

extension ConversationShell {
    /// 読み直しを終えた block を、始まり・届いた分の文・（止まっていれば）終わりの出来事にして出す
    func emitReplayed(_ blocks: [ReplayedStream.Block]) {
        for block in blocks {
            log.blockStarted(messageID: block.messageID, index: block.index)
            emit(.blockStart(messageID: block.messageID, index: block.index, block: block.block, toolName: block.toolName))
            if !block.text.isEmpty { emit(.delta(messageID: block.messageID, index: block.index, block: block.block, text: block.text)) }
            if block.stopped {
                emit(.blockStop(messageID: block.messageID, index: block.index))
                log.blockStopped(messageID: block.messageID, index: block.index)
            }
        }
    }
}
