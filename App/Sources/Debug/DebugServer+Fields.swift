#if DEBUG
import Foundation
import QuartzCore
import SwiftUI
import TaskboardKit

extension DebugServer {
    /// 入力欄に長い文を入れたときの重さを測る口（本物のキーとクリップボードは使わない）
    func respondFields(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("GET", "/fields"):
            // 見えている窓の入力欄（Mac は NSTextField・NSTextView、iPhone と iPad は UITextField・UITextView）。名前（読み上げの名前かプレースホルダー）・種類・字数・窓の題・
            // 画面の位置（左上が原点。NSTextView は外の NSScrollView の位置。iPhone と iPad は窓の中の位置で、窓の題は測りの欄の窓だけ「測りの欄」）・フォーカスがあるか
            let fields = Self.textInputs().map { input in
                [
                    "name": Self.fieldName(input.view), "kind": String(describing: type(of: input.view)), "chars": Self.fieldText(input.view).count,
                    "window": Self.windowTitle(input.window), "frame": Self.screenFrame(input.view), "focused": Self.isFocused(input),
                ] as [String: Any]
            }
            return .json(200, ["fields": fields])
        case ("POST", "/field/fill"):
            // {"name": "メッセージ", "index": 0, "text": "…", "settleMs": 3000, "then": "あいう", "gapMs": 80, "keep": false}。
            // 名前の合う入力欄（name を省くと GET /fields の並びの全部）の index 番目にフォーカスを置き、貼り付けと同じく文の全部を insertText で一度に入れ替え、settleMs の間の主スレッドの使用時間と body が走った回数（`DebugCounters.hit` を置いた view）を返す。
            // 続けて then を末尾に 1 字ずつ足し、打鍵ごとの使用時間と body の回数を返す。keep でなければ最後に空にする
            let body = request.jsonBody ?? [:]
            guard let text = body["text"] as? String else { return .json(400, ["error": "text が要る"]) }
            let name = body["name"] as? String
            let matches = Self.textInputs().filter { name == nil || Self.fieldName($0.view) == name }
            let index = body["index"] as? Int ?? 0
            guard matches.indices.contains(index) else {
                return .json(404, ["error": "その入力欄が無い", "names": Self.textInputs().map { Self.fieldName($0.view) }])
            }
            let input = matches[index]
            guard Self.focus(input), let editor = Self.editor(of: input.view) else {
                return .json(409, ["error": "入力欄にフォーカスを置けない"])
            }
            let settle = Duration.milliseconds(body["settleMs"] as? Int ?? 3000)
            let then = Array(body["then"] as? String ?? "")
            let gap = Duration.milliseconds(body["gapMs"] as? Int ?? 80)
            DebugCounters.reset()
            MainThreadBusy.shared.start()
            let started = CACurrentMediaTime()
            editor.replaceAll(text)
            try? await Task.sleep(for: settle)
            let fill = MainThreadBusy.shared.stop()
            let fillBodies = DebugCounters.snapshot()
            let fillWall = (CACurrentMediaTime() - started) * 1000
            var typed: [String: Any] = [:]
            if !then.isEmpty {
                DebugCounters.reset()
                MainThreadBusy.shared.start()
                var marks: [CFTimeInterval] = []
                for character in then {
                    marks.append(CACurrentMediaTime())
                    editor.append(String(character))
                    try? await Task.sleep(for: gap)
                }
                marks.append(CACurrentMediaTime())
                typed = MainThreadBusy.perWindow(MainThreadBusy.shared.stop(), marks: marks)
                typed["bodies"] = DebugCounters.snapshot()
            }
            let chars = Self.fieldText(input.view).count
            if body["keep"] as? Bool != true { editor.replaceAll("") }
            return .json(200, [
                "kind": String(describing: type(of: input.view)), "chars": chars, "fill": MainThreadBusy.summary(fill),
                "fillWallMs": (fillWall * 10).rounded() / 10, "fillBodies": fillBodies, "typed": typed,
            ])
        case ("POST", "/field/focus"):
            // {"index": 0}。GET /fields の並びの index 番目の入力欄にフォーカスを置き、見える所まで動かす（下の方の欄を撮るため）。
            // {"index": 0, "resign": true} はその欄の窓のフォーカスを外す（フォーカスが外れたときの確定を確かめるため）
            let inputs = Self.textInputs()
            let index = request.jsonBody?["index"] as? Int ?? 0
            guard inputs.indices.contains(index) else { return .json(404, ["error": "その入力欄が無い"]) }
            let input = inputs[index]
            if request.jsonBody?["resign"] as? Bool == true {
                Self.resign(input)
            } else {
                _ = Self.focus(input)
                Self.reveal(input.view)
            }
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["ok": true, "frame": Self.screenFrame(input.view)])
        #if os(macOS)
        case ("POST", "/field/key"):
            // {"index": 0, "key": "return", "modifiers": ["shift"]}。GET /fields の並びの index 番目の欄の窓に、/key と同じキーを直に渡す（窓が前面に無くても first responder に届く）
            let body = request.jsonBody ?? [:]
            let inputs = Self.textInputs()
            let index = body["index"] as? Int ?? 0
            guard inputs.indices.contains(index) else { return .json(404, ["error": "その入力欄が無い"]) }
            guard let key = (body["key"] as? String).flatMap(DebugKey.init) else { return .json(400, ["error": "key が要る（/key と同じ名前）"]) }
            let window = inputs[index].window
            for event in key.events(modifiers: body["modifiers"] as? [String] ?? [], windowNumber: window.windowNumber) { window.sendEvent(event) }
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["ok": true, "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } as Any])
        case ("POST", "/scroll"):
            // {"x": 400, "y": 300, "dy": 600} か {"to": "top"|"bottom"}。主ウィンドウの中の点（左上から、pt）に触れるスクロールを送る（入力欄を除く）。
            // 概況の下の部品を撮るのに使う（iOS の /scroll と同じ用途）
            let body = request.jsonBody ?? [:]
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView else {
                return .json(404, ["error": "窓が無い"])
            }
            let point = NSPoint(x: body["x"] as? Double ?? content.bounds.midX, y: content.bounds.height - (body["y"] as? Double ?? content.bounds.midY))
            var hit = content.hitTest(point)
            while let current = hit, !(current is NSScrollView) || (current as? NSScrollView)?.documentView is NSTextView { hit = current.superview }
            guard let scroll = hit as? NSScrollView, let document = scroll.documentView else { return .json(404, ["error": "スクロールが無い"]) }
            let clip = scroll.contentView
            let maxY = max(0, document.frame.height - clip.bounds.height)
            let current = document.isFlipped ? clip.bounds.origin.y : maxY - clip.bounds.origin.y
            let next: Double =
                switch body["to"] as? String {
                case "top": 0
                case "bottom": maxY
                default: min(maxY, max(0, current + (body["dy"] as? Double ?? 0)))
                }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: document.isFlipped ? next : maxY - next))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(500))
            return .json(200, ["ok": true, "y": next, "contentHeight": document.frame.height])
        #endif
        #if os(iOS)
        case ("POST", "/field/scroll"):
            // {"index": 3, "to": "bottom"} か {"index": 3, "dy": 600}。GET /fields の並びの index 番目（省くと最後）の欄を中に持つスクロールを動かす。
            // Form の一覧は画面に出た行の欄しか作らないので、下の欄を測る前に送る。to も dy も無ければ、その欄が見える所まで送る（画面の外の欄にはフォーカスを置けない）
            let body = request.jsonBody ?? [:]
            let inputs = Self.textInputs()
            let index = body["index"] as? Int ?? inputs.count - 1
            guard inputs.indices.contains(index) else { return .json(404, ["error": "その入力欄が無い"]) }
            var parent = inputs[index].view.superview
            while let current = parent, !(current is UIScrollView) || current is UITextView { parent = current.superview }
            guard let scroll = parent as? UIScrollView else { return .json(404, ["error": "スクロールが無い"]) }
            let bottom = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            if body["to"] == nil, body["dy"] == nil {
                let view = inputs[index].view
                scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll), animated: false)
            } else {
                let y = body["to"] as? String == "bottom" ? bottom : min(bottom, max(-scroll.adjustedContentInset.top, scroll.contentOffset.y + (body["dy"] as? Double ?? 0)))
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
            }
            let y = scroll.contentOffset.y
            try? await Task.sleep(for: .milliseconds(500))
            return .json(200, ["ok": true, "y": y, "contentHeight": scroll.contentSize.height])
        case ("POST", "/scroll"):
            // {"to": "bottom"} か {"to": "top"} か {"dy": 500}（今の位置から送る量）、{"y": 600} で当てる高さ（窓の中の位置。省くと中央）。その位置で触れるスクロール（入力欄を除く）を端まで送る。
            // 一覧の最後の行が浮いたタブバーや下の帯に隠れていないかを撮るのに使う
            let body = request.jsonBody ?? [:]
            guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
                return .json(404, ["error": "窓が無い"])
            }
            let point = CGPoint(x: window.bounds.midX, y: body["y"] as? Double ?? window.bounds.midY)
            var hit = window.hitTest(point, with: nil)
            while let current = hit, !(current is UIScrollView) || current is UITextView { hit = current.superview }
            guard let scroll = hit as? UIScrollView else { return .json(404, ["error": "スクロールが無い"]) }
            let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            let top = -scroll.adjustedContentInset.top
            let y: CGFloat =
                if body["to"] as? String == "top" { top } else if let dy = body["dy"] as? Double { min(bottom, max(top, scroll.contentOffset.y + dy)) } else { bottom }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
            try? await Task.sleep(for: .milliseconds(500))
            return .json(200, ["ok": true, "y": y, "contentHeight": scroll.contentSize.height, "bottomInset": scroll.adjustedContentInset.bottom])
        case ("POST", "/field/return"):
            // {"index": 0}。GET /fields の並びの index 番目の UITextView の末尾で、キーボードの ↩ と同じく delegate に改行を入れてよいかを聞き、よければ入れる。
            // 改行が入ったか・欄の文・submit を呼んだ回数（Mac の欄だけが数える）を返す
            let inputs = Self.textInputs()
            let index = request.jsonBody?["index"] as? Int ?? 0
            guard inputs.indices.contains(index), let textView = inputs[index].view as? UITextView else { return .json(404, ["error": "その UITextView が無い"]) }
            guard Self.focus(inputs[index]) else { return .json(409, ["error": "入力欄にフォーカスを置けない"]) }
            let end = NSRange(location: (textView.text as NSString).length, length: 0)
            textView.selectedRange = end
            let inserts = textView.delegate?.textView?(textView, shouldChangeTextIn: end, replacementText: "\n") ?? true
            if inserts { textView.insertText("\n") }
            try? await Task.sleep(for: .milliseconds(300))
            return .json(200, ["inserted": inserts, "text": textView.text ?? "", "submits": DebugCounters.textSubmits])
        #endif
        case ("GET", "/lab/field"):
            // 測りの欄で呼ばれた確定・取り消し・送信の記録（古い順）と、欄の文
            return .json(200, ["events": LabField.events, "text": LabField.text])
        case ("POST", "/lab/field"):
            // {"kind": "title" | "memo" | "link" | "comment" | "reply" | "blocker", "width": 400}。fixtures では書き込めず開けない欄（その場の編集・コメント・返信・待ち理由）を、
            // その部品のまま載せた窓を開く（Mac は後ろに、iPhone と iPad は画面の上に重ねる。返信は一覧の中の private な関数なので、同じ指定の欄 `LabField.reply`）。{"close": true} で閉じる
            let body = request.jsonBody ?? [:]
            Self.closeLabWindow()
            LabField.events = []
            if body["close"] as? Bool == true { return .json(200, ["ok": true]) }
            guard let kind = LabField.Kind(rawValue: body["kind"] as? String ?? "") else { return .json(400, ["error": "kind は title / memo / link / comment / reply / blocker"]) }
            let item = model.fleet.machines.values.lazy.flatMap(\.workItems.values).first
            guard kind != .blocker || item != nil else { return .json(404, ["error": "fixtures に作業項目が無い"]) }
            guard let window = Self.openLabWindow(LabField(kind: kind, item: item).modifier(WindowRoot(model: model)), width: body["width"] as? Double ?? 400) else {
                return .json(409, ["error": "窓を開く scene が無い"])
            }
            try? await Task.sleep(for: .milliseconds(500))
            return .json(200, ["ok": true, "fields": Self.textInputs().filter { $0.window === window }.count])
        default:
            return nil
        }
    }

    /// 文を入れる先。全部の入れ替えと末尾への 1 字の足しを、打鍵・貼り付けと同じ経路（insertText）で行う
    struct FieldEditor {
        let replaceAll: (String) -> Void
        let append: (String) -> Void
    }

    static let labWindowTitle = "測りの欄"

    #if os(macOS)
    @MainActor static var labWindow: NSWindow?

    static func openLabWindow(_ content: some View, width: Double) -> NSWindow? {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = labWindowTitle
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.orderBack(nil)
        labWindow = window
        return window
    }

    static func closeLabWindow() {
        labWindow?.close()
        labWindow = nil
    }

    static func windowTitle(_ window: NSWindow) -> String { window.title }

    static func focus(_ input: (view: NSView, window: NSWindow)) -> Bool { input.window.makeFirstResponder(input.view) }

    static func isFocused(_ input: (view: NSView, window: NSWindow)) -> Bool { input.window.firstResponder === input.view }

    static func resign(_ input: (view: NSView, window: NSWindow)) { input.window.makeFirstResponder(nil) }

    static func reveal(_ view: NSView) { view.scrollToVisible(view.bounds) }

    /// 見えている窓の、編集できる入力欄（field editor と、`MultilineTextField` の枠に敷いた欄は除く）
    static func textInputs() -> [(view: NSView, window: NSWindow)] {
        func find(_ view: NSView) -> [NSView] {
            let own: [NSView]
            if let field = view as? NSTextField, field.isEditable, !(field.superview is MultilineScrollView) {
                own = [field]
            } else if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor {
                own = [text]
            } else {
                own = []
            }
            return own + view.subviews.flatMap(find)
        }
        return NSApp.windows.filter(\.isVisible).flatMap { window in (window.contentView.map(find) ?? []).map { ($0, window) } }
    }

    /// 入力欄の名前。読み上げの名前、無ければプレースホルダー（SwiftUI の TextField は NSTextField に名前を載せないので、空のことが多い）
    static func fieldName(_ view: NSView) -> String {
        let placeholder = (view as? NSTextField)?.placeholderString ?? view.accessibilityPlaceholderValue()
        return [view.accessibilityLabel(), placeholder].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    static func fieldText(_ view: NSView) -> String {
        (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? ""
    }

    /// 文を入れる先。NSTextField はフォーカスを置いた後の field editor
    static func editor(of view: NSView) -> FieldEditor? {
        guard let editor = (view as? NSTextView) ?? ((view as? NSTextField)?.currentEditor() as? NSTextView) else { return nil }
        return FieldEditor(
            replaceAll: { editor.insertText($0, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)) },
            append: { editor.insertText($0, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0)) })
    }

    static func screenFrame(_ view: NSView) -> [String: Double] {
        let view = (view as? NSTextView)?.enclosingScrollView ?? view
        guard let window = view.window else { return [:] }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return ["x": frame.minX, "y": top - frame.maxY, "width": frame.width, "height": frame.height]
    }

    #else
    @MainActor static var labWindow: UIWindow?

    /// 測りの欄は、前にある scene に重ねた窓（閉じるまで画面の上を覆う）。幅は画面の幅に合わせ、`width` は使わない
    static func openLabWindow(_ content: some View, width: Double) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.accessibilityIdentifier = labWindowTitle
        window.windowLevel = .normal + 1
        window.isHidden = false
        labWindow = window
        return window
    }

    static func closeLabWindow() {
        labWindow?.isHidden = true
        labWindow = nil
    }

    static func windowTitle(_ window: UIWindow) -> String { window.accessibilityIdentifier ?? "" }

    static func focus(_ input: (view: UIView, window: UIWindow)) -> Bool { input.view.isFirstResponder || input.view.becomeFirstResponder() }

    static func isFocused(_ input: (view: UIView, window: UIWindow)) -> Bool { input.view.isFirstResponder }

    static func resign(_ input: (view: UIView, window: UIWindow)) { input.view.resignFirstResponder() }

    /// 欄を外のスクロールの中で見える所まで動かす（UITextView は自分もスクロールなので、親から探す）
    static func reveal(_ view: UIView) {
        var parent = view.superview
        while let current = parent, !(current is UIScrollView) { parent = current.superview }
        guard let scroll = parent as? UIScrollView else { return }
        scroll.scrollRectToVisible(view.convert(view.bounds, to: scroll), animated: false)
    }

    /// 見えている窓の、編集できる入力欄（UITextField・UITextView）
    static func textInputs() -> [(view: UIView, window: UIWindow)] {
        func find(_ view: UIView) -> [UIView] {
            let own: [UIView]
            if let field = view as? UITextField, field.isEnabled, !field.isHidden {
                own = [field]
            } else if let text = view as? UITextView, text.isEditable, !text.isHidden {
                own = [text]
            } else {
                own = []
            }
            return own + view.subviews.flatMap(find)
        }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).filter { !$0.isHidden }
        return windows.flatMap { window in find(window).map { ($0, window) } }
    }

    /// 入力欄の名前。読み上げの名前、無ければプレースホルダー
    static func fieldName(_ view: UIView) -> String {
        [view.accessibilityLabel, (view as? UITextField)?.placeholder].compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    static func fieldText(_ view: UIView) -> String {
        (view as? UITextField)?.text ?? (view as? UITextView)?.text ?? ""
    }

    /// 文を入れる先。全部（または末尾）を選んでから UITextInput の insertText で入れる（打鍵と同じく、欄の delegate と SwiftUI の Binding を通る）
    static func editor(of view: UIView) -> FieldEditor? {
        guard let input = view as? (UIView & UITextInput) else { return nil }
        return FieldEditor(
            replaceAll: { text in
                input.selectedTextRange = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument)
                input.insertText(text)
            },
            append: { text in
                input.selectedTextRange = input.textRange(from: input.endOfDocument, to: input.endOfDocument)
                input.insertText(text)
            })
    }

    static func screenFrame(_ view: UIView) -> [String: Double] {
        let frame = view.convert(view.bounds, to: nil)
        return ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
    }
    #endif
}

