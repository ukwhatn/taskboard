import Foundation
import Testing

@testable import TaskboardKit

/// daemon とアプリの間の JSON の形を固める。控え（`Wire/*.json`）を読んで書き直すと、同じ JSON に戻ること。
/// 欄・CodingKeys・raw value・既定値を足したり消したり変えたりすると落ちる。wire を変えると決めたときだけ
/// `TASKBOARD_WIRE_RECORD=1 swift test --filter WireFreezeTests` で控えを作り直し、差分を見てからコミットする
@Suite("wire の形")
struct WireFreezeTests {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Wire")
    private static let appFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Fixtures")

    private static func encoder() -> JSONEncoder {
        let e = WireJSON.encoder()
        e.outputFormatting.insert(.prettyPrinted)
        return e
    }

    /// 控えを読み、書き直した JSON が控えと同じかを見る。控えが無いか記録を頼まれたら、`make` の値で控えを作って落とす
    private func check<T: Codable & Equatable>(_ name: String, _ type: T.Type, make: () throws -> T) throws {
        let file = Self.directory.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["TASKBOARD_WIRE_RECORD"] == "1" || !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try Self.encoder().encode(try make()).write(to: file)
            Issue.record("\(name) の控えを作った。中身を見てからコミットする")
            return
        }
        let golden = try Data(contentsOf: file)
        let decoded = try WireJSON.decoder().decode(T.self, from: golden)
        let again = try Self.encoder().encode(decoded)
        #expect(String(decoding: again, as: UTF8.self) == String(decoding: golden, as: UTF8.self), "\(name) を読んで書き直すと形が変わる")
        #expect(try WireJSON.decoder().decode(T.self, from: again) == decoded)
    }

    private static func fixture(_ name: String) throws -> StateSnapshot {
        try WireJSON.decoder().decode(StateSnapshot.self, from: Data(contentsOf: appFixtures.appendingPathComponent("\(name).json")))
    }

    @Test("全体の様子（会話・セッション・タスク・PR・利用枠・定期起動・オーケストレーター、設定）")
    func snapshots() throws {
        try check("state-conversations.json", StateSnapshot.self) { try Self.fixture("conversations") }
        try check("state-settings.json", StateSnapshot.self) { try Self.fixture("settings") }
    }

    @Test("出来事（種類ごとに 1 つ）")
    func events() throws {
        try check("events.json", [DaemonEvent].self) {
            let s = try Self.fixture("conversations")
            let settings = try Self.fixture("settings")
            var conversation = try #require(s.conversations.first { $0.stats != nil })
            conversation.lastReply = ConversationReply(text: "テストを通しました。", at: s.generatedAt)
            conversation.turnStartedAt = s.generatedAt.addingTimeInterval(-90)
            return [
                .stateSnapshot(StateSnapshot(machine: s.machine, generatedAt: s.generatedAt)),
                .machineUpdated(s.machine),
                .boardUpdated(try #require(s.boards.first)), .boardRemoved(try #require(s.boards.first).id),
                .taskUpdated(try #require(s.tasks.first)), .taskRemoved(try #require(s.tasks.first).id),
                .workUpdated(try #require(s.workItems.first)), .workRemoved(try #require(s.workItems.first).id),
                .docUpdated(try #require(s.documents.first)), .docRemoved(try #require(s.documents.first).id),
                .askUpdated(try #require(s.asks.first)), .reviewRequestUpdated(try #require(s.reviewRequests.first)),
                .reviewRequestRemoved(try #require(s.reviewRequests.first).id), .prsUpdated(try #require(s.prs)), .usageUpdated(try #require(s.usage)),
                .linksUpdated(s.links), .scheduleUpdated(try #require(s.schedules.first)), .scheduleRemoved(try #require(s.schedules.first).id),
                .settingsUpdated(try #require(settings.settings)), .orchestratorUpdated(try #require(s.orchestrator)), .devicesUpdated([]),
                .inboxDismissalsUpdated(s.inboxDismissals), .conversationUpdated(conversation), .conversationRemoved(conversation.key),
                .wakeUpdated(
                    Wake(
                        wakeID: 3, machine: s.machine.id, at: s.generatedAt.addingTimeInterval(3600), prompt: "デプロイの結果を確かめる",
                        taskNumber: try #require(s.tasks.first).number, closesCreator: true, createdBy: conversation.id, state: .failed,
                        failure: "タスクがありません", createdAt: s.generatedAt, updatedAt: s.generatedAt)),
                .wakeRemoved(WakeKey(machine: s.machine.id, id: 3)),
                .watchUpdated(
                    Watch(
                        watchID: 4, machine: s.machine.id, url: "https://github.com/o/r/pull/12", events: [.merged, .checksFailed],
                        conversationID: conversation.id, prompt: "マージされたらデプロイを確かめる", once: true, expiresAt: s.generatedAt.addingTimeInterval(86400),
                        state: .ended, ending: .delivered, error: "gh が PATH に無い", fetchedAt: s.generatedAt, createdBy: conversation.id, createdAt: s.generatedAt,
                        updatedAt: s.generatedAt)),
                .watchRemoved(WatchKey(machine: s.machine.id, id: 4)),
                .conversationActivity(ConversationToolActivity(conversation: conversation.key, toolName: "Bash")),
                .panelUpdated(
                    OverviewPanel(
                        machine: s.machine.id, taskNumber: try #require(s.tasks.first).number,
                        parts: [
                            PanelPart(
                                spec: PanelPartSpec(
                                    id: "answers",
                                    content: .gauge(PanelGauge(label: "回答", value: "4", amount: 4, basis: PanelBasis(kind: .denominator, value: "6", amount: 6), tone: .attention)),
                                    place: .band),
                                updatedAt: s.generatedAt, updatedTurn: 1),
                            PanelPart(spec: PanelPartSpec(id: "plan", content: .plan(PanelPlan(groups: ["M3"])), bind: PanelBinding(source: .work)), updatedAt: s.generatedAt, updatedTurn: 0),
                            PanelPart(
                                spec: PanelPartSpec(id: "notice", content: .draft(PanelDraft(to: "フォーラム", body: "改定しました。", checks: [PanelCheck(label: "敬体", ok: true)])), place: .composer),
                                updatedAt: s.generatedAt, updatedTurn: 1,
                                answer: PanelDraftAnswer(answerID: 2, body: "改定しました。", edited: false, answeredAt: s.generatedAt)),
                        ], turn: 3, updatedAt: s.generatedAt)),
                .panelRemoved(try #require(s.tasks.first).id),
            ]
        }
    }

    @Test("Claude Code のモデルの一覧（GET /v1/claude。effort の無いモデルと、まだ一覧を受けていない daemon）")
    func claudeModels() throws {
        try check("claude.json", [ClaudeMachineInfo].self) {
            [
                ClaudeMachineInfo(
                    models: [
                        .init(
                            value: "opus", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus 5.5", description: "Opus 5.5 with 1M context",
                            efforts: ["low", "medium", "high", "xhigh", "max"]),
                        .init(value: "claude-haiku-4-5-20251001", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", efforts: nil),
                    ], version: "2.1.304", readAt: Date(timeIntervalSince1970: 1_792_500_000)),
                ClaudeMachineInfo(models: nil),
            ]
        }
    }

    @Test("再開の結果")
    func resume() throws {
        try check("resume.json", [SessionResumeResult].self) {
            let s = try Self.fixture("conversations")
            return [SessionResumeResult(conversation: try #require(s.conversations.first))]
        }
    }
}
