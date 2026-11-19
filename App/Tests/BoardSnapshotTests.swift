import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// ボードとカードの見た目を PNG で固定する。fixtures `sessions-basic` のボードを、
/// ライト / ダーク / ライト + コントラストを上げる / ダーク + コントラストを上げる の 4 組で描く
/// （「透明度を下げる」はシステム設定で、環境値が read-only のためプロセス内から再現できない）。
/// 記録し直すときは `SNAPSHOT_TESTING_RECORD=all xcodebuild test ...`。
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct BoardSnapshotTests {
    /// 撮る部品の周りの余白
    static let margin: CGFloat = 16

    struct Variant: Sendable {
        let name: String
        let appearance: NSAppearance.Name
    }

    nonisolated static let variants: [Variant] = [
        Variant(name: "light", appearance: .aqua),
        Variant(name: "dark", appearance: .darkAqua),
        Variant(name: "light-increaseContrast", appearance: .accessibilityHighContrastAqua),
        Variant(name: "dark-increaseContrast", appearance: .accessibilityHighContrastDarkAqua),
    ]

    /// fixtures を読み、daemon に繋がない AppModel に載せる
    static func model() -> AppModel {
        // 設定は空の別の保存先から読む（ユーザーのアプリや、確かめ方で切り替えた開き方・表示を拾わない）
        AppDefaults.useScratch("snapshot")
        return AppModel(options: LaunchOptions(scenario: "sessions-basic"))
    }

    /// 窓に載せていない view の displayScale は 1 で、SwiftUI は部品を 1 pt に丸めて置く。ちょうど 0.5 pt にある辺は回によってどちらにも丸まり、
    /// 全体で回すと入力欄や選ぶ欄が 1 pt ずれた。PNG と同じ 2 倍を渡し、本物の Retina の窓と同じく 0.5 pt のまま置かせる
    nonisolated static let renderScale: CGFloat = 2

    /// 日数の表示（期日まで N 日・最後の動きから N 日）が実行日で変わらないように固定する
    nonisolated static let today = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00+09:00")!

    static func host(_ view: some View, size: CGSize, variant: Variant) -> NSView {
        let hosting = NSHostingView(
            rootView: view
                .defaultAppStorage(AppDefaults.store)
                .environment(\.today, today)
                // 相対時刻と利用枠の予測を `today` で描く（TimelineView の本物の「今」で描くと日付で画像が変わる）
                .environment(\.liveClock, false)
                .environment(\.defersMount, false)
                .frame(width: size.width, height: size.height)
                // cacheDisplay はウィンドウ背景を描かないので、PNG を見て分かるように敷く
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.displayScale, renderScale))
        hosting.appearance = NSAppearance(named: variant.appearance)
        hosting.frame = CGRect(origin: .zero, size: size)
        LayoutMatrixSnapshotTests.settle(hosting)
        return hosting
    }

    @Test(arguments: variants.map(\.name))
    func board(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        // FixtureSource の snapshot は非同期に入るので、ボードが載るまで待つ
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.tasks.isEmpty ?? true) }
        let board = model.fleet.allBoards[0]
        let view = NavigationStack { BoardView(board: board) }.environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 1400, height: 420), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func card(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.tasks.isEmpty ?? true) }
        let machine = model.fleet.allBoards[0].machine
        let state = try #require(model.fleet.machineState(for: machine))
        // 待ち理由の種類が揃う 3 枚: 承認待ちのセッション / 期日あり / 動いていない日数の札
        let numbers = [128, 118, 120]
        var cards = numbers.compactMap { state.tasks[TaskKey(machine: machine, number: $0)] }
        try #require(cards.count == numbers.count, "fixtures のタスク番号が変わった")
        // #120 は fixtures では未着手なので札が付かない。セッションを結んで着手済みにする（fixtures を直すとボードの画像も変わる）
        cards[2].sessions = [TaskSessionRef(id: 1, agent: "claude", sessionID: "sess-stalled", cwd: "/w", linkedAt: cards[2].updatedAt)]
        try #require(cards[2].stall(workItems: [], terminal: false, now: Self.today) != nil)
        let view = VStack(spacing: Space.row) {
            ForEach(cards) { task in
                TaskCard(task: task, signals: model.cardSignals(for: task), scheduleName: model.schedule(forTask: task.id)?.name)
            }
        }
        .padding(Self.margin)
        .environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 300, height: 360), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func workItems(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.workItems.isEmpty ?? true) }
        let machine = model.fleet.allBoards[0].machine
        // #137: 完了（成果物）/ 作業中 / 待ち（CI）/ 依存で未着手 / 着手できる（owner あり）/ 見送り が揃う
        let key = TaskKey(machine: machine, number: 137)
        let task = try #require(model.fleet.task(for: key), "fixtures のタスク番号が変わった")
        let items = model.fleet.workItems(for: key)
        try #require(items.count == 7, "fixtures の作業項目が変わった")
        let view = WorkItemList(task: task, items: items)
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
            .environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 420, height: 520), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func newTaskSheet(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty }
        let board = model.fleet.allBoards[0]
        // 列 review_req はテンプレートの上書きがあり、起動プロンプトにそれが出る
        var draft = NewTaskDraft(board: board)
        draft.title = "起票から起動までの確認"
        draft.columnID = "review_req"
        draft.launch.promptEdited = false
        draft.launch.applyTemplate(for: draft.columnID, in: board)
        draft.launch.cwd = "~/dev/8_tools/taskboard"
        let view = NewTaskSheet(draft: draft).environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 560, height: 1000), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func chat(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { model.fixtureExtras.conversations["c-transcript"] != nil }
        let messages = try #require(model.fixtureExtras.conversations["c-transcript"]?.messages, "fixtures に c-transcript の会話が無い")
        // 失敗した呼び出し（t2）は開いて結果まで見せる
        let view = ChatTranscript(messages: messages, expandedTools: ["t2"])
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 560, height: 900), variant: variant),
            named: variant.name)
    }

    /// 利用枠: マシン見出しのバーと、押すと出る表。fixtures の枠（5h 42% / 1w 57%、Codex のセッションがあるので Codex も）
    @Test(arguments: variants.map(\.name))
    func usage(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { model.fleet.usage.values.first != nil }
        let state = try #require(model.fleet.machines.values.first)
        let usage = try #require(model.fleet.usage.values.first)
        let view = VStack(alignment: .leading, spacing: Self.margin) {
            HStack {
                Text(state.machine?.name ?? "").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                MachineUsageBars(state: state)
            }
            .frame(width: 220)
            .environment(model)
            UsageTable(title: "Mac Studio の利用枠", rows: UsageText.rows(usage, now: Self.today), updatedAt: usage.claude?.at)
            Spacer()
        }
        .padding(Self.margin)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 460, height: 340), variant: variant),
            named: variant.name)
    }

    /// 定期起動: 開いた行（前回は起動した）と、停止中で前回が失敗した行
    @Test(arguments: variants.map(\.name))
    func scheduleList(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        let schedules = { model.fleet.allBoards.first.flatMap { model.fleet.machineState(for: $0.machine) }.map { Array($0.schedules.values) } ?? [] }
        try await waitUntil(model) { schedules().count == 2 }
        let morning = try #require(schedules().first { $0.scheduleID == 1 }, "fixtures の定期起動が変わった")
        let wiki = try #require(schedules().first { $0.scheduleID == 2 }, "fixtures の定期起動が変わった")
        let view = ScrollView {
            VStack(alignment: .leading, spacing: Space.row) {
                ScheduleRowView(schedule: morning, expanded: true, canEdit: true, toggle: {}, edit: {})
                ScheduleRowView(schedule: wiki, expanded: false, canEdit: true, toggle: {}, edit: {})
            }
            .padding(Self.margin)
        }
        .environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 720, height: 560), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func scheduleForm(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        let schedules = { model.fleet.allBoards.first.flatMap { model.fleet.machineState(for: $0.machine) }.map { Array($0.schedules.values) } ?? [] }
        try await waitUntil(model) { schedules().count == 2 }
        let morning = try #require(schedules().first { $0.scheduleID == 1 }, "fixtures の定期起動が変わった")
        let view = ScheduleForm(draft: ScheduleDraft(morning)).environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 560, height: 760), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func connections(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let info = { (name: String) in MachineInfo(id: MachineID(rawValue: name), name: name, daemonVersion: "t") }
        let view = VStack(spacing: Space.block) {
            ConnectionRow(name: "このMac", detail: nil, state: MachineState(machine: info("Work Mac"), connected: true))
            ConnectionRow(
                name: "Mac Studio", detail: "https://taskboard-studio.example.com", state: { var s = MachineState(machine: info("studio")); s.authFailure = .forbidden; return s }(),
                menu: ConnectionRow.Menu(canMoveUp: true, canMoveDown: true, move: { _ in }, setHidden: { _ in }, edit: {}, delete: {}))
            ConnectionRow(name: "Mac mini", detail: "https://taskboard-mini.example.com", state: { var s = MachineState(); s.authFailure = .unauthorized; return s }())
            ConnectionRow(name: "自宅", detail: "https://taskboard-home.example.com", state: MachineState(lastError: "The request timed out."), hidden: true)
            ConnectionRow(
                name: "検証機", detail: "https://taskboard-lab.example.com",
                state: {
                    var machine = info("lab")
                    machine.agentHost = AgentHostInfo(connected: false, draining: true, remaining: ["c1", "c2"])
                    return MachineState(machine: machine, connected: true)
                }())
            Spacer()
        }
        .padding(Self.margin)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 560, height: 560), variant: variant),
            named: variant.name)
    }

    @Test("タスク画面の右側の状態の欄（メモ・PR・止まったセッション）", arguments: variants.map(\.name))
    func sidePaneStatus(variantName: String) async throws {
        try await sidePane(task: 137, open: [.status], variantName: variantName)
    }

    @Test("タスク画面の右側の作業項目の欄", arguments: variants.map(\.name))
    func sidePaneWork(variantName: String) async throws {
        try await sidePane(task: 137, open: [.work], variantName: variantName)
    }

    @Test("タスク画面の右側の初めの欄（中身のある文書と作業項目。#120 は質問付きの文書）", arguments: variants.map(\.name))
    func sidePaneDocs(variantName: String) async throws {
        try await sidePane(task: 120, open: nil, variantName: variantName)
    }

    /// `open` はこの端末で開いている欄（nil なら人が選んでいない）
    private func sidePane(task number: Int, open: [SidePanel]?, variantName: String, testName: String = #function) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.documents.isEmpty ?? true) }
        AppDefaults.store.set(SidePanelSet(open: open).json, forKey: AppPreferences.taskSidePanelsKey)
        let key = TaskKey(machine: model.fleet.allBoards[0].machine, number: number)
        let task = try #require(model.fleet.task(for: key), "fixtures のタスク番号が変わった")
        let view = TaskSideArea(task: task, editable: true).environment(model).environment(\.taskScope, key)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 400, height: 640), variant: variant),
            named: variant.name, testName: testName)
    }

    @Test(arguments: variants.map(\.name))
    func documentList(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.documents.isEmpty ?? true) }
        let machine = model.fleet.allBoards[0].machine
        // #120: 質問付きの markdown と、未解決コメントのある html。上に判断待ち（質問 2 件）が並ぶ
        let key = TaskKey(machine: machine, number: 120)
        let task = try #require(model.fleet.task(for: key), "fixtures のタスク番号が変わった")
        let documents = model.fleet.documents(for: key)
        try #require(documents.count == 2, "fixtures の文書が変わった")
        let view = DocumentList(task: task, documents: documents).environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 340, height: 340), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func askForm(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty && !(model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.asks.isEmpty ?? true) }
        let machine = model.fleet.allBoards[0].machine
        let ask = try #require(model.fleet.machineState(for: machine)?.openAsk(forDoc: 1), "fixtures の質問が変わった")
        let view = ScrollView { AskForm(ask: ask).padding(Self.margin) }.environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 340, height: 560), variant: variant),
            named: variant.name)
    }

    /// codex の問い：選択肢の無い問いと、答えを伏せる問い
    @Test(arguments: variants.map(\.name))
    func askFormFreeAndSecret(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allBoards.isEmpty }
        let machine = model.fleet.allBoards[0].machine
        let questions = [
            AskQuestion(id: "scope", question: "どこまで直しますか", header: "範囲", options: [AskOption(label: "全部", description: "全ファイル"), AskOption(label: "一部")]),
            AskQuestion(id: "name", question: "ブランチの名前を入れてください", options: []),
            AskQuestion(id: "token", question: "トークンを入れてください", header: "鍵", options: [], isSecret: true),
        ]
        let view = ScrollView { AskForm(questions: questions, machine: machine) { _ in }.padding(Self.margin) }.environment(model)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 340, height: 560), variant: variant),
            named: variant.name)
    }

    @Test("タスク画面の右側の状態の欄の PR の節（リンクした PR の詳細）", arguments: variants.map(\.name))
    func sidePanePR(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = Self.model()
        try await waitUntil(model) { !model.fleet.allPullRequests.isEmpty }
        AppDefaults.store.set(SidePanelSet(open: [.status]).json, forKey: AppPreferences.taskSidePanelsKey)
        let task = try #require(
            model.fleet.allBoards.first.flatMap { board in model.fleet.machineState(for: board.machine)?.tasks.values.sorted { $0.number < $1.number }.first { !$0.pullRequestLinks.isEmpty } },
            "fixtures に PR をリンクしたタスクが無い")
        let view = TaskSideArea(task: task).environment(model).environment(\.taskScope, task.id)
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 440, height: 720), variant: variant),
            named: variant.name)
    }

    @Test(arguments: variants.map(\.name))
    func prDetail(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let t = Self.today
        let detail = PullRequestDetail(
            url: "https://github.com/ukwhatn/taskboard/pull/55", repository: "ukwhatn/taskboard", number: 55, title: "フェーズ 6: 受信箱と文書",
            author: "ukwhatn", state: "OPEN", isDraft: false, body: "## 概要\n文書・質問・レビューを **daemon** に持つ。`hook stop` で往復する。\n\n- 受信箱\n- 通知",
            baseRef: "main", headRef: "feature/phase6", createdAt: t, updatedAt: t, mergeable: "CONFLICTING", reviewDecision: "CHANGES_REQUESTED",
            checkState: .failure, additions: 2400, deletions: 120, changedFiles: 31,
            files: [
                .init(path: "Sources/TaskboardKit/Documents.swift", additions: 800, deletions: 0, changeType: "ADDED"),
                .init(path: "App/Sources/Views/RootView.swift", additions: 40, deletions: 12, changeType: "MODIFIED"),
            ],
            checks: [
                .init(name: "test", workflow: "CI", state: "FAILURE", url: "https://example.invalid/1"),
                .init(name: "lint", workflow: "CI", state: "SUCCESS"),
                .init(name: "deploy/preview", state: "IN_PROGRESS"),
            ],
            reviews: [.init(author: "dave", state: "CHANGES_REQUESTED", body: "`FeedbackService` の待機を見直してほしい", submittedAt: t)],
            commentCount: 3, fetchedAt: t)
        let task = BoardTask(machine: MachineID(rawValue: "m"), number: 120, boardID: "b", columnID: "review", title: "kairan の置き換え", createdAt: t, updatedAt: t)
        let work = WorkItem(
            machine: MachineID(rawValue: "m"), itemID: 4, taskNumber: 120, title: "Stop hook の往復を実装する", state: .doing, deliverableKind: .pr,
            deliverableRef: "https://github.com/ukwhatn/taskboard/pull/55", position: 0, source: "lead", createdAt: t, updatedAt: t)
        let view = PRDetailContent(detail: detail, linkedTasks: [task], linkedWork: [work])
        assertImageSnapshot(
            of: Self.host(view, size: CGSize(width: 560, height: 760), variant: variant),
            named: variant.name)
    }

    private func waitUntil(_ model: AppModel, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            let diagnosis = "connectionNote=\(model.connectionNote ?? "-") machines=\(model.fleet.machines.map { "\($0.key): connected=\($0.value.connected) error=\($0.value.lastError ?? "-") boards=\($0.value.boards.count) tasks=\($0.value.tasks.count)" })"
            try #require(ContinuousClock.now < deadline, "fixtures の読み込みを待ち切れなかった: \(diagnosis)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
