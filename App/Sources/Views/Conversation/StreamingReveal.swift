import Foundation
import Observation
import TaskboardKit

/// 生成中の本文の block の、画面に見せる文。届いた文は `update` で受けるだけにし、見せる文はタイマーで `StreamingPace` の歩ずつ進める
/// （差分の届く頻度で描き直さない）。読むのは生成中の行だけ。
/// 初めて見えた block（会話を開いたときに控えから流れてきたもの）と止まった block は、届いている文を全部見せる。
/// 見せる文は書き終えた塊（`settled`。段落を書き終えたときだけ替わる）と書きかけ（`tails`。歩ごとに替わる）に分けても持ち、
/// Mac の一覧は塊ごとの行と書きかけの 1 行に並べる（伸びて測り直すのは書きかけの行だけ）
@MainActor
@Observable
final class StreamingReveal {
    /// block の id ごとの見せている文
    private(set) var shown: [String: String] = [:]
    /// block の id ごとの、見せている文のうち書き終えた塊
    private(set) var settled: [String: [String]] = [:]
    /// block の id ごとの、見せている文のうち最後の区切りより後ろ
    private(set) var tails: [String: String] = [:]
    @ObservationIgnored private var chunkers: [String: ChatMarkdownChunks] = [:]
    /// 届いている文と、そのうち見せている所（UTF-8 の位置）
    @ObservationIgnored private var targets: [String: String] = [:]
    @ObservationIgnored private var offsets: [String: Int] = [:]
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func text(for id: String) -> String { shown[id] ?? "" }

    func update(_ blocks: [ConversationTimeline.StreamingBlock]) {
        let texts = blocks.filter { $0.block == .text }
        let ids = Set(texts.map(\.id))
        for id in targets.keys where !ids.contains(id) {
            targets[id] = nil
            offsets[id] = nil
            shown[id] = nil
            settled[id] = nil
            tails[id] = nil
            chunkers[id] = nil
        }
        for block in texts {
            targets[block.id] = block.text
            if offsets[block.id] == nil || block.stopped {
                reveal(block.id, through: block.text.utf8.count)
            } else if let offset = offsets[block.id], offset > block.text.utf8.count {
                // 届いた文が短くなった（別の文に替わった）ら、届いている分まで戻す
                reveal(block.id, through: block.text.utf8.count)
            }
        }
        guard ticker == nil, isBehind else { return }
        ticker = Task { [weak self] in
            while let self, let wait = self.tick() {
                try? await Task.sleep(for: .seconds(wait))
            }
            self?.ticker = nil
        }
    }

    private var isBehind: Bool {
        targets.contains { id, text in (offsets[id] ?? 0) < text.utf8.count }
    }

    /// 遅れている block を 1 歩ずつ進め、次の歩までの秒を返す。遅れが無ければ nil
    private func tick() -> Double? {
        guard isBehind else { return nil }
        var wait = StreamingPace.maxInterval
        for (id, text) in targets {
            let offset = offsets[id] ?? 0
            guard offset < text.utf8.count else { continue }
            let step = StreamingPace.next(text, shown: offset)
            if step.shown != offset { reveal(id, through: step.shown) }
            wait = min(wait, step.wait)
        }
        return wait
    }

    private func reveal(_ id: String, through offset: Int) {
        guard let text = targets[id] else { return }
        offsets[id] = offset
        let prefix = String(decoding: text.utf8.prefix(offset), as: UTF8.self)
        if shown[id] != prefix { shown[id] = prefix }
        var chunker = chunkers[id] ?? ChatMarkdownChunks()
        let chunks = chunker.update(prefix, streaming: true)
        chunkers[id] = chunker
        if settled[id] != chunks.settled { settled[id] = chunks.settled }
        let tail = chunks.tail ?? ""
        if tails[id] != tail { tails[id] = tail }
    }
}
