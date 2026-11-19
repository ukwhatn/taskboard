#if DEBUG
import Foundation
import QuartzCore
import SwiftUI
import TaskboardKit

extension DebugServer {
    /// チャットの入力とスクロールの計測（本物のキーとマウスは使わない）
    func respondChatPerf(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/conversation/type"):
            // {"text": "あいう…", "gapMs": 80, "caret": false, "noop": false, "keep": false}。開いている会話の入力欄の文を 1 字ずつ伸ばす（caret なら文を全部入れてから、カーソルを 1 字ずつ左へ動かす）。
            // 打鍵ごとの主スレッドの使用時間（次の打鍵まで）・画面の更新間隔・body の回数を返す。noop は入力欄を変えずに同じ間隔で回す（測る口自身の負荷）。
            // keep なら終わった後に入力欄を空にしない（書きかけが残るかを /conversation/draft で確かめる）
            guard model.activeConversation != nil else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            let text = Array(body["text"] as? String ?? String(repeating: "入力の重さを測るための文です。", count: 4))
            let gap = Duration.milliseconds(body["gapMs"] as? Int ?? 80)
            let caret = body["caret"] as? Bool ?? false
            let noop = body["noop"] as? Bool ?? false
            let keep = body["keep"] as? Bool ?? false
            var seq = (model.debugComposerInput?.seq ?? 0) + 1
            if caret {
                model.debugComposerInput = DebugComposerInput(seq: seq, text: String(text), cursor: text.count)
                try? await Task.sleep(for: .milliseconds(500))
            }
            DebugCounters.reset()
            MainThreadBusy.shared.start()
            FrameMonitor.shared.start()
            var marks: [CFTimeInterval] = []
            for index in text.indices {
                marks.append(CACurrentMediaTime())
                seq += 1
                if !noop {
                    model.debugComposerInput =
                        caret
                        ? DebugComposerInput(seq: seq, text: String(text), cursor: text.count - index - 1)
                        : DebugComposerInput(seq: seq, text: String(text[...index]), cursor: index + 1)
                }
                try? await Task.sleep(for: gap)
            }
            marks.append(CACurrentMediaTime())
            let spans = MainThreadBusy.shared.stop()
            let frames = FrameMonitor.shared.stop()
            let counters = DebugCounters.snapshot()
            if !keep { model.debugComposerInput = DebugComposerInput(seq: seq + 1, text: "", cursor: 0) }
            return .json(200, [
                "keys": text.count, "busy": MainThreadBusy.perWindow(spans, marks: marks), "frames": frames,
                "bodiesPerKey": counters.mapValues { (Double($0) / Double(max(1, text.count)) * 10).rounded() / 10 },
            ])
        case ("POST", "/conversation/fill"):
            // {"text": "…", "settleMs": 3000, "then": "あいう", "gapMs": 80, "insert": false, "keep": false}。開いている会話の入力欄に text を一度に入れ（貼り付けと同じく文の全部が一度に変わる）、
            // settleMs の間の主スレッドの使用時間を返す。続けて then を文の末尾に 1 字ずつ足し、打鍵ごとの使用時間を返す。
            // insert なら Mac の入力欄（MultilineNSTextView）の insertText で入れる（打鍵と貼り付けと同じ経路。無い版では Binding に入れる）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            let body = request.jsonBody ?? [:]
            guard let text = body["text"] as? String, !text.isEmpty else { return .json(400, ["error": "text が要る"]) }
            let settle = Duration.milliseconds(body["settleMs"] as? Int ?? 3000)
            let then = Array(body["then"] as? String ?? "")
            let gap = Duration.milliseconds(body["gapMs"] as? Int ?? 80)
            let keep = body["keep"] as? Bool ?? false
            let insert = body["insert"] as? Bool ?? false
            var seq = (model.debugComposerInput?.seq ?? 0) + 1
            #if os(macOS)
            let textView = insert ? Self.composerTextView() : nil
            #endif
            /// 入力欄に文を入れる。insert なら今の文の末尾に insertText で足し、そうでなければ文の全部を `whole` にする
            func put(_ added: String, whole: String) {
                #if os(macOS)
                if let textView {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                    textView.insertText(added, replacementRange: textView.selectedRange())
                    return
                }
                #endif
                seq += 1
                model.debugComposerInput = DebugComposerInput(seq: seq, text: whole, cursor: whole.count)
            }
            MainThreadBusy.shared.start()
            let started = CACurrentMediaTime()
            put(text, whole: text)
            try? await Task.sleep(for: settle)
            let fill = MainThreadBusy.shared.stop()
            let fillWall = (CACurrentMediaTime() - started) * 1000
            var typed: [String: Any] = [:]
            if !then.isEmpty {
                DebugCounters.reset()
                MainThreadBusy.shared.start()
                var marks: [CFTimeInterval] = []
                for index in then.indices {
                    marks.append(CACurrentMediaTime())
                    put(String(then[index]), whole: text + String(then[...index]))
                    try? await Task.sleep(for: gap)
                }
                marks.append(CACurrentMediaTime())
                typed = MainThreadBusy.perWindow(MainThreadBusy.shared.stop(), marks: marks)
                typed["bodiesPerKey"] = DebugCounters.snapshot().mapValues { (Double($0) / Double(then.count) * 10).rounded() / 10 }
            }
            if !keep { model.debugComposerInput = DebugComposerInput(seq: seq + 1, text: "", cursor: 0) }
            return .json(200, [
                "chars": text.count, "fill": MainThreadBusy.summary(fill), "fillWallMs": (fillWall * 10).rounded() / 10, "typed": typed,
                "draftChars": model.chatDrafts.text(for: feed.key).count,
            ])
        case ("POST", "/conversation/dictation"):
            // {"down": true} で開いている会話の入力欄の［音声入力］を押し、{"down": false} で離す（ボタンと ⌥Space と同じ経路）。返りは今の段階
            guard model.activeConversation != nil else { return .json(404, ["error": "会話を開いていない"]) }
            let down = request.jsonBody?["down"] as? Bool ?? true
            model.debugDictationPress = DebugDictationPress(seq: (model.debugDictationPress?.seq ?? 0) + 1, down: down)
            try? await Task.sleep(for: .milliseconds(100))
            return .json(200, ["ok": true, "phase": model.debugDictationPhase])
        case ("GET", "/conversation/dictation"):
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            return .json(200, ["phase": model.debugDictationPhase, "draft": model.chatDrafts.text(for: feed.key)])
        case ("GET", "/conversation/draft"):
            // 開いている会話の書きかけ（ChatDraftTexts。入力欄が作り直されたらここから読む）
            guard let feed = model.activeConversation else { return .json(404, ["error": "会話を開いていない"]) }
            return .json(200, ["text": model.chatDrafts.text(for: feed.key)])
        case ("GET", "/conversation/composer"), ("POST", "/conversation/composer"):
            // Mac のチャットと会話の入力欄（名前が「メッセージ」の MultilineNSTextView）の今：文・選択（UTF-16）・変換中か・窓の first responder か・欄の高さ・送信を呼んだ回数。
            // POST {"mark": "にほんご"} は変換中の文を置き（setMarkedText）、{"unmark": true} は確定する（本物の入力メソッドは使わない）。
            // {"key": "return", "modifiers": ["shift"]} は入力欄の窓にキーを渡す（/key と同じ出来事を、アプリが前面に無くても窓の first responder に届ける）。
            // {"focus": true} は入力欄を first responder にし、{"replace": "文"} は全部を選んで打鍵と同じ経路（insertText）で入れ替える（"" なら空にする）
            #if os(macOS)
            guard let textView = Self.composerTextView() else { return .json(404, ["error": "入力欄が無い"]) }
            var filesFailure: String?
            if request.method == "POST" {
                let body = request.jsonBody ?? [:]
                if let marked = body["mark"] as? String {
                    textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0), replacementRange: textView.selectedRange())
                }
                if body["unmark"] as? Bool == true { textView.unmarkText() }
                if body["focus"] as? Bool == true { textView.window?.makeFirstResponder(textView) }
                if let replacement = body["replace"] as? String {
                    textView.insertText(replacement, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
                }
                // {"paste": "文"} は ⌘V の貼り付けと同じ経路（長ければ添付、短ければ入力欄）で入れる。本物のクリップボードは使わない
                if let pasted = body["paste"] as? String, (textView as? MultilineNSTextView)?.takesLongPaste(pasted) != true {
                    textView.insertText(pasted, replacementRange: textView.selectedRange())
                }
                // {"addFiles": ["/パス", …]} はドロップと ⌘V のファイルと同じ経路（`AppModel.addChatFiles`）で下書きに足す。失敗は "failure" に返す
                if let paths = body["addFiles"] as? [String], let feed = model.activeConversation {
                    let problem = await model.addChatFiles(paths.map { URL(fileURLWithPath: $0) }, for: feed.key)
                    filesFailure = problem?.text
                }
                if let name = body["key"] as? String {
                    guard let key = DebugKey(name), let window = textView.window else { return .json(400, ["error": "key が要る（/key と同じ名前）"]) }
                    for event in key.events(modifiers: body["modifiers"] as? [String] ?? [], windowNumber: window.windowNumber) { window.sendEvent(event) }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            let selected = textView.selectedRange()
            let drafted = model.activeConversation.map { model.chatFiles(for: $0.key) } ?? []
            return .json(200, [
                "files": drafted.map { ["title": $0.title, "name": $0.name, "folder": $0.isFolder] as [String: Any] }, "filesFailure": filesFailure ?? "",
                "text": textView.string, "selection": [selected.location, selected.length], "marked": textView.hasMarkedText(),
                "firstResponder": textView.window?.firstResponder === textView, "height": textView.enclosingScrollView?.frame.height ?? -1,
                "documentHeight": textView.frame.height, "submits": DebugCounters.textSubmits,
            ])
            #else
            return .json(404, ["error": "macOS だけ"])
            #endif
        case ("POST", "/conversation/scroll"):
            // {"dy": 20, "steps": 120, "intervalMs": 16, "back": true, "untilEdge": false, "trackpad": false, "settleMs": 0}。主ウィンドウのチャットの所に、ピクセル単位のホイールを
            // アプリの中で作って 1 フレームごとに渡し、steps 回上へ送ってから同じだけ戻す（back が false なら上へ送るだけ。dy が負なら下へ）。本物のホイールと同じく NSScrollView を通る。
            // untilEdge なら、位置が 8 回続けて動かなくなったら（端に着いたら）その向きを終える。trackpad なら phase の無いホイールの代わりに、トラックパッドの 1 回のなで
            // （began・changed を steps 回・ended と、続く momentum を 12 回）を送る。settleMs は送り終えてから待って位置を読み直す（下端へ引き戻されないか）。
            // 画面の更新間隔・主スレッドの使用時間・作った行の数（TranscriptRow の body）と、送る前・向きを変える所・後・待った後の位置（offset と下端までの gap）を返す
            #if os(macOS)
            let body = request.jsonBody ?? [:]
            let dy = body["dy"] as? Double ?? 20
            let steps = body["steps"] as? Int ?? 120
            let interval = Duration.milliseconds(body["intervalMs"] as? Int ?? 16)
            let back = body["back"] as? Bool ?? true
            let untilEdge = body["untilEdge"] as? Bool ?? false
            let trackpad = body["trackpad"] as? Bool ?? false
            let settle = body["settleMs"] as? Int ?? 0
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let content = window.contentView else {
                return .json(404, ["error": "窓が無い"])
            }
            // 会話の列は窓の中で中身が一番高い NSScrollView。その真ん中（窓の左下が原点）に渡す
            let scrollView = Self.allScrollViews(in: content).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
            let frame = scrollView.map { $0.convert($0.bounds, to: nil) } ?? content.convert(content.bounds, to: nil)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            func position() -> [String: Double] {
                guard let scrollView else { return [:] }
                let offset = scrollView.documentVisibleRect.origin.y
                let gap = (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height - offset
                return ["offset": offset, "gap": gap, "viewport": scrollView.contentView.bounds.height, "insetTop": scrollView.contentInsets.top, "insetBottom": scrollView.contentInsets.bottom]
            }
            func wheel(_ delta: Double, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) {
                guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return }
                // 窓の無い NSEvent の locationInWindow は、CGEvent の位置を左下が原点の座標にしたもの（/wheel と同じ）
                cgEvent.location = CGPoint(x: point.x, y: top - point.y)
                cgEvent.timestamp = CGEventTimestamp(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
                if phase != nil || momentum != .none {
                    cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
                    cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
                }
                guard let event = NSEvent(cgEvent: cgEvent) else { return }
                // CGEvent から作った NSEvent には窓が付かず、窓に渡すと行の NSHostingView が受けて捨て、一覧が動かなかった（D3・D4 の測りが動かない一覧を測っていた）。
                // 一覧の NSScrollView に直に渡す（本物のホイールも、行が受けなかった分は responder chain でここに着く）。local monitor に見せるため列にも入れる
                NSApp.postEvent(event, atStart: false)
                if let scrollView { scrollView.scrollWheel(with: event) } else { window.sendEvent(event) }
            }
            /// 1 つの向きに steps 回送る。untilEdge なら端に着いたところで止める
            func leg(_ delta: Double) async {
                var still = 0
                if trackpad {
                    wheel(0, phase: .began)
                    try? await Task.sleep(for: interval)
                }
                for _ in 0..<steps {
                    let before = scrollView?.documentVisibleRect.origin.y
                    wheel(delta, phase: trackpad ? .changed : nil)
                    try? await Task.sleep(for: interval)
                    still = scrollView?.documentVisibleRect.origin.y == before ? still + 1 : 0
                    if untilEdge, still >= 8 { break }
                }
                guard trackpad else { return }
                wheel(0, phase: .ended)
                // 指を離した後の惰性。だんだん小さくする
                for index in 0..<12 {
                    wheel(delta * Double(12 - index) / 12, momentum: index == 0 ? .begin : .continuous)
                    try? await Task.sleep(for: interval)
                }
                wheel(0, momentum: .end)
                try? await Task.sleep(for: interval)
            }
            /// 送る点の下の view と、それを包む NSScrollView が一覧か（行の中のコードの塊などの NSScrollView が受けていないか）
            func hit() -> [String: Any] {
                let view = content.hitTest(content.convert(point, from: nil))
                return ["view": view.map { String(describing: type(of: $0)) } ?? "nil", "inList": view?.enclosingScrollView === scrollView]
            }
            let hitBefore = hit()
            let before = position()
            DebugCounters.reset()
            MainThreadBusy.shared.start()
            FrameMonitor.shared.start()
            await leg(dy)
            let turned = position()
            if back { await leg(-dy) }
            let spans = MainThreadBusy.shared.stop()
            let frames = FrameMonitor.shared.stop()
            let after = position()
            if settle > 0 { try? await Task.sleep(for: .milliseconds(settle)) }
            return .json(200, [
                "frames": frames, "busy": MainThreadBusy.summary(spans), "bodies": DebugCounters.snapshot(),
                "offset": ["before": before["offset"] ?? -1, "top": turned["offset"] ?? -1, "after": after["offset"] ?? -1],
                "position": ["before": before, "turned": turned, "after": after, "settled": position()],
                "hit": ["before": hitBefore, "after": hit()],
                "foundScrollView": scrollView != nil, "scrollViews": Self.scrollViews(in: content),
            ])
            #else
            // iPhone・iPad: {"dy": 40, "steps": 60, "intervalMs": 32, "settleMs": 0}。一覧の UIScrollView の位置を 1 回ごとに dy だけ上へずらし（負なら下へ）、人がなでたことにする（delegate の始めと終わりを送る）。
            // 前後で両方に見えていた行の動きから送った量を引いた分を、行の高さが直ったときのずれ（jump）として数える
            let body = request.jsonBody ?? [:]
            let dy = body["dy"] as? Double ?? 40
            let steps = body["steps"] as? Int ?? 60
            let interval = Duration.milliseconds(body["intervalMs"] as? Int ?? 32)
            let settle = body["settleMs"] as? Int ?? 0
            guard let scrollView = Self.chatScrollView() else { return .json(404, ["error": "一覧が無い"]) }
            func position() -> [String: Double] {
                let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                return ["offset": offset, "contentHeight": scrollView.contentSize.height, "gap": scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height - scrollView.contentOffset.y]
            }
            let before = position()
            var jumps: [Double] = []
            var moved: [Double] = []
            // 指でなでたのと同じに、delegate に始めと終わりを知らせる（知らせないと SwiftUI は人が送った位置と見なさず、ScrollPosition が下端を指したまま残る）
            DebugCounters.reset()
            MainThreadBusy.shared.start()
            FrameMonitor.shared.start()
            scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
            for _ in 0..<steps {
                let rows = DebugRowFrames.minY
                let start = scrollView.contentOffset.y
                // 上端に着いたら終える（送った量だけ動かなくなる）
                let top = -scrollView.adjustedContentInset.top
                guard dy < 0 || start > top + 0.5 else { break }
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: max(start - dy, dy < 0 ? -.infinity : top)), animated: false)
                try? await Task.sleep(for: interval)
                let shifts = rows.compactMap { id, old in DebugRowFrames.minY[id].map { $0 - old } }
                guard !shifts.isEmpty else { continue }
                let asked = dy < 0 ? dy : min(dy, start - top)
                moved.append(start - scrollView.contentOffset.y)
                // 見えている行のずれの中央。一番動いた行だけを見ると、開いた行の中身の伸びを拾う
                jumps.append(shifts.sorted()[shifts.count / 2] - asked)
            }
            var target = scrollView.contentOffset
            scrollView.delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
            scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
            let busy = MainThreadBusy.summary(MainThreadBusy.shared.stop())
            let frames = FrameMonitor.shared.stop()
            if settle > 0 { try? await Task.sleep(for: .milliseconds(settle)) }
            let large = jumps.filter { abs($0) > 1 }
            return .json(200, [
                "steps": jumps.count, "jumpSteps": large.count, "maxJump": jumps.map(abs).max() ?? 0, "totalJump": large.reduce(0) { $0 + abs($1) },
                "position": ["before": before, "after": position()], "movedTotal": moved.reduce(0, +),
                "busy": busy, "frames": frames, "bodies": DebugCounters.snapshot(),
            ])
            #endif
        case ("POST", "/conversation/press"):
            // iPhone・iPad: {"label": "思考", "index": 0}。一覧の中で読み上げの名前に label を含む押せる部品の index 番目を、VoiceOver と同じ口で押す
            // （シミュレータに触れる操作を送れないので、開閉した行を撮るため）。見つからなければ見えている部品の名前を返す
            #if os(iOS)
            guard let scrollView = Self.chatScrollView() else { return .json(404, ["error": "一覧が無い"]) }
            func all(_ view: UIView) -> [ChatPressableView] { ((view as? ChatPressableView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
            let buttons = all(scrollView).sorted { $0.convert($0.bounds, to: scrollView).minY < $1.convert($1.bounds, to: scrollView).minY }
            let label = request.jsonBody?["label"] as? String ?? ""
            let matched = buttons.filter { $0.accessibilityLabel?.contains(label) == true }
            let index = request.jsonBody?["index"] as? Int ?? 0
            guard matched.indices.contains(index) else { return .json(404, ["labels": buttons.compactMap(\.accessibilityLabel)]) }
            return .json(200, ["pressed": matched[index].accessibilityActivate()])
            #else
            return .json(404, ["error": "iPhone・iPad だけ"])
            #endif
        case ("GET", "/conversation/rows"):
            // iPhone・iPad: 一覧に今ある行の上端（見えている所の上端から）と、一覧の位置。/bench/older の前後で比べ、見ていた行が動かないかを見る
            #if os(iOS)
            guard let scrollView = Self.chatScrollView() else { return .json(404, ["error": "一覧が無い"]) }
            return .json(200, [
                "rows": DebugRowFrames.minY.mapValues(Double.init), "offset": scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
                "contentHeight": scrollView.contentSize.height,
            ])
            #else
            return .json(404, ["error": "iPhone・iPad だけ"])
            #endif
        default:
            return nil
        }
    }

    #if os(iOS)
    /// 窓の中で中身が一番高い UIScrollView（会話の一覧）
    static func chatScrollView() -> UIScrollView? {
        func all(_ view: UIView) -> [UIScrollView] { ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all) }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.flatMap(all).filter { !($0 is UITextView) }.max { $0.contentSize.height < $1.contentSize.height }
    }
    #endif

    #if os(macOS)
    /// 見えている窓のうち、最初に見つかったチャットか会話の入力欄（名前が「メッセージ」の MultilineNSTextView）
    static func composerTextView() -> MultilineNSTextView? {
        func find(_ view: NSView) -> MultilineNSTextView? {
            if let text = view as? MultilineNSTextView, text.accessibilityLabel() == String(localized: "メッセージ") { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView.flatMap(find) }.first
    }

    static func allScrollViews(in view: NSView) -> [NSScrollView] { all(NSScrollView.self, in: view) }

    /// `view` とその中の `type` の view（深さ優先）
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// 窓の中の NSScrollView（窓の座標の枠・中身の高さ・見えている所の上端）
    static func scrollViews(in view: NSView) -> [[String: Double]] {
        allScrollViews(in: view).map { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return [
                "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height,
                "documentHeight": Double(scroll.documentView?.frame.height ?? -1), "visibleY": scroll.documentVisibleRect.origin.y,
            ]
        }
    }
    #endif
}

#if os(iOS)
/// 計測用: iPhone・iPad の一覧に今ある行の上端（一覧の見えている所から）。行の id ごと
@MainActor
enum DebugRowFrames {
    static var minY: [String: CGFloat] = [:]
}

#endif

/// 計測用: 会話の入力欄に入れる文とカーソル（DebugServer の /conversation/type が 1 字ずつ変える）
struct DebugComposerInput: Equatable {
    var seq: Int
    var text: String
    /// カーソルの位置（文字の数）
    var cursor: Int
}

/// 確認用: 会話の入力欄の［音声入力］の押し下げ（true）と離し（false）
struct DebugDictationPress: Equatable {
    var seq: Int
    var down: Bool
}

/// 会話の入力欄に付け、/conversation/dictation の押し下げと離しを渡し、音声入力の段階を書き戻す
struct DebugDictationFeed: ViewModifier {
    @Environment(AppModel.self) private var model: AppModel?
    let phase: VoiceDictation.Phase
    let press: () -> Void
    let release: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: model?.debugDictationPress) { _, value in
                guard let value else { return }
                if value.down { press() } else { release() }
            }
            .onChange(of: phase, initial: true) { _, phase in model?.debugDictationPhase = "\(phase)" }
    }
}

