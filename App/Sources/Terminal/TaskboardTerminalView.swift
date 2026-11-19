import Foundation

#if os(macOS)
import AppKit
import GhosttyTerminal

/// 端末の platform view。`GhosttyTerminalEngine` が `TerminalViewState.makePlatformView` で渡す。
///
/// - 右クリックは、選んでいれば「コピー」「ペースト」、選んでいなければ「ペースト」のメニュー（ライブラリの選択のメニューは英語の「Copy」だけ）
final class TaskboardTerminalView: TerminalView {
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let selected = selectionMenuPoint(at: CGPoint(x: point.x, y: bounds.height - point.y)) != nil
        NSMenu.popUpContextMenu(contextMenu(copies: selected), with: event, for: self)
    }

    /// 押した方を自分で受けたので、離した方もライブラリに渡さない（渡すと、押していない右ボタンの離した報告がシェルに届く）
    override func rightMouseUp(with event: NSEvent) {}

    override func selectionContextMenu() -> NSMenu {
        contextMenu(copies: true)
    }

    /// 使えない項目は無効にせず出さない（選んでいなければコピーを出さない）
    private func contextMenu(copies: Bool) -> NSMenu {
        let menu = NSMenu()
        if copies {
            let copy = NSMenuItem(title: String(localized: "コピー"), action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        // paste(_:) はライブラリの中で internal だが @IBAction なので、selector で届く（⌘V と同じ経路）
        let paste = NSMenuItem(title: String(localized: "ペースト"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        paste.target = self
        menu.addItem(paste)
        return menu
    }
}
#endif
