import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// チャットの Markdown の描画と検索の強調を PNG で固定する。ライト / ダークの 2 組。
/// 記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatMarkdownSnapshotTests {
    nonisolated static let variants: [BoardSnapshotTests.Variant] = BoardSnapshotTests.variants.filter { ["light", "dark"].contains($0.name) }

    static let reply = """
        ## 調査の結果

        原因は **2 つ**ある。`ChatFeed` の再接続と、表の *列幅（column width）*。詳しくは [README](https://example.com) を見る。

        ### 対応

        1. 再接続を 3 秒おきにする
        2. 表を `Grid` で描く
           - 列の幅を揃える
           - 横に長い表はスクロール
        3. 確認する

        - [x] パーサーを書く
        - [ ] snapshot を見る

        | 項目 | 件数 | 状態 |
        |:---|---:|:---:|
        | 認証 | 12 | **完了** |
        | 決済の画面と通知のまとめ直し | 3 | `doing` |
        | taskboard | 1024 | 待ち |

        ```swift
        let blocks = MarkdownBlocks.parse(text)
        ```

        > 補足: 閉じていないコードの塊は末尾までをコードにする

        ---

        以上。
        """

    static let messages = [
        ChatMessage(id: "u1", role: .user, kind: .text, text: "表の描画が崩れる原因を調べて"),
        ChatMessage(id: "c1", role: .assistant, kind: .toolUse, text: "rg -n ChatFeed App/Sources", toolName: "Bash", toolID: "t1"),
        ChatMessage(id: "r1", role: .user, kind: .toolResult, text: "App/Sources/Views/ChatView.swift:7:final class ChatFeed {", toolID: "t1"),
        ChatMessage(id: "a1", role: .assistant, kind: .text, text: reply),
    ]

    @Test(arguments: variants.map(\.name))
    func chatMarkdown(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: Self.messages)
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 1000), variant: variant),
            named: variant.name)
    }

    /// 折り返す長いセルの表。行の高さが折り返した文に合い、隣の行に重ならない（実画面で重なっていた）
    static let wideTable = """
        ## 開発中の中心：エージェント作業管理

        | ツール | 中身 | 状態 |
        |---|---|---|
        | `taskboard/` | herdr を engine にしたタスクボード。Swift 製で、Mac ごとに常駐する daemon と Mac / iPad / iPhone アプリからなる。CLI に MCP サーバー(tool 21 個)・hook・taskherd 取り込みを持つ | 最終コミット 10/06。main に直コミットする運用。設計資料は `.local/memory/261002_taskboard-native-client/` |
        | `taskboard-wt/` | taskboard の worktree 4 本 | chat ／ cols ／ inbox ／ prs。4 本とも 10/06 にコミットあり |
        | `taskherd/` | 前身。Claude Code 向けの TUI kanban で、タスクを JSON 1 枚に置き、セッション・PR・Jira を紐づける | v0.1.1 |
        | `herdr/` | コードは無い。taskherd の設計メモリと issue 1 件だけ | `herdr/.local/memory/260824_herdr-task-manager/` |

        ## MCP サーバー（`mcp/`）
        """

    @Test(arguments: variants.map(\.name))
    func chatWideTable(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: [ChatMessage(id: "w1", role: .assistant, kind: .text, text: Self.wideTable)])
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view, size: CGSize(width: 900, height: 700), variant: variant),
            named: variant.name)
    }

    /// iPhone・iPad の一覧（SwiftUI）の表。セルごとの地（見出しは濃く）、線なし、揃え（左・右・中）、折り返す長いセル。
    /// Mac 上に載せて、iPhone の幅と文字の大きさ（16pt）で撮る。行内のコードの地は `TextRenderer` で描くので写らない
    static let phoneTables = """
        | 項目 | 件数 | 状態 |
        |:---|---:|:---:|
        | 認証 | 12 | **完了** |
        | 決済の画面と通知のまとめ直し | 3 | `doing` |
        | taskboard | 1024 | 待ち |

        | ツール | 中身 |
        |---|---|
        | `taskherd/` | 前身。Claude Code 向けの TUI kanban で、タスクを JSON 1 枚に置き、セッション・PR・Jira を紐づける |
        """

    @Test(arguments: variants.map(\.name))
    func phoneTable(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        // 会話の一覧と同じく、縦は中身の高さにする（高さを渡すと、行の高さに揃えるセルの地が渡した高さまで伸びる）
        let view = MarkdownView(Self.phoneTables, style: .sized(16))
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.block)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 390, height: 420), variant: variant), named: variant.name)
    }

    /// diff の塊。足した行・消した行の地と印の色、hunk と見出しの薄い色。hunk の中の `--` で始まる行は消した行
    static let diffReply = """
        直す差分。

        ```diff
        diff --git a/App/Sources/Feed.swift b/App/Sources/Feed.swift
        --- a/App/Sources/Feed.swift
        +++ b/App/Sources/Feed.swift
        @@ -10,4 +10,4 @@ final class ChatFeed {
             func reconnect() {
        -        retry(after: 1)
        +        retry(after: 3) // 再接続は 3 秒おき
        ---  古い注記
             }
        ```
        """

    @Test(arguments: variants.map(\.name))
    func chatDiff(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: [ChatMessage(id: "d1", role: .assistant, kind: .text, text: Self.diffReply)])
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 360), variant: variant), named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func phoneDiff(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let view = MarkdownView(Self.diffReply, style: .sized(16))
            .fixedSize(horizontal: false, vertical: true)
            .padding(Space.block)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 390, height: 360), variant: variant), named: variant.name)
    }

    /// 検索の欄と一致の強調。一致は畳んだツールの結果にもあり、今の一致は開いて見せる
    @Test(arguments: variants.map(\.name))
    func chatSearch(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let search = ChatSearch(isOpen: true, query: "chatfeed", position: 0)
        let view = ChatSearchHarness(search: search, messages: Self.messages)
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 1000), variant: variant),
            named: variant.name)
    }
}

private struct ChatSearchHarness: View {
    @State var search: ChatSearch
    let messages: [ChatMessage]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ChatView と同じく、検索の欄は会話と同じ列に置く
            ChatSearchBar(search: $search, messages: messages, size: SessionTextSize.chatDefault, focused: $focused)
                .readableColumn()
                .padding(.horizontal, 20)
            Divider()
            ChatTranscript(messages: messages, search: search)
        }
    }
}