/// 入力欄の文とカーソルの持ち主に付け、/conversation/type の文を打鍵と同じに入れる。値を読むのはこの modifier だけにする（持ち主の body を計測で走らせない）
struct DebugComposerFeed: ViewModifier {
    @Environment(AppModel.self) private var model: AppModel?
    @Binding var draft: String
    @Binding var selection: TextSelection?

    func body(content: Content) -> some View {
        content.onChange(of: model?.debugComposerInput) { _, input in
            guard let input else { return }
            draft = input.text
            selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: min(input.cursor, draft.count)))
        }
    }
}

/// 計測用: view の body が走った回数
@MainActor
enum DebugCounters {
    /// 複数行の入力欄（MultilineTextField）が ↩ で submit を呼んだ回数。fixtures は書き込めず送信が何も残さないので、↩ で送ろうとしたかをこれで見る
    static var textSubmits = 0
    private static var counts: [String: Int] = [:]
    private static var active = false

    static func hit(_ name: String) {
        guard active else { return }
        counts[name, default: 0] += 1
    }

    static func reset() {
        counts = [:]
        active = true
    }

    static func snapshot() -> [String: Int] {
        active = false
        return counts
    }
}

/// 計測用: 主スレッドの run loop が起きてから寝るまでの区間（主スレッドが働いていた時間）。display link が止まる後ろの窓でも測れる
@MainActor
final class MainThreadBusy {
    static let shared = MainThreadBusy()
    private var spans: [(start: CFTimeInterval, end: CFTimeInterval)] = []
    private var wokeAt: CFTimeInterval?
    private var observers: [CFRunLoopObserver] = []

