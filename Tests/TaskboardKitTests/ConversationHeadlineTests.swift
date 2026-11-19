import Foundation
import Testing

@testable import TaskboardKit

@Suite("最後の応答の頭の 1 文")
struct ConversationHeadlineTests {
    private func headline(_ text: String) -> String {
        ConversationReply(text: text, at: Date(timeIntervalSince1970: 0)).headline
    }

    @Test("日本語は最初の句点・感嘆符・疑問符まで")
    func japanese() {
        #expect(headline("D3 の回答に合わせて修正しました。残りは D5 です。") == "D3 の回答に合わせて修正しました。")
        #expect(headline("終わりました！次は何を？") == "終わりました！")
        #expect(headline("進めてよいですか？　理由は下に") == "進めてよいですか？")
    }

    @Test("英語は文の終わりの記号の後に空白があるところまで。数字の小数点や版では切らない")
    func english() {
        #expect(headline("Fixed the build. Next is tests.") == "Fixed the build.")
        #expect(headline("Bumped to v1.2.3 and done") == "Bumped to v1.2.3 and done")
        #expect(headline("Ready? Yes.") == "Ready?")
    }

    @Test("改行で切り、頭の Markdown の印と強調を外す")
    func markdown() {
        #expect(headline("## 結果\n本文です。") == "結果")
        #expect(headline("\n\n- **PR を 1 本**にまとめた\n- 次") == "PR を 1 本にまとめた")
        #expect(headline("> 引用の文。続き") == "引用の文。")
        #expect(headline("1. `swift test` が通った。") == "swift test が通った。")
    }

    @Test("空と、空白だけの応答は空")
    func empty() {
        #expect(headline("") == "")
        #expect(headline("  \n  \n") == "")
    }
}
