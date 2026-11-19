import Markdown
import SwiftUI
import TaskboardKit
import WebKit

/// 文書本文の描画。markdown は swift-markdown で HTML にしてから、html はそのまま WKWebView に載せる。
/// 外部リソースは content rule list で全部止める。止める規則を用意できなければ本文を載せない。
/// 利用者が文書ごとに許したときだけ（`DocumentRemoteContent`）、規則を外して描く。
/// 押したリンクだけをブラウザへ渡し、文書の script・meta refresh・iframe による遷移は止める（文書の script は動く。kairan と同じ割り切り）。
@MainActor
@Observable
final class DocumentWebController: NSObject {
    let webView: WKWebView
    /// 文書内で文字が選ばれている（「選択範囲にコメント」を出せる）
    private(set) var hasSelection = false
    /// 選んだ所の枠（web view の座標）。スクロールすると付いて動くので、読むのは浮かせる［コメント］だけにする（上の帯は `hasSelection`）
    private(set) var selectionRect: CGRect? {
        didSet {
            if hasSelection != (selectionRect != nil) { hasSelection = selectionRect != nil }
        }
    }
    private(set) var ready = false
    /// 読み込んだ本文の高さ（概況の自由の部品が、中身に合わせて欄の高さを決める）
    private(set) var contentHeight: CGFloat = 0
    /// 外部の読み込みを止める規則を用意できなかった。本文は載せない
    private(set) var failure: UserFacingError?
    private var pending: (html: String, highlights: [HighlightItem], allowsRemote: Bool)?
    private var blockList: WKContentRuleList?
    /// 今載せている本文に、外部の読み込みを止める規則を付けているか
    private(set) var blocksRemote = true
    private var highlights: [HighlightItem] = []
    private var activeID: Int64?

    struct HighlightItem: Hashable {
        var id: Int64
        var anchor: CommentAnchor
    }

    /// 本文の中の質問と送る文面の欄の中身（`DocumentForms.Payload` の JSON）。読み込み直したら入れ直す
    private var formsJSON: String?
    /// 送る先の欄。頁と欄を描き終える前に頼まれたら、欄を入れた後に送る
    private var pendingFormScroll: String?
    /// 欄に選んだ選択肢か書いた文がある（Esc で文書を閉じて消さない）
    private(set) var formsPendingInput = false
    /// 欄で答えた・承認した・閉じた（`DocumentScreen` が daemon に送る）
    var onFormAction: (@MainActor (DocumentFormAction) -> Void)?

    /// 文書の中の `taskboard://` を押したときの開き先（`AppModel.open(_:)`）。チャットと PR の本文と同じくアプリの中で開く
    var openInApp: (@MainActor (URL) -> Void)?

    /// 最後に作られた文書ビュー（DebugServer の `/doc/text` `/doc/screenshot` が読む）
    static weak var current: DocumentWebController?

    /// `tracksCurrent` が false なら debug の `/doc/*` の対象にしない（質問の選択肢の見本）
    init(tracksCurrent: Bool = true) {
        let config = WKWebViewConfiguration()
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        if tracksCurrent { Self.current = self }
        config.userContentController.add(MessageProxy(owner: self), name: "tb")
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        #endif
        Task { await prepare() }
    }

    /// 外部読み込みを止める規則をコンパイルしてから最初の文書を載せる（ネットワークに出さないことを先に確定する）
    private func prepare() async {
        guard let list = await Self.blockList() else {
            pending = nil
            failure = UserFacingError(
                "本文を表示できませんでした", cause: String(localized: "外部の読み込みを防ぐ設定を用意できませんでした"),
                remedy: String(localized: "アプリを開き直してください"))
            return
        }
        webView.configuration.userContentController.add(list)
        blockList = list
        ready = true
        if let pending {
            self.pending = nil
            load(html: pending.html, highlights: pending.highlights, allowsRemote: pending.allowsRemote)
        }
    }

