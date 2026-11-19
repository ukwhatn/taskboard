import Foundation
import NIOCore

final class LineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    private var search = NewlineSearch()

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = search.next(in: buffer) else { return .needMoreData }
        let line = buffer.readSlice(length: length)!
        buffer.moveReaderIndex(forwardBy: 1)
        if line.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(line))
        }
        return .continue
    }

    func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        while try decode(context: context, buffer: &buffer) == .continue {}
        if buffer.readableBytes > 0 {
            let rest = buffer.readSlice(length: buffer.readableBytes)!
            context.fireChannelRead(wrapInboundOut(rest))
        }
        return .needMoreData
    }
}

/// 読み残しの頭から次の改行までの長さを探す。探し終えた所を覚え、次は新しく届いた分だけを探す
/// （毎回頭から探すと、長い 1 行を小分けに受けたときに行の長さの 2 乗の時間がかかる）。
/// 覚えるのは読み残しの頭からの距離なので、ByteToMessageHandler が読んだ分を詰めても狂わない
struct NewlineSearch {
    private var scanned = 0

    // memberwise init は private の scanned があると file の外から呼べない（debug のビルドでは通り、release で落ちた）
    init() {}

    mutating func next(in buffer: ByteBuffer) -> Int? {
        let found = buffer.withUnsafeReadableBytes { bytes -> Int? in
            guard scanned < bytes.count, let base = bytes.baseAddress else { return nil }
            guard let hit = memchr(base + scanned, Int32(UInt8(ascii: "\n")), bytes.count - scanned) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
        scanned = found == nil ? buffer.readableBytes : 0
        return found
    }

    /// 読み残しを捨てた（探した所も無かったことにする）
    mutating func reset() { scanned = 0 }
}
