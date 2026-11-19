import Foundation
import TaskboardKit

/// 前の版との差分の頁。差分を ```diff のコードの塊にした markdown にし、本文と同じ描き方（`DiffCode` の色）に通す
enum DocumentDiffPage {
    static func content(old: DocContent, new: DocContent) -> DocContent {
        let diff = LineDiff.unified(old: old.content, new: new.content)
        let heading = String(localized: "第\(old.rev)版から第\(new.rev)版への差分")
        let body: String
        if diff.isEmpty {
            body = String(localized: "前の版と同じです。")
        } else {
            // 本文に ``` があっても塊が切れないよう、中の最も長い backtick の並びより 1 つ長くする
            let longest = diff.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            body = "\(fence)diff\n\(diff)\n\(fence)"
        }
        return DocContent(docID: new.docID, rev: new.rev, format: .markdown, content: "## \(heading)\n\n\(body)\n")
    }
}
