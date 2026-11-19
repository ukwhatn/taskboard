import Foundation
import Testing

@testable import TaskboardKit

@Suite("画像でない添付を本文に書く形")
struct MentionedFilesTests {
    private let paths = ["/Users/me/資料/見積 v2.pdf", "/tmp/a&b<c>.csv"]

    @Test("Claude は本文の頭に uploaded_files を付ける（Claude Desktop と同じ形）。パスの & < > は書き換える")
    func claude() {
        #expect(
            MentionedFiles.compose("これを読んで", paths: paths, engine: .claude) == """
                <uploaded_files>
                <file><file_path>/Users/me/資料/見積 v2.pdf</file_path></file>
                <file><file_path>/tmp/a&amp;b&lt;c&gt;.csv</file_path></file>
                </uploaded_files>

                これを読んで
                """)
    }

    @Test("codex は Files mentioned by the user の一覧と My request を付ける（Codex Desktop と同じ形）。見出しはファイルの名前")
    func codex() {
        #expect(
            MentionedFiles.compose("これを読んで", paths: paths, engine: .codex) == """
                # Files mentioned by the user:

                ## 見積 v2.pdf: /Users/me/資料/見積 v2.pdf

                ## a&b<c>.csv: /tmp/a&b<c>.csv

                ## My request:
                これを読んで
                """)
    }

    @Test("ファイルが無ければ本文をそのまま返す。本文が空でもファイルの一覧だけを送る")
    func edges() {
        #expect(MentionedFiles.compose("そのまま", paths: [], engine: .claude) == "そのまま")
        #expect(MentionedFiles.compose("", paths: [], engine: .codex) == "")
        #expect(MentionedFiles.compose("", paths: ["/a"], engine: .claude) == "<uploaded_files>\n<file><file_path>/a</file_path></file>\n</uploaded_files>")
        #expect(MentionedFiles.compose("", paths: ["/a"], engine: .codex) == "# Files mentioned by the user:\n\n## a: /a\n\n## My request:\n")
    }

    @Test("履歴の本文から一覧を外してパスと本文に分ける。作る形と往復する（Claude・codex、本文が空、複数行の本文、パスに & < > と「: 」）")
    func splitsRoundTrip() {
        let tricky = ["/tmp/x: y.txt", "/Users/me/資料/見積 v2.pdf", "/tmp/a&b<c>.csv"]
        for engine in [Conversation.Engine.claude, .codex] {
            for text in ["これを読んで", "", "1 行目\n\n## 見出し\n<file>本文</file>"] {
                let split = MentionedFiles.split(MentionedFiles.compose(text, paths: tricky, engine: engine))
                #expect(split?.paths == tricky, "\(engine) \(text)")
                #expect(split?.text == text, "\(engine) \(text)")
            }
        }
    }

    @Test("頭に一覧が無い本文と、閉じていない一覧は分けない")
    func splitsOnlyLists() {
        #expect(MentionedFiles.split("ふつうの発言") == nil)
        #expect(MentionedFiles.split("") == nil)
        #expect(MentionedFiles.split("前置き\n<uploaded_files>\n<file><file_path>/a</file_path></file>\n</uploaded_files>") == nil)
        #expect(MentionedFiles.split("<uploaded_files>\n<file><file_path>/a</file_path></file>\n") == nil)
        #expect(MentionedFiles.split("# Files mentioned by the user:\n\n## a: /a\n\n") == nil)
    }

    @Test("送る要求の files は前の版のアプリが送らなくても読める")
    func decodesWithoutFiles() throws {
        let request = try JSONDecoder().decode(ConversationSendRequest.self, from: Data(#"{"text":"x","attachments":[],"clientMessageID":"c"}"#.utf8))
        #expect(request.files.isEmpty)
        let round = try JSONDecoder().decode(ConversationSendRequest.self, from: JSONEncoder().encode(ConversationSendRequest(text: "x", files: ["/a"])))
        #expect(round.files == ["/a"])
    }

    @Test("後で送る印は true のときだけ載り、前の版の要求と false は印なしで読む")
    func laterFlag() throws {
        let plain = try JSONEncoder().encode(ConversationSendRequest(text: "x", clientMessageID: "c"))
        #expect(!String(decoding: plain, as: UTF8.self).contains("later"))
        let later = try JSONDecoder().decode(ConversationSendRequest.self, from: JSONEncoder().encode(ConversationSendRequest(text: "x", later: true)))
        #expect(later.isLater)
        let old = try JSONDecoder().decode(ConversationSendRequest.self, from: Data(#"{"text":"x","attachments":[],"clientMessageID":"c"}"#.utf8))
        #expect(!old.isLater && old.later == nil)
        let falseFlag = try JSONDecoder().decode(ConversationSendRequest.self, from: Data(#"{"text":"x","attachments":[],"clientMessageID":"c","later":false}"#.utf8))
        #expect(falseFlag.later == nil)
    }
}
