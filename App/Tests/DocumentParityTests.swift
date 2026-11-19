import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 文書の画面のリモートコンテンツの許可・差分の頁・エディタの URL・図と色付けの埋め込み
@Suite struct DocumentParityTests {
    private func scratch() -> UserDefaults {
        let name = "uk.whatn.taskboard.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private let key = DocKey(machine: MachineID(rawValue: "m-test"), id: 7)

    @Test("リモートコンテンツは許したホストだけを覚え、版でホストが増えたら聞き直す。前の版のホストは許したまま")
    func remoteContentPerDocument() {
        let defaults = scratch()
        #expect(DocumentRemoteContent.isAllowed([], for: key, in: defaults))
        #expect(!DocumentRemoteContent.isAllowed(["cdn.example.com"], for: key, in: defaults))
        DocumentRemoteContent.allow(["cdn.example.com"], for: key, in: defaults)
        #expect(DocumentRemoteContent.isAllowed(["cdn.example.com"], for: key, in: defaults))
        #expect(!DocumentRemoteContent.isAllowed(["cdn.example.com", "img.example.org"], for: key, in: defaults))
        DocumentRemoteContent.allow(["cdn.example.com", "img.example.org"], for: key, in: defaults)
        #expect(DocumentRemoteContent.isAllowed(["img.example.org"], for: key, in: defaults))
        // 別のマシンの同じ番号の文書は別に聞く
        #expect(!DocumentRemoteContent.isAllowed(["cdn.example.com"], for: DocKey(machine: MachineID(rawValue: "m-other"), id: 7), in: defaults))
    }

    @Test("差分の頁は diff のコードの塊で、本文の ``` より長い囲みにする。同じ本文は「同じです」")
    func diffPage() {
        let old = DocContent(docID: 1, rev: 1, format: .markdown, content: "# 計画\n```swift\nlet a = 1\n```")
        let new = DocContent(docID: 1, rev: 2, format: .markdown, content: "# 計画\n```swift\nlet a = 2\n```")
        let page = DocumentDiffPage.content(old: old, new: new)
        #expect(page.format == .markdown && page.rev == 2)
        #expect(page.content.contains("````diff\n@@ -1,4 +1,4 @@\n # 計画\n ```swift\n-let a = 1\n+let a = 2\n ```\n````"))
        #expect(DocumentDiffPage.content(old: old, new: old).content.contains("前の版と同じです。"))
    }

    @Test("エディタの URL は {path} を元のファイルのパス（空白と日本語は percent-encoding）に置き換え、空なら VS Code")
    func editorURL() {
        #expect(DocumentEditorURL.url(template: "", path: "/tmp/計画 書.md")?.absoluteString == "vscode://file/tmp/%E8%A8%88%E7%94%BB%20%E6%9B%B8.md")
        #expect(DocumentEditorURL.url(template: "cursor://file{path}:1", path: "/a/b.md")?.absoluteString == "cursor://file/a/b.md:1")
    }

    @Test("mermaid と highlight.js は使う本文にだけ埋める（diff だけのコードは色付けしない）")
    func scriptsOnlyWhenUsed() {
        #expect(DocumentScripts.injection(for: "<p>本文</p>").script.isEmpty)
        #expect(DocumentScripts.injection(for: "<pre><code class=\"language-diff\">+a</code></pre>").script.isEmpty)
        let swift = DocumentScripts.injection(for: "<pre><code class=\"language-swift\">let a</code></pre>")
        #expect(swift.script.contains("hljs") && !swift.script.contains("mermaid.initialize"))
        let mermaid = DocumentScripts.injection(for: "<pre><code class=\"language-mermaid\">flowchart LR</code></pre>")
        #expect(mermaid.script.contains("mermaid.initialize") && !mermaid.script.contains("highlightElement(el)"))
    }
}