    private static func blockList() async -> WKContentRuleList? {
        let rules = """
            [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","raw","svg-document","media","popup","ping","fetch","websocket","other"]},"action":{"type":"block"}}]
            """
        return try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "tb-block-external", encodedContentRuleList: rules)
    }

    /// 組み立てた HTML をそのまま載せる（概況の自由の部品。文書の選択とハイライトの橋渡しは入れない）
    func load(page html: String) {
        load(html: html, highlights: [], allowsRemote: false)
    }

    /// `allowsRemote` は利用者がこの文書のリモートコンテンツを許したときだけ true（外部の読み込みを止める規則を外す）
    func load(content: DocContent, highlights: [HighlightItem], textSize: Double, forms: Bool = true, allowsRemote: Bool = false) {
        load(html: Self.html(for: content, textSize: textSize, forms: forms), highlights: highlights, allowsRemote: allowsRemote)
    }

    /// 文字の大きさ（pt）を変える。markdown の文書だけが従う（html の文書は見た目を変えない）
    func setTextSize(_ size: Double) {
        webView.evaluateJavaScript("document.documentElement.style.setProperty('--tb-size', '\(size)px')") { _, _ in }
    }

    private func load(html: String, highlights: [HighlightItem], allowsRemote: Bool) {
        guard failure == nil else { return }
        guard ready, let blockList else {
            pending = (html, highlights, allowsRemote)
            return
        }
        // 規則の付け外しは次の読み込みから効く。止める側へ戻すのは、許していない文書に切り替えたとき（同じ web view を使い回す）
        let controller = webView.configuration.userContentController
        if allowsRemote, blocksRemote {
            controller.remove(blockList)
            blocksRemote = false
        } else if !allowsRemote, !blocksRemote {
            controller.add(blockList)
            blocksRemote = true
        }
        self.highlights = highlights
        selectionRect = nil
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// 引用のハイライトを引き直す。`active` は濃く出す
    func setHighlights(_ items: [HighlightItem], active: Int64?) {
        highlights = items
        activeID = active
        applyHighlights()
    }

    private func applyHighlights() {
        let payload = highlights.map { ["id": $0.id, "exact": $0.anchor.exact, "prefix": $0.anchor.prefix] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__tb && __tb.highlight(\(json), \(activeID.map(String.init) ?? "null"))") { _, _ in }
    }

    /// 欄を描き直す。書きかけの選択と文は残る
    func setForms(_ payload: DocumentForms.Payload) {
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else { return }
        formsJSON = json
        applyForms()
    }

    private func applyForms() {
        guard let formsJSON else { return }
        webView.evaluateJavaScript("window.__tbForms && __tbForms.set(\(formsJSON))") { [weak self] _, _ in
            MainActor.assumeIsolated { self?.flushFormScroll() }
        }
    }

    private func flushFormScroll() {
        guard let slot = pendingFormScroll, formsJSON != nil,
            let data = try? JSONSerialization.data(withJSONObject: [slot]), let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript("window.__tbForms ? __tbForms.scrollTo(\(json)[0]) : false") { [weak self] result, _ in
            MainActor.assumeIsolated {
                if result as? Bool == true, self?.pendingFormScroll == slot { self?.pendingFormScroll = nil }
            }
        }
    }

    /// 欄（`ask:q1`・`draft:id`）の位置まで送る。まだ描いていなければ描いた後に送る
    func scroll(toForm slot: String) {
        pendingFormScroll = slot
        flushFormScroll()
    }

    /// 答えた結果を欄に返す（失敗なら欄に文を出し、ボタンを戻す）
    func formResult(kind: String, id: String, error: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: [kind, id, error as Any]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__tbForms && __tbForms.result.apply(null, \(json))") { _, _ in }
    }

    #if DEBUG
    /// 欄を押す（DebugServer の `/doc/js`）。欄の中の操作は MessageProxy を通る本物の経路になる
    func debugEvaluate(_ script: String) async -> Any? {
        try? await webView.evaluateJavaScript(script)
    }
    #endif

    func scroll(to commentID: Int64) {
        webView.evaluateJavaScript("window.__tb && __tb.scrollTo(\(commentID))") { _, _ in }
    }

    /// 今の選択範囲（引用のアンカー）。無ければ nil
    func selection() async -> CommentAnchor? {
        guard let result = try? await webView.evaluateJavaScript("window.__tb ? __tb.selection() : null"), let dict = result as? [String: Any],
            let exact = dict["exact"] as? String, !exact.isEmpty
        else { return nil }
        return CommentAnchor(exact: exact, prefix: dict["prefix"] as? String ?? "", suffix: dict["suffix"] as? String ?? "")
    }

    func clearSelection() {
        webView.evaluateJavaScript("window.getSelection() && window.getSelection().removeAllRanges()") { _, _ in }
        selectionRect = nil
    }

    /// 本文の文字と、画像が読み込まれたか（外部遮断の確認用）
    func debugProbe() async -> [String: Any] {
        let script = "JSON.stringify({text: document.body ? document.body.innerText : null, images: Array.from(document.images).map(i => ({src: i.src, loaded: i.complete && i.naturalWidth > 0})), stylesheets: Array.from(document.styleSheets).filter(s => s.href).map(s => ({href: s.href, loaded: (() => { try { return s.cssRules.length >= 0 } catch (e) { return e.name === 'SecurityError' } })()})), highlights: ('highlights' in CSS) ? Array.from(CSS.highlights.keys()) : null})"
        guard let result = try? await webView.evaluateJavaScript(script) as? String, let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["error": "評価できない"] }  // ui-copy:ignore（画面に出ない。接続の記録と debug の口だけが読む）
        var probe = object
        probe["blocksRemote"] = blocksRemote
        return probe
    }

    #if DEBUG
    /// 本文の最初の一致を選ぶ（DebugServer の `/doc/select`）
    func debugSelect(_ text: String) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: data, encoding: .utf8) else { return false }
        let result = try? await webView.evaluateJavaScript("window.getSelection().removeAllRanges(); window.find(\(json)[0])")
        return result as? Bool ?? false
    }
    #endif

    /// 表示中の本文を 1 枚の PDF にする
    func pdf() async throws -> Data {
        try await webView.pdf()
    }

    /// WKWebView 自身の描画（ウィンドウのスクリーンショットには写らないため）
    func debugSnapshot() async -> Data? {
        guard let image = try? await webView.takeSnapshot(configuration: nil) else { return nil }
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #else
        return image.pngData()
        #endif
    }

    // MARK: HTML

    /// `forms` は本文の印を質問と送る文面の欄の置き場にし、欄の見た目と動きを足す（選択肢の見本の頁では足さない）
    static func html(for content: DocContent, textSize: Double, forms: Bool = true) -> String {
        let formsStyle = forms ? DocumentForms.style : ""
        let formsTail = forms ? DocumentForms.endSlot + "<script>\(DocumentForms.script)</script>" : ""
        switch content.format {
        case .markdown:
            var escaping = HTMLEscaping()
            let document = Markdown.Document(parsing: content.content, options: [.parseBlockDirectives, .parseSymbolLinks])
            let rendered = DiffCode.html(escaping.visit(document).map { HTMLFormatter.format($0) } ?? "")
            let body = forms ? DocumentForms.placeSlots(in: rendered) : rendered
            return "<!doctype html><html style=\"--tb-size:\(textSize)px\"><head><meta charset=\"utf-8\">\(viewport)<meta name=\"color-scheme\" content=\"light dark\"><style>\(markdownStyle)\(highlightStyle)\(formsStyle)</style></head><body class=\"tb-markdown\"><main>\(body)</main>\(formsTail)<script>\(bridgeScript)</script></body></html>"
        case .html:
            // 文書の見た目は変えない。ハイライトの見た目と選択の橋渡し、欄の置き場だけ足す。viewport が無ければ足す（iPhone で縮んで出る）
            var html = forms ? DocumentForms.placeSlots(in: content.content) : content.content
            if html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil && html.range(of: "name=viewport", options: .caseInsensitive) == nil {
                if let head = html.range(of: "<head>", options: .caseInsensitive) {
                    html.replaceSubrange(head, with: "<head>" + viewport)
                } else {
                    html = viewport + html
                }
            }
            let injection = "<style>\(highlightStyle)\(formsStyle)</style>\(formsTail)<script>\(bridgeScript)</script>"
            if let range = html.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                return html.replacingCharacters(in: range, with: injection + "</body>")
            }
            return html + injection
        }
    }

    static let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

    static let markdownStyle = """
        :root{color-scheme:light dark}
        body{margin:0;padding:24px 20px 64px;font:var(--tb-size,14px)/1.7 -apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif;color:CanvasText;background:transparent;overflow-wrap:anywhere}
        main{max-width:760px;margin:0 auto}
        h1{font-size:1.5em;margin:.2em 0 .6em} h2{font-size:1.2em;margin:1.6em 0 .5em;padding-bottom:.2em;border-bottom:.5px solid rgba(127,127,127,.35)} h3{font-size:1.05em;margin:1.3em 0 .4em}
        p,ul,ol,pre,table,blockquote{margin:.5em 0} li{margin:.15em 0}
        code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.92em;background:rgba(127,127,127,.15);padding:.1em .35em;border-radius:4px}
        pre{background:rgba(127,127,127,.12);padding:10px 12px;border-radius:8px;white-space:pre-wrap} pre code{background:none;padding:0}
        pre code:has(> [class^=tb-diff-]){display:block;width:max-content;min-width:100%} [class^=tb-diff-]{display:block}
        .tb-diff-added{background:rgba(52,199,89,.12)} .tb-diff-removed{background:rgba(255,59,48,.12)} .tb-diff-hunk,.tb-diff-header{color:GrayText}
        .tb-diff-added>.tb-sign{color:#28a745} .tb-diff-removed>.tb-sign{color:#d73a49}
        table{border-collapse:collapse;font-size:.95em} td,th{border:.5px solid rgba(127,127,127,.4);padding:4px 8px;text-align:left;vertical-align:top} th{background:rgba(127,127,127,.1)}
        blockquote{padding-left:12px;border-left:3px solid rgba(127,127,127,.4);color:GrayText}
        a{color:LinkText} img{max-width:100%} hr{border:0;border-top:.5px solid rgba(127,127,127,.4)}
        input[type=checkbox]{margin-right:.4em}
        """

    static let highlightStyle = """
        ::highlight(tb-comment){background:rgba(255,204,0,.38)} ::highlight(tb-comment-active){background:rgba(255,140,0,.7);color:CanvasText}
        """

    /// 引用の検索とハイライト（CSS Custom Highlight API）、選択範囲の取り出し
    static let bridgeScript = """
        (function(){
        const TB = window.__tb = { ranges: {} };
        function textNodes(){ const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const nodes = []; let n; while ((n = w.nextNode())) { if (n.parentElement && n.parentElement.closest('script,style')) continue; nodes.push(n); } return nodes; }
        function rangeFor(exact, prefix){
          const nodes = textNodes(); let full = ''; const starts = [];
          for (const n of nodes) { starts.push(full.length); full += n.nodeValue; }
          let idx = -1;
          if (prefix) { const p = full.indexOf(prefix + exact); if (p >= 0) idx = p + prefix.length; }
          if (idx < 0) idx = full.indexOf(exact);
          if (idx < 0) return null;
          const end = idx + exact.length; const r = document.createRange(); let started = false;
          for (let i = 0; i < nodes.length; i++) {
            const s = starts[i], e = s + nodes[i].nodeValue.length;
            if (!started && idx >= s && idx < e) { r.setStart(nodes[i], idx - s); started = true; }
            if (started && end > s && end <= e) { r.setEnd(nodes[i], end - s); return r; }
          }
          return null;
        }
        TB.highlight = function(items, activeId){
          TB.ranges = {}; if (!('highlights' in CSS)) return;
          const all = [], active = [];
          for (const it of items) { const r = rangeFor(it.exact, it.prefix); if (!r) continue; TB.ranges[it.id] = r; (it.id === activeId ? active : all).push(r); }
          CSS.highlights.set('tb-comment', new Highlight(...all)); CSS.highlights.set('tb-comment-active', new Highlight(...active));
        };
        TB.scrollTo = function(id){ const r = TB.ranges[id]; if (!r) return false; const el = r.startContainer.parentElement || document.body; el.scrollIntoView({ block: 'center', behavior: 'smooth' }); return true; };
        TB.selection = function(){
          const s = window.getSelection(); if (!s || s.isCollapsed || s.rangeCount === 0) return null;
          const r = s.getRangeAt(0); const exact = r.toString(); if (!exact.trim()) return null;
          const pre = document.createRange(); pre.setStart(document.body, 0); pre.setEnd(r.startContainer, r.startOffset);
          const post = document.createRange(); post.setStart(r.endContainer, r.endOffset); post.setEnd(document.body, document.body.childNodes.length);
          return { exact: exact, prefix: pre.toString().slice(-64), suffix: post.toString().slice(0, 64) };
        };
        let queued = false;
        function report(){
          queued = false;
          const s = window.getSelection(); const has = !!(s && !s.isCollapsed && s.rangeCount > 0 && s.toString().trim().length > 0);
          const b = has ? s.getRangeAt(0).getBoundingClientRect() : null;
          const rect = b ? { x: b.left, y: b.top, width: b.width, height: b.height } : null;
          if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tb) window.webkit.messageHandlers.tb.postMessage({ type: 'selection', has: has, rect: rect });
        }
        function queue(){ if (!queued) { queued = true; requestAnimationFrame(report); } }
        document.addEventListener('selectionchange', queue);
        window.addEventListener('scroll', queue, true);
        window.addEventListener('resize', queue);
        })();
        """

    /// WKScriptMessageHandler は強参照で持たれるので、controller を弱く持つ代理を挟む
    private final class MessageProxy: NSObject, WKScriptMessageHandler {
        weak var owner: DocumentWebController?
        init(owner: DocumentWebController) { self.owner = owner }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "formsPending" {
                let value = body["value"] as? Bool ?? false
                Task { @MainActor in self.owner?.formsPendingInput = value }
                return
            }
            if let action = DocumentFormAction(message: body) {
                Task { @MainActor in self.owner?.onFormAction?(action) }
                return
            }
            guard body["type"] as? String == "selection" else { return }
            let rect = (body["has"] as? Bool ?? false) ? (body["rect"] as? [String: Double]).map {
                CGRect(x: $0["x"] ?? 0, y: $0["y"] ?? 0, width: $0["width"] ?? 0, height: $0["height"] ?? 0)
            } : nil
            Task { @MainActor in self.owner?.selectionRect = rect }
        }
    }
}

