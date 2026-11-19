#if DEBUG
import Foundation
import SwiftUI

/// 自ウィンドウをプロセス内で描画して PNG にする。Screen Recording の権限は要らない（実測済み）。
/// ガラスの透けは写らないので、レイアウトと状態の確認に使う。
@MainActor
enum WindowScreenshot {
    /// `scheme` はアプリが `preferredColorScheme` で上書きしている外観。SwiftUI の上書きは NSView の
    /// effectiveAppearance に乗らないので、撮る側で同じ外観を選ぶ。
    /// `index` を渡すと、見えている窓のその番目（`/menu` の windows と同じ並び）を撮る（設定の窓など）
    /// `popover` なら一番手前の popover の窓を撮る
    static func capture(scheme: ColorScheme? = nil, index: Int? = nil, popover: Bool = false) -> Data? {
        #if os(macOS)
        // シートが出ていればそれを撮る（アプリが前面でないと keyWindow は nil）
        let visible = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
        let chosen = index.flatMap { visible.indices.contains($0) ? visible[$0] : nil }
        let main = chosen ?? NSApp.mainWindow ?? visible.first
        let popoverWindow = popover ? NSApp.windows.first { $0.isVisible && $0.className.contains("Popover") } : nil
        guard let window = popoverWindow ?? main?.attachedSheet ?? (chosen == nil ? NSApp.keyWindow : nil) ?? main,
            let view = window.contentView,
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        // cacheDisplay はウィンドウ背景を描かず（透明のまま）、外観も明示しないとライトの色で描く。
        // ビューの外観で背景を塗ってから重ねる
        let appearance: NSAppearance = switch scheme {
        case .dark: NSAppearance(named: .darkAqua) ?? view.effectiveAppearance
        case .light: NSAppearance(named: .aqua) ?? view.effectiveAppearance
        default: view.effectiveAppearance
        }
        appearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: out)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let pixelBounds = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            pixelBounds.fill()
        }
        // 既定の合成は copy で、透明ピクセルが背景の塗りを消す
        rep.draw(in: pixelBounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .png, properties: [:])
        #else
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first
        else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
        #endif
    }
}
#endif