    func start() {
        stopObserving()
        spans = []
        wokeAt = CACurrentMediaTime()
        // 起きた印は一番先に、寝る印は一番後に（SwiftUI と Core Animation の更新が済んでから）呼ぶ
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { _, _ in
            MainActor.assumeIsolated { MainThreadBusy.shared.wokeAt = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                let busy = MainThreadBusy.shared
                guard let woke = busy.wokeAt else { return }
                busy.spans.append((woke, CACurrentMediaTime()))
                busy.wokeAt = nil
            }
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func stop() -> [(start: CFTimeInterval, end: CFTimeInterval)] {
        stopObserving()
        if let wokeAt { spans.append((wokeAt, CACurrentMediaTime())) }
        wokeAt = nil
        return spans
    }

    private func stopObserving() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// 全体の使用時間と、1 回の区間の長さの p50・p95・最大（ms）
    static func summary(_ spans: [(start: CFTimeInterval, end: CFTimeInterval)]) -> [String: Any] {
        let lengths = spans.map { ($0.end - $0.start) * 1000 }.sorted()
        guard let first = spans.first, let last = spans.last, !lengths.isEmpty else { return ["spans": 0] }
        func percentile(_ p: Double) -> Double { lengths[min(lengths.count - 1, Int(Double(lengths.count) * p))] }
        let total = lengths.reduce(0, +)
        return [
            "spans": lengths.count, "busyMs": rounded(total), "durationMs": rounded((last.end - first.start) * 1000),
            "spanP50Ms": rounded(percentile(0.5)), "spanP95Ms": rounded(percentile(0.95)), "spanMaxMs": rounded(lengths.last ?? 0),
        ]
    }

    /// 打鍵ごと（`marks` の隣り合う 2 つの間）の使用時間の p50・p95・最大と、全体の要約（ms）
    static func perWindow(_ spans: [(start: CFTimeInterval, end: CFTimeInterval)], marks: [CFTimeInterval]) -> [String: Any] {
        var windows: [Double] = []
        for (from, to) in zip(marks, marks.dropFirst()) {
            let busy = spans.reduce(0.0) { sum, span in sum + max(0, min(span.end, to) - max(span.start, from)) }
            windows.append(busy * 1000)
        }
        let sorted = windows.sorted()
        guard !sorted.isEmpty else { return ["keys": 0] }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return [
            "perKeyP50Ms": rounded(percentile(0.5)), "perKeyP95Ms": rounded(percentile(0.95)), "perKeyMaxMs": rounded(sorted.last ?? 0),
            "overall": summary(spans),
        ]
    }
}
#endif