extension DocumentWebController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // 文書自身の読み込み（about:blank）だけ通す。押したリンクだけをブラウザかアプリの中へ渡し、
        // script・meta refresh・iframe・フォームによる遷移は止める（ユーザーの操作なしに外のアプリが開かないように）
        guard let url = navigationAction.request.url, url.scheme != "about" else { return decisionHandler(.allow) }
        let pressed = navigationAction.navigationType == .linkActivated && navigationAction.targetFrame?.isMainFrame != false
        switch Self.destination(of: url, pressed: pressed) {
        case .browser: ExternalLinks.open(url)
        case .app: openInApp?(url)
        case .ignore: break
        }
        decisionHandler(.cancel)
    }

    /// 文書の中の遷移の開き先。押したリンクだけをチャットと同じ規則（`LinkDestination`）で振り分け、それ以外は開かない
    nonisolated static func destination(of url: URL, pressed: Bool) -> LinkDestination {
        pressed ? LinkDestination(url) : .ignore
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyHighlights()
        applyForms()
        webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] value, _ in
            guard let height = value as? Double else { return }
            MainActor.assumeIsolated { self?.contentHeight = CGFloat(height) }
        }
    }
}

/// 本文の欄でした操作。JS の `postMessage` の中身から読む（読めない中身は捨てる）
enum DocumentFormAction: Equatable {
    case answer(askID: Int64, answers: [AskAnswer])
    case cancel(askID: Int64)
    case approve(draftID: String, body: String)

