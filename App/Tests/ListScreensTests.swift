import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 一覧の画面（受信箱・PR）の、画面に出す文と行き先を組む処理
@MainActor
@Suite struct ListScreensTests {
    let machine = MachineID(rawValue: "m")
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: 通知

    func item(_ kind: InboxItem.Kind, group: InboxItem.Group = .waiting, id: String, title: String, task: Int? = 131) -> InboxItem {
        InboxItem(id: id, kind: kind, group: group, machine: machine, taskNumber: task, title: title, details: ["#131 受信箱を作り直す"], at: t0)
    }

    var ask: Ask {
        Ask(
            machine: machine, askID: 7, taskNumber: 131, docID: 3, status: .open,
            questions: [AskQuestion(id: "q1", question: "どちらにしますか", options: [AskOption(label: "A")]), AskQuestion(id: "q2", question: "x", options: [AskOption(label: "A")])],
            answers: nil, createdAt: t0, answeredAt: nil)
    }

    @Test("通知: 題は種別、本文は行の題。件数を題と本文の両方に入れない。補足はマシンとタスクの番号")
    func notificationContent() throws {
        let question = try #require(InboxNotification.make(item(.question(ask), id: "ask/7", title: "どちらにしますか（2問）"), machineName: "Mac Studio"))
        #expect(question.title == "質問" && question.body == "どちらにしますか（2問）" && question.subtitle == "Mac Studio・#131")
        #expect(question.url.absoluteString == "taskboard://task/m/131/doc/3" && question.itemID == "m/ask/7")
    }

    @Test("通知する種類: 設定に並ぶ種類（承認待ち・質問・CIの失敗・レビュー）だけ。CI成功・文書・取得の失敗・返事・定期起動の成功は鳴らさない")
    func loudKinds() {
        func notice(_ kind: PRNotice.Kind) -> InboxItem {
            item(.pullRequest(PRNotice(machine: machine, url: "https://github.com/o/r/pull/1", label: "o/r#1", title: "t", kind: kind, at: t0)), group: .notice, id: "pr/\(kind)", title: "t")
        }
        #expect(InboxNotification.make(notice(.approved), machineName: "")?.title == "承認済み")
        #expect(InboxNotification.make(notice(.ciPassed), machineName: "") == nil)
        #expect(InboxNotification.make(notice(.newReview), machineName: "") == nil)
        let doc = Document(machine: machine, docID: 1, taskNumber: 131, name: "a.md", format: .markdown, latestRev: 1, createdAt: t0, updatedAt: t0)
        #expect(InboxNotification.make(item(.document(doc), group: .notice, id: "doc", title: "a.md"), machineName: "") == nil)
        #expect(InboxNotification.make(item(.prSync(PRAccountStatus(host: "github.com", account: "a", error: "x")), group: .notice, id: "s", title: "t"), machineName: "") == nil)
        let schedule = Schedule(
            scheduleID: 1, machine: machine, name: "朝の棚卸し", enabled: true, rule: .interval(minutes: 60), cwd: "/tmp", kind: .claude, agentArgs: [],
            prompt: "", taskNumber: nil, overlap: .skip, createdAt: t0, updatedAt: t0)
        let run = ScheduleRun(id: 1, scheduleID: 1, scheduledAt: t0, trigger: .schedule, stage: .done, createdAt: t0)
        #expect(InboxNotification.make(item(.scheduleRun(schedule, run), group: .notice, id: "sched", title: "t"), machineName: "") == nil)
        let failed = ScheduleRun(id: 2, scheduleID: 1, scheduledAt: t0, trigger: .schedule, stage: .failed, error: "taskNotFound(12)", createdAt: t0)
        #expect(InboxNotification.make(item(.scheduleRun(schedule, failed), group: .notice, id: "sched-failed", title: "t"), machineName: "")?.title == "定期起動")
        let turn = PullRequestSummary.sample(machine: machine)
        #expect(InboxNotification.make(item(.pullRequestTurn(turn, .ciFailed), id: "prturn", title: "t"), machineName: "")?.title == "CI失敗")
        #expect(InboxNotification.make(item(.pullRequestTurn(turn, .reviewRequested), id: "prturn2", title: "t"), machineName: "")?.url.absoluteString.hasPrefix("taskboard://pr?url=") == true)
    }

    @Test("種別の名前: PRのレビュー依頼と文書のレビュー依頼を分ける")
    func kindLabels() {
        #expect(PRNotice.Kind.approved.label == "承認済み")
        #expect(PRNotice.Kind.reviewRequested.label != InboxItem.Kind.reviewRequest(ReviewRequest(machine: machine, taskNumber: 1, requestedAt: t0)).label)
    }

    // MARK: PR をアカウントごとに

    @Test("fixtures の 2 アカウント・2 台: 一覧はアカウントごとに 1 行、URL で引くと最後に更新された 1 件、レビュー依頼の数は同じ PR を 2 回数えない")
    func pullRequestsByAccount() async throws {
        let model = ListSnapshotTests.model(ListSnapshotTests.accounts)
        try await ListSnapshotTests.loaded(model, machines: 2)
        let fleet = model.fleet
        let mine = fleet.allPullRequests.filter { $0.account == "demo-work" }
        let bot = fleet.allPullRequests.filter { $0.account == "review-bot" }
        #expect(mine.map(\.number) == [310, 305, 301], "同じアカウントの 310 と 305 は 2 台が取っているが 1 行")
        #expect(mine.first { $0.number == 310 }?.machine.rawValue == "fixture-second", "新しく取れた Mac mini の分")
        #expect(mine.first { $0.number == 305 }?.machine.rawValue == "fixture-air", "新しく取れた MacBook Air の分")
        #expect(bot.map(\.category) == [.reviewRequested], "別のアカウントの 305 は自分の区分で残る")
        #expect(fleet.reviewRequestedCount == 2, "310 と 305")
        #expect(fleet.pullRequestsByURL.map(\.number) == [310, 305, 301])
        #expect(fleet.pullRequest(url: "https://github.com/example-org/api/pull/310")?.updatedAt == ISO8601DateFormatter().date(from: "2026-10-03T02:10:00Z"))
        #expect(fleet.pullRequest(url: "https://github.com/example-org/api/pull/305")?.machine.rawValue == "fixture-air")
        #expect(Set(fleet.machinesFetching(url: "https://github.com/example-org/api/pull/305").map(\.rawValue)) == ["fixture-second", "fixture-air"])
    }
}

extension PullRequestSummary {
    static func sample(machine: MachineID) -> PullRequestSummary {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        return PullRequestSummary(
            machine: machine, host: "github.com", account: "a", category: .myReady, url: "https://github.com/o/r/pull/1", repository: "o/r", number: 1,
            title: "t", author: "a", isDraft: false, headRef: "h", createdAt: t0, updatedAt: t0)
    }
}
