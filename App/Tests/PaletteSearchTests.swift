import Foundation
import Testing
@testable import Taskboard

@Suite struct PaletteSearchTests {
    private func item(_ id: String, _ kind: PaletteEntry.Kind, _ title: String, _ subtitle: String = "", keywords: [String] = []) -> PaletteEntry {
        PaletteEntry(id: id, kind: kind, title: title, subtitle: subtitle, keywords: keywords)
    }

    private var items: [PaletteEntry] {
        [
            item("c-new", .command, "新規タスク", keywords: ["new", "task"]),
            item("c-inbox", .command, "受信箱を開く", keywords: ["inbox"]),
            item("t-148", .task, "#148 taskboard アプリを仕上げる", "この Mac・default"),
            item("t-12", .task, "#12 feat(mfg): 製造モジュール", "Mac Studio・default"),
            item("s-1", .conversation, "claude new-tool", "taskboard"),
            item("p-1", .pullRequest, "fix: 通知の URL", "Example-Org/server#4360"),
            item("b-1", .board, "default", "この Mac"),
        ]
    }

    @Test("空の欄ではコマンドだけを並べる")
    func emptyShowsCommands() {
        #expect(PaletteSearch.rank(items, query: "").map(\.id) == ["c-new", "c-inbox"])
        #expect(PaletteSearch.rank(items, query: "   ").map(\.id) == ["c-new", "c-inbox"])
    }

    @Test("コマンドの検索語の先頭に一致すれば、題に同じ語を含むタスクより先に出す")
    func commandKeywordBeatsTaskTitle() {
        let entries = [
            item("t-148", .task, "#148 taskboard アプリを仕上げる"),
            item("c-board", .command, "案件を作る", keywords: ["new board", "board"]),
        ]
        #expect(PaletteSearch.rank(entries, query: "board").map(\.id) == ["c-board", "t-148"])
        #expect(PaletteSearch.rank(entries, query: "Board").map(\.id) == ["c-board", "t-148"])
    }

    @Test("大文字小文字を区別しない")
    func caseInsensitive() {
        #expect(PaletteSearch.rank(items, query: "TASKBOARD").map(\.id).first == "t-148")
    }

    @Test("題の先頭に一致するものを先に出す")
    func prefixFirst() {
        // 「default」は案件の題の先頭、タスクでは副題に入る
        #expect(PaletteSearch.rank(items, query: "default").map(\.id) == ["b-1", "t-148", "t-12"])
    }

    @Test("番号は # 付きでも数字だけでも、そのタスクを先頭に")
    func taskNumber() {
        #expect(PaletteSearch.rank(items, query: "#148").first?.id == "t-148")
        #expect(PaletteSearch.rank(items, query: "12").first?.id == "t-12")
    }

    @Test("空白で区切った語はすべて含むものだけ")
    func allTokens() {
        #expect(PaletteSearch.rank(items, query: "claude taskboard").map(\.id) == ["s-1"])
        #expect(PaletteSearch.rank(items, query: "claude 存在しない").isEmpty)
    }

    @Test("日本語の部分一致と、keywords での一致")
    func japaneseAndKeywords() {
        #expect(PaletteSearch.rank(items, query: "受信").map(\.id) == ["c-inbox"])
        #expect(PaletteSearch.rank(items, query: "inbox").map(\.id) == ["c-inbox"])
        #expect(PaletteSearch.rank(items, query: "server#4360").map(\.id) == ["p-1"])
    }

    @Test("同じ強さの一致はコマンド → タスク → セッション → PR → 案件の順")
    func kindOrder() {
        let tie = [item("p", .pullRequest, "abc"), item("t", .task, "abc"), item("c", .command, "abc")]
        #expect(PaletteSearch.rank(tie, query: "abc").map(\.id) == ["c", "t", "p"])
    }

    @Test("件数は上限で切る")
    func limit() {
        let many = (0..<200).map { item("t\($0)", .task, "task \($0)") }
        #expect(PaletteSearch.rank(many, query: "task").count == PaletteSearch.limit)
    }
    @Test("紐づく URL の先頭が一致すれば、題の一致より先に出す。scheme の有無と大文字小文字は問わない")
    func urlPrefix() {
        var task = item("t-7", .task, "#7 通知の設定を直す")
        task.urls = ["https://github.com/Example-Org/server/pull/4360", "https://example.slack.com/archives/C01/p123"]
        var pr = item("p-1", .pullRequest, "fix: github.com/Example-Org/server の URL")
        pr.urls = ["https://github.com/Example-Org/server/pull/4361"]
        let entries = [pr, task]
        #expect(PaletteSearch.rank(entries, query: "https://github.com/Example-Org/server/pull/4360").map(\.id) == ["t-7"])
        #expect(PaletteSearch.rank(entries, query: "github.com/example-org/server/pull/436").map(\.id) == ["t-7", "p-1"])
        #expect(PaletteSearch.rank(entries, query: "example.slack.com/archives/C01").map(\.id) == ["t-7"])
    }

    @Test("紐づく URL より深い URL（/files・#discussion）を貼っても引ける。番号の続きの別の PR は引かない")
    func deeperURL() {
        var task = item("t-7", .task, "#7 通知の設定を直す")
        task.urls = ["https://github.com/Example-Org/server/pull/43"]
        #expect(PaletteSearch.rank([task], query: "https://github.com/Example-Org/server/pull/43/files").map(\.id) == ["t-7"])
        #expect(PaletteSearch.rank([task], query: "https://github.com/Example-Org/server/pull/43#discussion_r1").map(\.id) == ["t-7"])
        #expect(PaletteSearch.rank([task], query: "https://github.com/Example-Org/server/pull/4360").isEmpty)
    }

    @Test("「/」を含まない語では URL を見ない")
    func urlNeedsSlash() {
        var task = item("t-7", .task, "#7 通知の設定を直す")
        task.urls = ["https://github.com/Example-Org/server/pull/43"]
        #expect(PaletteSearch.rank([task], query: "github").isEmpty)
    }
}
