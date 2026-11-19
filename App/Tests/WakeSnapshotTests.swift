import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 再開の予定と PR・issueの監視。fixtures `wakes` の #128 に、止まった会話 c-rewind・終了した会話 c-done・動いている会話 c-live と、
/// 予定（待ち・理由付きの待ち・失敗・届けた）と監視（タグ待ち・取れていない・repo・タグに入った・取り消した）がある
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct WakeSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    static func loadedModel() async throws -> AppModel {
        let model = try await LaunchSnapshotTests.loadedModel("wakes")
        try #require(model.fleet.machineState(for: LaunchSnapshotTests.machine(model))?.wakes.isEmpty == false, "fixtures wakes に予定が無い")
        return model
    }

    static func task(_ model: AppModel) throws -> BoardTask {
        try #require(model.fleet.task(for: TaskKey(machine: LaunchSnapshotTests.machine(model), number: 128)), "fixtures のタスク番号が変わった")
    }

    @Test("右側の状態の欄の再開の予定と監視（失敗・理由付きの待ち・取れていない・タグに入った）と、終了した会話の予定の時刻", arguments: Matrix.cases([420]))
    func statusSections(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let task = try Self.task(model)
        AppDefaults.store.set(SidePanelSet(open: [.status]).json, forKey: AppPreferences.taskSidePanelsKey)
        let view = TaskSideArea(task: task, editable: false).environment(model).environment(\.taskScope, task.id).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    @Test("iPhone の会話の行に添える予定の時刻（止まった会話だけ。動いている会話には添えない）", arguments: Matrix.cases([390]))
    func conversationRows(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let conversations = try ["c-rewind", "c-live"].map { id in
            try #require(model.fleet.conversation(for: ConversationKey(machine: LaunchSnapshotTests.machine(model), id: id)))
        }
        let view = VStack(alignment: .leading, spacing: Space.block) {
            ForEach(conversations) { conversation in
                ConversationLinkRow(conversation: conversation)
            }
        }
        .padding(Space.card).frame(maxHeight: .infinity, alignment: .top).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 280), variant: appearance), named: name)
    }
}

@MainActor
@Suite("再開の予定と監視の引き方")
struct WakeListingTests {
    @Test("タスクの予定は、タスク宛てとタスクの会話宛ての待ちと失敗を時刻の早い順に。届けたものは出さない")
    func wakesOfTask() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let task = try WakeSnapshotTests.task(model)
        #expect(model.wakes(forTask: task.id).map(\.wakeID) == [3, 2, 1, 4])
    }

    @Test("タスクの監視は、続いているものとタグに入って終えたものを作った順に。取り消したものは出さない")
    func watchesOfTask() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let task = try WakeSnapshotTests.task(model)
        #expect(model.watches(forTask: task.id).map(\.watchID) == [1, 2, 3, 4, 6])
    }

    @Test("会話の行の予定は、止まった会話のいちばん早い待ちだけ。失敗したものと、動いている会話には添えない")
    func nextWake() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let machine = LaunchSnapshotTests.machine(model)
        func next(_ id: String) throws -> Int64? {
            model.nextWake(for: try #require(model.fleet.conversation(for: ConversationKey(machine: machine, id: id))))?.wakeID
        }
        #expect(try next("c-rewind") == 1)
        #expect(try next("c-done") == 4)
        #expect(try next("c-live") == nil)
    }

    @Test("予定の行の理由は、失敗なら原因だけ（事象は題が言う）、待っているなら試し直している様子。原因の分からない失敗には添えない")
    func wakeNotes() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let wakes = model.wakes(forTask: try WakeSnapshotTests.task(model).id)
        #expect(wakes.map { WakeRow.note($0)?.text } == ["24時間、会話の生成か質問への回答が終わりませんでした。", "タスクのセッションが応答待ちになるのを待っています。", nil, nil])
        #expect(WakeRow.failureCause(.gaveUp(.resumeFailed)) == nil)
        #expect(WakeRow.failureCause(.unexpected("前の版の文")) == nil)
        #expect(WakeRow.retryNote(.unexpected("前の版の文")) == nil)
    }

    @Test("監視の行の題と条件。GHES の PR も「repo#番号」、repo は検索条件を添える")
    func watchTexts() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let task = try WakeSnapshotTests.task(model)
        let watches = model.watches(forTask: task.id)
        #expect(watches.map(WatchRow.title) == ["console#552", "taskboard#42", "console/consoleの新しいPR・issue", "taskboard#40", "curl -fsS https://status.example.com/deploy"])
        #expect(WatchRow.meta(watches[0], conversation: nil, now: BoardSnapshotTests.today) == ["タグ「v*-prod」待ち"])
        #expect(WatchRow.meta(watches[2], conversation: nil, now: BoardSnapshotTests.today) == ["検索条件：label:security"])
        #expect(WatchRow.meta(watches[3], conversation: nil, now: BoardSnapshotTests.today).isEmpty)
        #expect(WatchRow.note(watches[3])?.text == "タグ「v1.2.0-prod」に入りました")
        #expect(WatchRow.note(watches[1])?.text == "取得できませんでした。自動でやり直します。")
    }

    @Test("コマンドの監視の行は、コマンドの 1 行目を題に、条件と間隔を添える。起動の失敗はコマンドの失敗として出す")
    func commandWatchTexts() async throws {
        let model = try await WakeSnapshotTests.loadedModel()
        let watch = try #require(model.watches(forTask: try WakeSnapshotTests.task(model).id).first { $0.watchID == 6 })
        #expect(WatchRow.title(watch) == "curl -fsS https://status.example.com/deploy")
        #expect(WatchRow.meta(watch, conversation: nil, now: BoardSnapshotTests.today) == ["出力が「deployed」に合ったら", "30分ごと"])
        #expect(WatchRow.note(watch)?.text == "コマンドを起動できませんでした。自動でやり直します。")
        #expect(WatchRow.interval(45) == "45秒ごと")
        #expect(WatchRow.interval(7_200) == "2時間ごと")
        #expect(WatchRow.interval(5_400) == "90分ごと")
    }
}
