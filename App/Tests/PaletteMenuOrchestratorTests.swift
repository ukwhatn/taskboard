import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 利用枠の文字（docs/ui-copy.md の期間と表記）
@Suite struct UsageTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("残り時間は「N時間M分後」、1時間未満は「M分後」、過ぎた時刻は「0分後」、無ければ空白")
    func reset() {
        #expect(UsageText.reset(now.addingTimeInterval(2 * 3600 + 13 * 60 + 30), longWindow: false, now: now) == "2時間13分後")
        #expect(UsageText.reset(now.addingTimeInterval(13 * 60), longWindow: false, now: now) == "13分後")
        #expect(UsageText.reset(now.addingTimeInterval(-60), longWindow: false, now: now) == "0分後")
        #expect(UsageText.reset(nil, longWindow: false, now: now) == "")
        #expect(UsageText.reset(nil, longWindow: true, now: now) == "")
    }

    @Test("長い窓は日時を「M/d（曜日）HH:mm」で出す")
    func resetLongWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 0)))
        #expect(UsageText.reset(date, longWindow: true, now: now) == "10/6（火）09:00")
    }

    @Test("窓の長さは週・日・時間の日本語。長さが無ければ「利用枠」")
    func windowLabel() {
        #expect(UsageText.windowLabel(UsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: 18_000)) == "5時間")
        #expect(UsageText.windowLabel(UsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: 604_800)) == "1週間")
        #expect(UsageText.windowLabel(UsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: 172_800)) == "2日")
        #expect(UsageText.windowLabel(UsageWindow(usedPercent: 0, resetsAt: nil, windowSeconds: 0)) == "利用枠")
        #expect(UsageText.windowLabel(nil) == "利用枠")
    }

    @Test("値が無い割合は空白")
    func percent() {
        #expect(UsageText.percent(41.6) == "42%")
        #expect(UsageText.percent(0) == "0%")
        #expect(UsageText.percent(nil) == "")
    }

    @Test("行の id は表示の文字と切り離して固定する（設定の「マシンの見出しに出す利用枠」が id で選ぶ）")
    func rowIDs() {
        let window = UsageWindow(usedPercent: 10, resetsAt: nil, windowSeconds: 18_000)
        let usage = UsageSnapshot(claude: ClaudeUsage(fiveHour: window, sevenDay: window, at: now), codex: nil, contexts: [])
        let rows = UsageText.rows(usage, now: now)
        #expect(rows.map(\.id) == ["Claude/5h", "Claude/1w"])
        #expect(rows.map(\.label) == ["5時間", "1週間"])
        #expect(UsageWindowChoice.claudeFiveHour.includes(rows[0]))
        #expect(UsageWindowChoice.claudeWeek.includes(rows[1]))
    }

    @Test("会話の利用枠は、会話のアカウントの枠（アカウントが無ければマシンのログインの枠）")
    func conversationRows() {
        let login = UsageWindow(usedPercent: 99, resetsAt: nil, windowSeconds: 604_800)
        let sub = UsageWindow(usedPercent: 1, resetsAt: nil, windowSeconds: 604_800)
        let usage = UsageSnapshot(
            claude: ClaudeUsage(fiveHour: nil, sevenDay: login, at: now),
            claudeAccounts: [ClaudeAccount(name: "sub", usage: ClaudeUsage(fiveHour: nil, sevenDay: sub, at: now))], codex: nil, contexts: [])
        #expect(UsageText.rows(usage, engine: .claude, account: "sub", now: now).map(\.now) == [1])
        #expect(UsageText.rows(usage, engine: .claude, account: nil, now: now).map(\.now) == [99])
        #expect(UsageText.rows(usage, engine: .codex, account: "sub", now: now).isEmpty)
    }
}

/// ⌥⌘1〜3・メニュー・パレットの「◯◯で開く」と、オーケストレーターの送り先
@MainActor
@Suite struct PaletteMenuOrchestratorTests {
    private func model(_ scenario: String) async throws -> AppModel {
        AppDefaults.useScratch("test-palette")
        let model = AppModel(options: LaunchOptions(scenario: scenario))
        // 選んでいるカード（cursorTask）を相手にするのは列の形のホーム
        model.homeLayout = .columns
        for _ in 0..<250 where model.fleet.allBoards.isEmpty || model.fleet.machines.values.contains(where: { $0.machine == nil }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        return model
    }

    @Test("「◯◯で開く」は開き方を変え、選んでいるカードのタスクを開く")
    func presentOpensTarget() async throws {
        let model = try await model("stress")
        let key = try #require(model.boardCursorGrid.move(from: nil, .down))
        model.cursorTask = key
        model.present(.full, from: .key)
        #expect(model.taskPresentation == .full)
        #expect(model.selectedTask == key)
    }

    @Test("相手のタスクが無ければ、開き方だけを変える。パレットの題も「開き方を◯◯にする」")
    func presentWithoutTarget() async throws {
        let model = try await model("stress")
        model.cursorTask = nil
        model.closeTask()
        model.present(.modal, from: .key)
        #expect(model.taskPresentation == .modal)
        #expect(model.selectedTask == nil)
        #expect(model.paletteCommands.contains { $0.title == "開き方を「中央に表示」にする" })
    }

    @Test("送り先は、選ぶまでは見ている案件のマシン、選んだ後は画面を移っても変わらない")
    func orchestratorTarget() async throws {
        let model = try await model("stress+machine-second")
        #expect(model.orchestratorCandidates.count == 2)
        let studio = MachineID(rawValue: "fixture-studio")
        let secondMac = MachineID(rawValue: "fixture-second")
        let studioBoard = try #require(model.fleet.board(id: "fixture-board", on: studio))
        model.navigate(to: .board(machine: studioBoard.machine, id: studioBoard.id), from: .debug)
        #expect(model.orchestratorMachine == studio)
        model.selectOrchestratorTarget(secondMac)
        model.navigate(to: .board(machine: studioBoard.machine, id: studioBoard.id), from: .debug)
        #expect(model.orchestratorMachine == secondMac)
    }

    @Test("書き込めない接続先への指示は、黙って捨てずに失敗を返す")
    func sendToReadOnlyFails() async throws {
        let model = try await model("stress+machine-second")
        await #expect(throws: AppModel.ActionError.self) {
            try await model.sendToOrchestrator("状況を教えて", on: MachineID(rawValue: "fixture-second"))
        }
        #expect(model.orchestratorHistory.isEmpty)
    }

    @Test("ショートカットの一覧のキーは ⌃⌥⇧⌘ の順で書く")
    func modifierOrder() {
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        for section in ShortcutCatalog.sections(taskOpen: true, sessionOpen: true, conversationOpen: true) {
            for item in section.items {
                for chunk in item.keys.split(separator: " ") {
                    let modifiers = chunk.compactMap { order.firstIndex(of: $0) }
                    #expect(modifiers == modifiers.sorted(), "\(item.keys)")
                }
            }
        }
    }
}
