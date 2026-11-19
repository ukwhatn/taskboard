import ImageIO
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Pasteboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// 画像を元の形式のまま置く。Mac は TIFF も添える（PNG・JPEG を読まずに TIFF だけ受けるアプリがあるため）。読めない画像なら false
    #if os(macOS)
    @discardableResult
    static func copy(image data: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let tiff = NSImage(data: data)?.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        if let type = imageType(data), type != .tiff { item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier)) }
        item.setData(tiff, forType: .tiff)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
    #else
    @discardableResult
    static func copy(image data: Data) -> Bool {
        guard let image = UIImage(data: data) else { return false }
        if let type = imageType(data) {
            UIPasteboard.general.setItems([[type.identifier: data]])
        } else {
            UIPasteboard.general.image = image
        }
        return true
    }
    #endif

    /// 画像の中身から決めた形式（PNG・JPEG など）。読めなければ nil
    static func imageType(_ data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }

    static var string: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
