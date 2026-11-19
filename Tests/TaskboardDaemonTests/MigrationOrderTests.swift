import Foundation
import GRDB
import Testing

@testable import TaskboardDaemon

/// GRDB は migration を登録した順に回し、回したものを識別子で DB に記録する。版の番号の順ではない
@Suite("migration の順")
struct MigrationOrderTests {
    /// 新しい DB で回る順。並べ替えると、新しい DB と途中の版の DB で回る順が変わり、`migrate(_:upTo:)` で古い版の DB を作るテストも別の形を作る
    private static let order = [
        "v1 boards and tasks",
        "v2 work items",
        "v3 launches and prompt templates",
        "v4 documents, asks, reviews",
        "v5 pr cache",
        "v6 schedules",
        "v11 schedule run failures",
        "v7 board settings",
        "v12 board merge target",
        "v8 settings and session launch args",
        "v9 paired devices",
        "v13 device push",
        "v10 working directory bookmarks",
        "v14 column description and standing",
        "v15 inbox dismissal",
        "v16 conversations",
        "v17 conversation trims",
        "v18 conversation forks and terminals",
        "v19 conversation purposes and parents",
        "v20 feedback and session lookup indexes",
        "v21 link snapshots and notices",
        "v22 conversation stats",
        "v23 browser profiles",
        "v24 wakes",
        "v25 watches",
        "v26 watch tags",
        "v27 conversation session sources",
        "v28 conversation usage pauses",
        "v29 conversation custom titles",
        "v30 conversation network resumes",
        "v31 usage analytics",
        "v32 conversation rewind redo and fork points",
        "v33 conversation search",
        "v34 schedule runs without launches",
        "v35 conversations without panes",
        "v36 command watches",
        "v37 slack requests",
        "v38 conversation replies",
        "v39 ask work items",
        "v40 turn digests and requests",
        "v41 turn request options",
        "v42 finished manual work",
        "v43 delegation scope and records",
        "v44 work item groups and codes",
        "v45 task panels",
        "v46 briefings",
        "v47 link status cache",
        "v48 document drafts and inline asks",
    ]

    @Test("登録した順は、これまでに出した DB が回ってきた順と同じ。足すのは末尾だけ")
    func registeredInRunOrder() {
        #expect(Store.migrator().migrations == Self.order)
    }

    @Test("空の DB に回すと、登録した全部が登録した順に記録される")
    func appliesAllInOrder() throws {
        let queue = try DatabaseQueue()
        let migrator = Store.migrator()
        try migrator.migrate(queue)
        #expect(try queue.read { try migrator.appliedMigrations($0) } == Self.order)
    }
}