/// 測り用の窓の中身。欄の部品をそのまま、書いた文の持ち主（@State）と一緒に置く。確定・取り消し・送信は `events` に残す
private struct LabField: View {
    enum Kind: String { case title, memo, link, comment, reply, blocker }
    @MainActor static var events: [String] = []
    @MainActor static var text = ""
    let kind: Kind
    let item: WorkItem?
    @State private var text = ""
    @State private var composer = DocumentScreen.Composer()

    var body: some View {
        VStack(alignment: .leading) {
            switch kind {
            case .title:
                InlineField(label: String(localized: "タイトル"), text: $text, font: .title, lines: 1...3, commit: { Self.events.append("commit") }, cancel: { Self.events.append("cancel") })
            case .memo:
                InlineField(label: String(localized: "メモ"), text: $text, lines: 3...20, commit: { Self.events.append("commit") }, cancel: { Self.events.append("cancel") })
            case .link:
                InlineField(
                    label: String(localized: "リンクのURL"), text: $text, font: .callout, lines: 1...1, prompt: "https://", commit: { Self.events.append("commit") },
                    cancel: { Self.events.append("cancel") })
            case .comment:
                CommentComposer(composer: $composer, submit: { _ in Self.events.append("submit") }, cancel: { Self.events.append("cancel") })
            case .reply:
                // `CommentsSection` の返信の欄と同じ指定
                MultilineTextField(label: String(localized: "返信"), placeholder: String(localized: "返信"), text: $text, lines: 1...4, font: .callout, style: .roundedBorder)
            case .blocker:
                if let item { BlockerEditor(item: item, save: { _, _ in Self.events.append("save") }, cancel: { Self.events.append("cancel") }) }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.card)
        .onChange(of: text) { _, text in Self.text = text }
        .onChange(of: composer.text) { _, text in Self.text = text }
    }
}
#endif