    init?(message body: [String: Any]) {
        switch body["type"] as? String {
        case "answerAsk":
            guard let id = (body["askID"] as? NSNumber)?.int64Value, let raw = body["answers"] as? [[String: Any]] else { return nil }
            let answers = raw.compactMap { a -> AskAnswer? in
                guard let q = a["questionID"] as? String else { return nil }
                return AskAnswer(questionID: q, selected: a["selected"] as? [String] ?? [], freeText: a["freeText"] as? String)
            }
            self = .answer(askID: id, answers: answers)
        case "cancelAsk":
            guard let id = (body["askID"] as? NSNumber)?.int64Value else { return nil }
            self = .cancel(askID: id)
        case "approveDraft":
            guard let id = body["draftID"] as? String, let text = body["body"] as? String else { return nil }
            self = .approve(draftID: id, body: text)
        default:
            return nil
        }
    }
}

#if os(macOS)
struct DocumentWebView: NSViewRepresentable {
    let controller: DocumentWebController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct DocumentWebView: UIViewRepresentable {
    let controller: DocumentWebController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

/// swift-markdown の `HTMLFormatter` は文字・コード・リンクとイメージの属性を escape しないまま出す（`a <b` の `<b` がタグになる）。
/// 渡す前に木の葉の文字を escape しておく。Markdown の中に書いた HTML（`HTMLBlock`・`InlineHTML`）はそのまま通す
struct HTMLEscaping: MarkupRewriter {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    mutating func visitText(_ text: Markdown.Text) -> Markup? {
        var text = text
        text.string = Self.escape(text.string)
        return text
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> Markup? {
        var inlineCode = inlineCode
        inlineCode.code = Self.escape(inlineCode.code)
        return inlineCode
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> Markup? {
        var codeBlock = codeBlock
        codeBlock.code = Self.escape(codeBlock.code)
        codeBlock.language = codeBlock.language.map(Self.escape)
        return codeBlock
    }

    mutating func visitSymbolLink(_ symbolLink: SymbolLink) -> Markup? {
        var symbolLink = symbolLink
        symbolLink.destination = symbolLink.destination.map(Self.escape)
        return symbolLink
    }

    mutating func visitLink(_ link: Markdown.Link) -> Markup? {
        var link = link
        link.destination = link.destination.map(Self.escape)
        return defaultVisit(link)
    }

    mutating func visitImage(_ image: Markdown.Image) -> Markup? {
        var image = image
        image.source = image.source.map(Self.escape)
        image.title = image.title.map(Self.escape)
        return defaultVisit(image)
    }
}
