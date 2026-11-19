import AppKit
import SwiftUI
import Testing
@testable import Taskboard

@MainActor
@Suite struct MultilineTextFieldTests {
    private final class Keys {
        var seen: [EventModifiers] = []
    }

    /// 窓に入力欄を置き、窓に ↩ の key equivalent を配る（AppKit がメニューより先に窓の view へ配るのと同じ経路）
    private func press(_ flags: NSEvent.ModifierFlags, focused: Bool = true) -> (taken: Bool, seen: [EventModifiers]) {
        let keys = Keys()
        let field = MultilineTextField(
            label: "メッセージ", text: .constant("hello"), lines: 1...4,
            commandKey: { key, modifiers in
                guard key == .return else { return false }
                keys.seen.append(modifiers)
                return true
            })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: field.frame(width: 400, height: 200))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let textView = Self.textView(in: host)
        #expect(textView != nil)
        if focused, let textView { window.makeFirstResponder(textView) }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        return (window.performKeyEquivalent(with: event), keys.seen)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    @Test("フォーカスのある入力欄は ⌘↩・⌥⌘↩ を受けて commandKey に渡す。⇧⌘↩ とフォーカスの無い欄は受けない（メニューに回す）")
    func commandReturn() {
        let command = press(.command)
        #expect(command.taken && command.seen == [.command])
        let option = press([.command, .option])
        #expect(option.taken && option.seen == [[.command, .option]], "\(option)")
        let shift = press([.command, .shift])
        #expect(!shift.taken && shift.seen.isEmpty)
        let unfocused = press(.command, focused: false)
        #expect(!unfocused.taken && unfocused.seen.isEmpty)
    }

    private final class Box {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// 窓に入力欄を置き、`text` の Binding で描いた欄の NSTextView と、同じ Binding で描き直す手続きを返す
    private func host(_ text: Binding<String>) -> (textView: NSTextView, redraw: () -> Void)? {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        // 描き直すたびに名前を変え、SwiftUI に updateNSView を必ず呼ばせる（同じ引数なら呼ばない）
        var count = 0
        let make = { MultilineTextField(label: "コメント\(count)", text: text, lines: 2...8).frame(width: 400, height: 200) }
        let host = NSHostingView(rootView: make())
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let textView = Self.textView(in: host) else { return nil }
        window.makeFirstResponder(textView)
        return (textView, {
            count += 1
            host.rootView = make()
            host.layoutSubtreeIfNeeded()
        })
    }

    @Test("文の途中に打った後に Binding が前の文のまま描き直されても、打った字とカーソルの位置を残す")
    func staleBindingKeepsTyping() throws {
        let field = try #require(host(.constant("abcdef")))
        field.textView.setSelectedRange(NSRange(location: 3, length: 0))
        field.textView.insertText("X", replacementRange: field.textView.selectedRange())
        field.redraw()
        #expect(field.textView.string == "abcXdef")
        #expect(field.textView.selectedRange() == NSRange(location: 4, length: 0))
    }

    @Test("文の途中に打って Binding に書いた後の描き直しは、カーソルを動かさない")
    func echoKeepsCaret() throws {
        let box = Box("あいうえお")
        let field = try #require(host(Binding(get: { box.text }, set: { box.text = $0 })))
        field.textView.setSelectedRange(NSRange(location: 2, length: 0))
        field.textView.insertText("漢", replacementRange: field.textView.selectedRange())
        field.redraw()
        #expect(box.text == "あい漢うえお")
        #expect(field.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("外で文が変わったら欄の文を入れ替え、カーソルは元の位置に残す（新しい文より後なら末尾）")
    func externalChangeKeepsCaret() throws {
        let box = Box("hello world")
        let field = try #require(host(Binding(get: { box.text }, set: { box.text = $0 })))
        field.textView.setSelectedRange(NSRange(location: 5, length: 0))
        box.text = "HELLO WORLD!"
        field.redraw()
        #expect(field.textView.string == "HELLO WORLD!")
        #expect(field.textView.selectedRange() == NSRange(location: 5, length: 0))
        box.text = "hi"
        field.redraw()
        #expect(field.textView.string == "hi")
        #expect(field.textView.selectedRange() == NSRange(location: 2, length: 0))
    }
}
