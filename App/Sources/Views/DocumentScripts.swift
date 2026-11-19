import Foundation

/// 文書の markdown の本文で動かす、同梱の mermaid（図）と highlight.js（コードの色付け）。
/// 外部の読み込みは止めていて、`about:blank` の頁からはアプリの中のファイルも読めないので、文字として頁に埋める。
/// 使う本文にだけ入れる（mermaid は 5MB あり、全部の文書で評価すると開くのが遅くなる）
enum DocumentScripts {
    /// 色付けしない言語（diff は `DiffCode` の色、mermaid は図にする）
    private static let plainLanguages: Set<String> = ["diff", "patch", "mermaid"]

    /// HTML にした markdown の本文に要る style と script。要らなければ空
    static func injection(for rendered: String) -> (style: String, script: String) {
        let languages = codeLanguages(in: rendered)
        var style = ""
        var script = ""
        if !languages.subtracting(plainLanguages).isEmpty, let hljs = resource("highlight.min", "js") {
            style += highlightStyle
            script += "<script>\(hljs)</script><script>\(highlightRun)</script>"
        }
        if languages.contains("mermaid"), let mermaid = resource("mermaid.min", "js") {
            style += mermaidStyle
            script += "<script>\(mermaid)</script><script>\(mermaidRun)</script>"
        }
        return (style, script)
    }

    private static let languagePattern = try! NSRegularExpression(pattern: "<code class=\"language-([^\"\\s]+)\"")

    private static func codeLanguages(in html: String) -> Set<String> {
        let ns = html as NSString
        return Set(languagePattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)).lowercased() })
    }

    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// 頁に埋めるので、`</script` を頁の終わりと取り違えないよう崩しておく
    private static func resource(_ name: String, _ ext: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "DocumentScripts"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let safe = text.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        cache[name] = safe
        return safe
    }

    /// GitHub のライトとダークの色を、OS の外観で切り替える。地と余白は本文のコードの塊（`markdownStyle` の pre）に任せる
    private static var highlightStyle: String {
        let light = resource("highlight-github.min", "css") ?? ""
        let dark = resource("highlight-github-dark.min", "css") ?? ""
        return "@media (prefers-color-scheme: light){\(light)}@media (prefers-color-scheme: dark){\(dark)}pre code.hljs{display:inline;padding:0;background:none;overflow-x:visible}"
    }

    private static let highlightRun = """
        (function(){
        if (!window.hljs) return;
        document.querySelectorAll('pre > code[class^="language-"]').forEach(function(el){
          var lang = el.className.slice('language-'.length).toLowerCase();
          if (['diff','patch','mermaid'].indexOf(lang) >= 0 || !hljs.getLanguage(lang)) return;
          hljs.highlightElement(el);
        });
        })();
        """

    private static let mermaidStyle = ".tb-mermaid{margin:.8em 0;text-align:center}.tb-mermaid svg{max-width:100%;height:auto}"

    /// 図の元の文は data 属性に残し、外観が替わったらその色で描き直す。描けない図は元の文のまま出す
    private static let mermaidRun = """
        (function(){
        if (!window.mermaid) return;
        var items = Array.prototype.map.call(document.querySelectorAll('pre > code.language-mermaid'), function(code){
          var box = document.createElement('div'); box.className = 'tb-mermaid'; box.dataset.source = code.textContent;
          code.parentElement.replaceWith(box); return box;
        });
        if (!items.length) return;
        var dark = window.matchMedia('(prefers-color-scheme: dark)');
        var round = 0;
        async function render(){
          var mine = ++round;
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark.matches ? 'dark' : 'default' });
          for (var i = 0; i < items.length; i++) {
            var box = items[i];
            try {
              var out = await mermaid.render('tb-mermaid-' + mine + '-' + i, box.dataset.source);
              if (mine !== round) return;
              box.innerHTML = out.svg; delete box.dataset.error;
            } catch (e) {
              var pre = document.createElement('pre'); pre.textContent = box.dataset.source;
              box.replaceChildren(pre); box.dataset.error = String((e && e.message) || e);
            }
          }
        }
        dark.addEventListener('change', render);
        render();
        })();
        """
}
