import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TaskboardKit

/// 指定の大きさの単色の画像を、指定の形式で作る
private func makeImage(width: Int, height: Int, as type: UTType = .png, noise: Bool = false) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
        // PNG で縮まない中身（乱数）にして、大きさの上限を超えさせる
        var generator = SystemRandomNumberGenerator()
        for i in 0..<(context.bytesPerRow * height) where i % 4 != 3 { pixels[i] = UInt8.random(in: 0...255, using: &generator) }
    }
    return ChatAttachment.encode(context.makeImage()!, as: type)!
}

private func pixelSize(_ data: Data) -> (Int, Int) {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    return (properties[kCGImagePropertyPixelWidth] as! Int, properties[kCGImagePropertyPixelHeight] as! Int)
}

@Suite("チャットに貼る画像")
struct ChatAttachmentTests {
    @Test("先頭のバイトで png・jpeg・gif・webp を見分け、ほかと短すぎるものは nil")
    func sniffing() {
        #expect(ChatAttachment.ImageType(sniffing: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])) == .png)
        #expect(ChatAttachment.ImageType(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(ChatAttachment.ImageType(sniffing: Data("GIF89a....".utf8)) == .gif)
        #expect(ChatAttachment.ImageType(sniffing: Data("GIF87a".utf8)) == .gif)
        #expect(ChatAttachment.ImageType(sniffing: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)) == .webp)
        #expect(ChatAttachment.ImageType(sniffing: Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)) == nil)
        #expect(ChatAttachment.ImageType(sniffing: Data("RIFF".utf8)) == nil)
        #expect(ChatAttachment.ImageType(sniffing: Data("MM\u{0}*".utf8)) == nil)  // TIFF
        #expect(ChatAttachment.ImageType(sniffing: Data("画像".utf8)) == nil)
        #expect(ChatAttachment.ImageType(sniffing: Data()) == nil)
        #expect(ChatAttachment.ImageType(sniffing: makeImage(width: 4, height: 4)) == .png)
        #expect(ChatAttachment.ImageType(sniffing: makeImage(width: 4, height: 4, as: .jpeg)) == .jpeg)
    }

    @Test("送れる形式で上限の内側なら、バイト列を変えずに返す")
    func passThrough() throws {
        let png = makeImage(width: 64, height: 48)
        let prepared = try #require(ChatAttachment.prepare(png))
        #expect(prepared.type == .png)
        #expect(prepared.data == png)
        let edge = makeImage(width: ChatAttachment.maxPixelSize, height: 10, as: .jpeg)
        #expect(try #require(ChatAttachment.prepare(edge)).data == edge)
    }

    @Test("TIFF（Mac のスクリーンショットのクリップボード）は PNG にする")
    func tiffBecomesPNG() throws {
        let tiff = makeImage(width: 30, height: 20, as: .tiff)
        let prepared = try #require(ChatAttachment.prepare(tiff))
        #expect(prepared.type == .png)
        #expect(pixelSize(prepared.data) == (30, 20))
    }

    @Test("長い辺が上限を超えたら、比を保って上限まで縮める")
    func scalesDown() throws {
        let wide = makeImage(width: ChatAttachment.maxPixelSize + 424, height: 1500)
        let prepared = try #require(ChatAttachment.prepare(wide))
        let (width, height) = pixelSize(prepared.data)
        #expect(width == ChatAttachment.maxPixelSize)
        #expect(abs(height - 1288) <= 1)  // 1500 × 2576 / 3000
        let tall = makeImage(width: 100, height: 3000)
        #expect(pixelSize(try #require(ChatAttachment.prepare(tall)).data).1 == ChatAttachment.maxPixelSize)
    }

    @Test("PNG で大きさの上限を超えるなら JPEG にして上限の内側に収める")
    func fallsBackToJPEG() throws {
        let noisy = makeImage(width: 1400, height: 1400, noise: true)
        #expect(noisy.count > ChatAttachment.maxBytes)
        let prepared = try #require(ChatAttachment.prepare(noisy))
        #expect(prepared.type == .jpeg)
        #expect(prepared.data.count <= ChatAttachment.maxBytes)
        #expect(pixelSize(prepared.data) == (1400, 1400))
    }

    @Test("画像として読めないものは nil")
    func unreadable() {
        #expect(ChatAttachment.prepare(Data()) == nil)
        #expect(ChatAttachment.prepare(Data("これは画像ではありません".utf8)) == nil)
        #expect(ChatAttachment.prepare(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil)
    }

}
