import SwiftUI
import TaskboardKit

/// 質問の選択肢の見本。markdown は `MarkdownView`、HTML は文書と同じく外部の読み込みを止めた WKWebView で描く
struct AskOptionPreview: View {
    let option: AskOption

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            Text("見本：\(option.displayLabel)").textRole(.caption).lineLimit(1).truncationMode(.tail)
            if let preview = option.preview, option.previewIsHTML {
                AskOptionHTMLPreview(html: preview)
                    .frame(height: AskFormMetrics.previewHeight)
                    .overlay(RoundedRectangle(cornerRadius: Radius.box, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
            } else {
                ScrollView {
                    MarkdownView(option.preview ?? "").frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: AskFormMetrics.previewHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AskOptionHTMLPreview: View {
    let html: String
    @State private var web = DocumentWebController(tracksCurrent: false)

    var body: some View {
        DocumentWebView(controller: web)
            .clipShape(RoundedRectangle(cornerRadius: Radius.box, style: .continuous))
            .onAppear { load() }
            .onChange(of: html) { load() }
    }

    private func load() {
        web.load(content: DocContent(docID: 0, rev: 0, format: .html, content: html), highlights: [], textSize: 13, forms: false)
    }
}
