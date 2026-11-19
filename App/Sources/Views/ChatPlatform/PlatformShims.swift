import SwiftUI

// 会話の一覧の行の部品（このフォルダ）を、Mac は AppKit、iPhone・iPad は UIKit の上で同じコードのまま組むための名前と手伝い。
// 部品は置ける幅を受けて自分で大きさを決め（`ChatFitting`）、地・枠・角丸は `draw(_:)` で描く。端末で違うのは、押し方・メニュー・選択・読み上げの口だけ

#if os(macOS)
import AppKit

typealias PlatformView = NSView
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#else
import UIKit

typealias PlatformView = UIView
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage

extension UIView {
    /// AppKit の `setFrameSize(_:)` と同じ（位置は動かさない）
    func setFrameSize(_ size: CGSize) {
        frame.size = size
    }

    /// AppKit の `needsDisplay` と同じ書き方で描き直しを頼む（読むと常に false）
    var needsDisplay: Bool {
        get { false }
        set { if newValue { setNeedsDisplay() } }
    }

    /// iPhone・iPad には説明の札（ポインタを載せて出す文）が無い。Mac と同じ書き方で書けるように置き、何もしない
    var toolTip: String? {
        get { nil }
        set {}
    }
}

extension CGRect {
    /// 今の描く先に、今の塗りの色で塗る（AppKit の `CGRect.fill()`）
    func fill() {
        UIRectFill(self)
    }
}
#endif

/// 部品の読み上げの役
enum ChatAccessibilityRole {
    case staticText, image, button, group, progress
}

extension PlatformView {
    /// 1 つの読み上げにする（`role` が nil なら読み上げない）
    func setChatAccessibility(_ role: ChatAccessibilityRole?, label: String? = nil, help: String? = nil) {
        #if os(macOS)
        setAccessibilityElement(role != nil)
        if let role {
            let value: NSAccessibility.Role = switch role {
            case .staticText: .staticText
            case .image: .image
            case .button: .button
            case .group: .group
            case .progress: .progressIndicator
            }
            setAccessibilityRole(value)
        }
        if let label { setAccessibilityLabel(label) }
        if let help { setAccessibilityHelp(help) }
        #else
        isAccessibilityElement = role != nil
        if let role { accessibilityTraits = role.traits }
        if let label { accessibilityLabel = label }
        if let help { accessibilityHint = help }
        #endif
    }
}

#if os(iOS)
extension ChatAccessibilityRole {
    var traits: UIAccessibilityTraits {
        switch self {
        case .staticText, .group: .staticText
        case .image: .image
        case .button: .button
        case .progress: .updatesFrequently
        }
    }
}
#endif

@MainActor
enum ChatSystem {
    /// 視差効果を減らす設定（`ChatMotion`）
    static var reducesMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// 開き方を渡されていないリンクをシステムで開く
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
