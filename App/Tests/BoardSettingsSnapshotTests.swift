import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 設定の［案件］の中身。fixtures `settings` の default（常設・足した列「検証」と、列の説明）を Mac の設定の幅で描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct BoardSettingsSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private static func scope() async throws -> (AppModel, SettingsBoardScope, Board) {
        let model = try await LaunchSnapshotTests.loadedModel("settings")
        let scope = try #require(model.settingsMachines.first)
        let board = try #require(scope.state.boards.values.first { $0.name == "default" })
        return (model, scope, board)
    }

    @Test("列の名前・説明・完了扱い・畳む・削除（完了だけ削除できない）", arguments: Matrix.cases([720]))
    func columns(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, scope, board) = try await Self.scope()
        let view = BoardDetailSettings(board: board, scope: scope, slack: Self.unconfigured).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1500), variant: appearance), named: name)
    }

    @Test("既定の列（レビュー依頼・デプロイ中）を消した案件: ［列を追加］が戻す先を選ぶメニューになり、マージしたら完了へ", arguments: Matrix.cases([720]))
    func removedStandardColumns(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, scope, board) = try await Self.scope()
        var trimmed = board
        trimmed.columns.removeAll { $0.id == "review_req" || $0.id == "deploying" }
        let view = BoardDetailSettings(board: trimmed, scope: scope, slack: Self.unconfigured).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1300), variant: appearance), named: name)
    }

    // MARK: Slack

    private static let unconfigured = SlackSettingsStatus(slack: BoardSlack(), channels: [])

    private static let channels = [SlackChannel(id: "C001", name: "taskboard-dev"), SlackChannel(id: "C002", name: "ops"), SlackChannel(id: "C003", name: "random")]

    private static func configured(_ connection: SlackConnection, members: [SlackMember]) -> SlackSettingsStatus {
        SlackSettingsStatus(
            slack: BoardSlack(
                configured: true, workspace: "Example Inc.", botName: "taskboard", allowedUsers: members,
                routes: [SlackRoute(channelID: "C001", channelName: "taskboard-dev", taskNumber: 137), SlackRoute(channelID: "C009", taskNumber: 131)],
                connection: connection),
            channels: channels)
    }

    private static let members = [SlackMember(id: "U0123ABCD", name: "渡辺 祐樹"), SlackMember(id: "W0456EFGH")]

    /// 案件の中身のうち Slack の区分だけを、案件の設定と同じ grouped Form の幅で描く
    private func slackSnapshot(_ status: SlackSettingsStatus, edit: (inout BoardSlackDraft) -> Void = { _ in }, name: String, height: CGFloat, testName: String = #function) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, scope, board) = try await Self.scope()
        var draft = status.slack.map(BoardSlackDraft.init)
        if draft != nil { edit(&draft!) }
        let tasks = SlackTaskChoice.choices(
            for: board, boards: model.orderedBoards(scope.state, fleetID: scope.fleetID, includeArchived: true), tasks: scope.state.tasks.values)
        let view = Form {
            BoardSlackSections(draft: .constant(draft), status: status, boardName: board.name, tasks: tasks, reload: {}, disconnect: {})
        }
        .formStyle(.grouped)
        .settingsContentWidth()
        .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: height), variant: appearance), named: name, testName: testName)
    }

    @Test("Slack 未設定: 2 つのトークンの欄。形の違うトークンは欄の下に示す", arguments: Matrix.cases([720, 390]))
    func slackUnconfigured(name: String) async throws {
        try await slackSnapshot(Self.unconfigured, edit: { $0.botToken = "xapp-test" }, name: name, height: 420)
    }

    @Test("Slack 設定済みでつながっている: ワークスペース・ボット・接続、受け付ける人、チャンネルの届け先（名前の取れないチャンネル）", arguments: Matrix.cases([720, 390]))
    func slackConnected(name: String) async throws {
        try await slackSnapshot(Self.configured(.connected, members: Self.members), name: name, height: 1000)
    }

    @Test("Slack 設定済みでつなげなかった: 理由と、トークンを入れ替える欄", arguments: Matrix.cases([720, 390]))
    func slackFailed(name: String) async throws {
        try await slackSnapshot(
            Self.configured(.failed(message: "Slackがトークンを受け付けませんでした。トークンを入れ替えてください。"), members: Self.members),
            edit: { $0.replacingTokens = true }, name: name, height: 1100)
    }

    @Test("Slack 受け付ける人が空: だれの依頼も届かないことを示す", arguments: Matrix.cases([720, 390]))
    func slackNoMembers(name: String) async throws {
        try await slackSnapshot(Self.configured(.connecting, members: []), name: name, height: 900)
    }
}
