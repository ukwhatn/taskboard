import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// タスクの編集（題・メモ・リンク・紐づける会話）の判断。fixtures `stress`（題・リンク）と `conversations`（紐づける会話）
@MainActor
@Suite struct TaskEditingTests {
    private let machine = MachineID(rawValue: "fixture-studio")

    private func model(_ scenario: String = "stress") async throws -> AppModel {
        AppDefaults.useScratch("test-task-editing")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.task(for: task(137)) == nil {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    private func task(_ number: Int) -> TaskKey { TaskKey(machine: machine, number: number) }

    // MARK: 題

    @Test("題は前後の空白を落として保存し、空白だけなら保存しない（起票と同じ）")
    func normalizedTitle() {
        #expect(AppModel.normalizedTitle("  iPad の殻を切る  ") == "iPad の殻を切る")
        #expect(AppModel.normalizedTitle("Fix CI") == "Fix CI")
        #expect(AppModel.normalizedTitle("") == nil)
        #expect(AppModel.normalizedTitle("   ") == nil)
        #expect(AppModel.normalizedTitle("\u{3000}") == nil)
    }

    @Test("その場の編集の確定: 前後の空白を落として保存し、空白だけと元のままなら送らない")
    func titleChange() {
        #expect(AppModel.titleChange(" Fix CI ", from: "Fix flaky CI") == "Fix CI")
        #expect(AppModel.titleChange("Fix CI", from: "Fix CI") == nil)
        #expect(AppModel.titleChange("  Fix CI", from: "Fix CI") == nil)
        #expect(AppModel.titleChange("", from: "Fix CI") == nil)
        #expect(AppModel.titleChange("\u{3000}", from: "Fix CI") == nil)
        #expect(AppModel.titleChange("iPad の殻を切る", from: "Fix CI") == "iPad の殻を切る")
    }

    // MARK: リンク

    @Test("足すリンク: 行を空白と改行で分け、空の行・このタスクにもうある URL・重ねて書いた URL を除く。並びは書いた順")
    func newLinks() async throws {
        let model = try await model()
        let task128 = try #require(model.fleet.task(for: task(128)))
        let existing = try #require(task128.links.first?.url)
        let jira = "https://example.atlassian.net/browse/PROJ-1297"
        let pr = "https://github.com/ukwhatn/taskboard/pull/99"
        #expect(AppModel.newLinks(["  \(pr)  ", "", existing, "\(jira)\n\(pr)", ""], existing: task128.links) == [pr, jira])
        #expect(AppModel.newLinks([""], existing: task128.links).isEmpty)
        #expect(AppModel.newLinks(["\(pr) \(jira)"], existing: []) == [pr, jira])
    }

    // MARK: 会話

    @Test("紐づけられる会話: 同じマシンのタスクなしの会話のうち、終了したもの・オーケストレーターを除く。新しく作った順")
    func linkCandidates() async throws {
        let model = try await model("conversations")
        let task137 = try #require(model.fleet.task(for: task(137)))
        let ids = model.linkCandidates(for: task137).map(\.id)
        #expect(ids.contains("c-stop") && ids.contains("c-files"))
        #expect(!ids.contains("c-orch"), "オーケストレーター")
        #expect(!ids.contains("c-gen") && !ids.contains("c-perm"), "タスクに結ばれている")
        let candidates = model.linkCandidates(for: task137)
        #expect(candidates.map(\.createdAt) == candidates.map(\.createdAt).sorted(by: >))
    }

    @Test("表示用のデータ（fixtures）のタスクには編集の項目を出さない")
    func editHiddenForFixtures() async throws {
        let model = try await model()
        let task137 = try #require(model.fleet.task(for: task(137)))
        #expect(!model.canWrite(task137.machine))
    }
}
