import Foundation
import NIOCore
import NIOEmbedded
import Testing

@testable import TaskboardDaemon

@Suite("区切りの行の切り出し（herdr・agent host の接続、host の子の出力）")
struct LineDecoderTests {
    private func feed(_ channel: EmbeddedChannel, _ parts: [String]) throws {
        for part in parts {
            var buffer = channel.allocator.buffer(capacity: part.utf8.count)
            buffer.writeString(part)
            try channel.writeInbound(buffer)
        }
    }

    private func lines(_ channel: EmbeddedChannel) throws -> [String] {
        var out: [String] = []
        while let line = try channel.readInbound(as: ByteBuffer.self) { out.append(String(buffer: line)) }
        return out
    }

    @Test("分かれて届いた行をつなぎ、1 回に届いた複数の行を分ける。空の行は出さない")
    func splitsAndJoins() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(LineFrameDecoder()))
        try feed(channel, ["あい", "う\nえ", "お\n\n", "か\nき"])
        #expect(try lines(channel) == ["あいう", "えお", "か"])
        _ = try channel.finish()
        #expect(try lines(channel) == ["き"])
    }

    @Test("host の子の出力も、分かれた行をつなぎ、上限を超えた行は捨てて大きさを知らせる")
    func boundedSplitsAndDiscards() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(BoundedLineDecoder(maximumLength: 8)))
        try feed(channel, ["abc", "d\n0123", "456789", "xyz\nok\n"])
        var out: [AgentHostLine] = []
        while let line = try channel.readInbound(as: AgentHostLine.self) { out.append(line) }
        #expect(out == [.line("abcd"), .oversize(bytes: 13), .line("ok")])
    }

    /// 画像 10 枚の発言（約 10MB の 1 行）を受けると、届くたびに頭から改行を探し直して 2 分止まっていた（2026-10-20）
    @Test("長い 1 行を小分けに受けても、届いた分だけを探す（10MB を 64KB ずつで数秒もかからない）")
    func longLineIsLinear() throws {
        for decoder in [ByteToMessageHandler(LineFrameDecoder()) as ChannelHandler, ByteToMessageHandler(BoundedLineDecoder(maximumLength: 16 << 20))] {
            let channel = EmbeddedChannel(handler: decoder)
            let chunk = String(repeating: "a", count: 64 << 10)
            let start = ContinuousClock.now
            try feed(channel, Array(repeating: chunk, count: 160) + ["\n"])
            #expect(ContinuousClock.now - start < .seconds(3))
            _ = try channel.finish()
        }
    }
}
