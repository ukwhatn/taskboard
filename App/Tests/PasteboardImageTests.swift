import AppKit
import Testing
@testable import Taskboard

@Suite("画像のコピー")
struct PasteboardImageTests {
    /// 2×1 の PNG
    private static func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test("PNG はそのまま PNG として置き、TIFF も添える")
    func pngAndTIFF() throws {
        // ユーザーのクリップボードを書き換えないよう、名前つきの pasteboard に置く
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("taskboard-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let data = try Self.png()
        #expect(Pasteboard.copy(image: data, to: pasteboard))
        #expect(pasteboard.data(forType: .png) == data)
        let tiff = try #require(pasteboard.data(forType: .tiff))
        #expect(NSImage(data: tiff)?.size == NSSize(width: 2, height: 1))
    }

    @Test("画像として読めない中身は置かず、前の中身も消さない")
    func unreadable() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("taskboard-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("前の中身", forType: .string)
        #expect(!Pasteboard.copy(image: Data("not an image".utf8), to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "前の中身")
    }
}
