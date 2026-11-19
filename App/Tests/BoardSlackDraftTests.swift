import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 案件の設定の Slack: 保存で `updateBoardSlack` に渡す中身と、保存の前に止める誤り
@MainActor
@Suite struct BoardSlackDraftTests {
    private static let configured = BoardSlack(
        configured: true, workspace: "example", botName: "taskboard",
        allowedUsers: [SlackMember(id: "U001", name: "山田"), SlackMember(id: "U002")],
        routes: [SlackRoute(channelID: "C001", channelName: "dev", taskNumber: 12)], connection: .connected)

    private static func settings(_ slack: BoardSlack) -> BoardSettingsDraft {
        var draft = BoardSettingsDraft(
            Board(id: "b1", machine: MachineID(rawValue: "m1"), name: "taskboard", position: 0, columns: [], createdAt: Date(timeIntervalSince1970: 0)))
        draft.slack = BoardSlackDraft(slack)
        return draft
    }

    @Test("読み込んだままなら送らない。設定済みで［トークンを入れ替える］を押しただけでも送らない")
    func untouchedSendsNothing() {
        let baseline = Self.settings(Self.configured)
        var draft = baseline
        #expect(draft.slackRequest(from: baseline) == nil)
        draft.slack?.replacingTokens = true
        #expect(draft.slackRequest(from: baseline) == nil)
        #expect(!draft.differs(from: baseline))
    }

    @Test("人を消すと token は nil のまま、人と対応表の全件を送る")
    func membersWithoutTokens() {
        let baseline = Self.settings(Self.configured)
        var draft = baseline
        draft.slack?.members.removeAll { $0.id == "U001" }
        #expect(draft.differs(from: baseline))
        #expect(!draft.boardDiffers(from: baseline), "Slack だけの変更で案件の更新は送らない")
        #expect(
            draft.slackRequest(from: baseline)
                == BoardSlackUpdate(botToken: nil, appToken: nil, allowedUsers: ["U002"], routes: [SlackRouteUpdate(channelID: "C001", taskNumber: 12)]))
    }

    @Test("未設定の案件で 2 つの token を入れると、前後の空白を除いて送る")
    func tokensOnUnconfigured() {
        let baseline = Self.settings(BoardSlack())
        var draft = baseline
        draft.slack?.botToken = " xoxb-test "
        draft.slack?.appToken = "xapp-test\n"
        #expect(draft.slack?.hasIssue == false)
        #expect(draft.slackRequest(from: baseline) == BoardSlackUpdate(botToken: "xoxb-test", appToken: "xapp-test", allowedUsers: [], routes: []))
    }

    @Test("設定済みで入れ替えるときは、token と今の人・対応表を一緒に送る")
    func replaceTokens() {
        let baseline = Self.settings(Self.configured)
        var draft = baseline
        draft.slack?.replacingTokens = true
        draft.slack?.botToken = "xoxb-new"
        draft.slack?.appToken = "xapp-new"
        let request = draft.slackRequest(from: baseline)
        #expect(request?.botToken == "xoxb-new")
        #expect(request?.appToken == "xapp-new")
        #expect(request?.allowedUsers == ["U001", "U002"])
        #expect(request?.routes == [SlackRouteUpdate(channelID: "C001", taskNumber: 12)])
    }

    @Test("token の形が違うか片方だけなら保存の前に止め、誤りは該当する欄に出す")
    func tokenIssues() {
        var slack = BoardSlackDraft(BoardSlack())
        #expect(!slack.hasIssue, "空のままは誤りにしない")
        slack.botToken = "xapp-wrong"
        #expect(slack.botTokenIssue == "「xoxb-」で始まるトークンを入力してください。")
        #expect(slack.appTokenIssue == "トークンを2つとも入力してください。")
        #expect(slack.hasIssue)
        slack.botToken = "xoxb-test"
        slack.appToken = "xoxb-test"
        #expect(slack.botTokenIssue == nil)
        #expect(slack.appTokenIssue == "「xapp-」で始まるトークンを入力してください。")
    }

    @Test("メンバーIDは U か W で始まる英大文字と数字だけ足せ、同じ ID は足さない")
    func addMember() {
        var slack = BoardSlackDraft(Self.configured)
        #expect(slack.memberIssue("") == nil)
        #expect(slack.memberIssue("u003") != nil)
        #expect(slack.memberIssue("C003") != nil)
        let duplicate = slack.addMember(" U001 ")
        let added = slack.addMember(" W003\n")
        #expect(!duplicate)
        #expect(added)
        #expect(slack.members.map(\.id) == ["U001", "U002", "W003"])
    }

    @Test("同じチャンネルに届け先を足すと、行を増やさずタスクを置き換える")
    func setRouteReplaces() {
        var slack = BoardSlackDraft(Self.configured)
        slack.setRoute(SlackChannel(id: "C001", name: "dev"), taskNumber: 30)
        slack.setRoute(SlackChannel(id: "C002", name: "ops"), taskNumber: 31)
        #expect(slack.routes.map(\.taskNumber) == [30, 31])
    }

    @Test("Slack を読み終える前は、Slack の変更を送らない")
    func notLoaded() {
        var baseline = Self.settings(BoardSlack())
        baseline.slack = nil
        #expect(baseline.slackRequest(from: baseline) == nil)
        #expect(!baseline.differs(from: baseline))
    }
}

/// チャンネルの届け先に選べるタスク: 同じワークスペースのほかの案件のチャンネルも 1 つのアプリで受ける
@MainActor
@Suite struct SlackTaskChoiceTests {
    private static let machine = MachineID(rawValue: "m1")
    private static let epoch = Date(timeIntervalSince1970: 0)

    private static func board(_ id: String, archived: Bool = false) -> Board {
        Board(
            id: id, machine: machine, name: id.uppercased(), position: 0,
            columns: [BoardColumn(id: "todo", label: "未着手", kind: .open, position: 0), BoardColumn(id: "done", label: "完了", kind: .terminal, position: 1)],
            createdAt: epoch, archived: archived)
    }

    private static func task(_ number: Int, _ board: String, column: String = "todo") -> BoardTask {
        BoardTask(machine: machine, number: number, boardID: board, columnID: column, title: "t\(number)", createdAt: epoch, updatedAt: epoch)
    }

    @Test("設定している案件のタスクを先に、ほかの案件を並びの順に続ける。各案件の中は新しい番号から")
    func ordersCurrentBoardFirst() {
        let das = Self.board("das"), hr = Self.board("hr")
        let choices = SlackTaskChoice.choices(for: hr, boards: [das, hr], tasks: [Self.task(1, "das"), Self.task(5, "das"), Self.task(3, "hr"), Self.task(4, "hr")])
        #expect(choices.map(\.number) == [4, 3, 5, 1])
        #expect(choices.map(\.boardName) == ["HR", "HR", "DAS", "DAS"])
    }

    @Test("終わりの列のタスクと、アーカイブした案件のタスクは選べない（表にあれば題は出す）")
    func terminalAndArchivedAreNotSelectable() {
        let current = Self.board("das"), old = Self.board("old", archived: true)
        let choices = SlackTaskChoice.choices(
            for: current, boards: [current, old], tasks: [Self.task(1, "das"), Self.task(2, "das", column: "done"), Self.task(3, "old")])
        #expect(choices.filter(\.selectable).map(\.number) == [1])
        #expect(choices.map(\.number) == [2, 1, 3])
    }
}
