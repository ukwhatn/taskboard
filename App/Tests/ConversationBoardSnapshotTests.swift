import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// ホームの会話の形を、会話の本数ごと（10・20・40 本。提案書の「本数が多いとき」の図と同じ組の内訳）にライトとダークで描く。
/// 10 本は対応待ちと実行中がすべて札、20 本は実行中が 1 行、40 本は実行中を案件の見出しで分けて各案件の新しい 2 件
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ConversationBoardSnapshotTests {
    nonisolated static let variants = Array(BoardSnapshotTests.variants.prefix(2))
    /// MacBook の窓（1512×945。perf-gate と同じ）からサイドバーと上の帯を除いた面
    static let size = CGSize(width: 1300, height: 860)

    struct Mix {
        let waiting: Int
        let running: Int
        let unread: Int
        let idle: Int
    }

    static let mixes: [Int: Mix] = [
        10: Mix(waiting: 2, running: 4, unread: 1, idle: 3),
        20: Mix(waiting: 4, running: 10, unread: 3, idle: 3),
        40: Mix(waiting: 6, running: 18, unread: 6, idle: 10),
    ]

    @Test(arguments: [10, 20, 40], variants.map(\.name))
    func board(count: Int, variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let mix = try #require(Self.mixes[count])
        let model = try await Self.model()
        let fixture = Fixture(now: BoardSnapshotTests.today).build(mix)
        let tiles = ConversationTiles(fixture.states, unread: fixture.unread, now: BoardSnapshotTests.today)
        #expect(tiles.waiting.count + tiles.running.count + tiles.unread.count + tiles.idle.count == count)
        let view = NavigationStack { ConversationBoardSurface(tiles: tiles, filtered: false) }.environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: Self.size, variant: variant), named: "\(count)-\(variant.name)")
    }

    /// 札のマシンを fleet が知っている model（マシン名と、書き込めない接続先の文を本物の画面と同じ経路で出す）
    static func model() async throws -> AppModel {
        AppDefaults.useScratch("snapshot")
        let model = AppModel(options: LaunchOptions(scenario: "demo+demo-laptop"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.machines.count < 2 || model.fleet.machines.values.contains(where: { $0.machine == nil }) {
            try #require(ContinuousClock.now < deadline, "fixtures を読み込めない")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    /// 2 台・3 案件の会話。題は提案書の図と同じもの。マシンは demo の 2 台
    struct Fixture {
        let now: Date
        let studio = MachineID(rawValue: "demo-studio")
        let laptop = MachineID(rawValue: "demo-laptop")

        private static let runningTitles = [
            "3D セキュアの戻り先", "E2E テストを新しい API に向ける", "結果をキャッシュする", "major の上げ方を調べる", "遅いクエリを洗い出す", "上限を設定から読む",
            "patch と minor を上げる", "画像の縮小を並べる", "在庫の引当を見直す", "ログの保存先を分ける", "検索の候補を出す", "決済の失敗を記録する",
            "注文の CSV の列を足す", "管理画面の権限を分ける", "家計簿アプリの CSV 取り込み", "通知の文面を直す", "依存の警告を消す", "週報の集計を速くする",
        ]
        private static let idleTitles = ["在庫 API の PR をレビュー", "ブログの記事の OGP", "社内 wiki の検索", "請求書の PDF", "アクセスログの集計"]

        /// マシンの状態と、未読の会話
        func build(_ mix: Mix) -> (states: [MachineState], unread: Set<ConversationKey>) {
            var studioState = MachineState(machine: MachineInfo(id: studio, name: "Mac Studio", daemonVersion: "test"), connected: true)
            var laptopState = MachineState(machine: MachineInfo(id: laptop, name: "MacBook Pro", daemonVersion: "test"), connected: true)
            let columns = [BoardColumn(id: "working", label: "作業中", kind: .open, position: 0)]
            let boards = [
                Board(id: "storefront", machine: studio, name: "ストアフロント", position: 0, columns: columns, createdAt: now),
                Board(id: "admin", machine: studio, name: "社内ツール", position: 1, columns: columns, createdAt: now),
                Board(id: "personal", machine: laptop, name: "個人開発", position: 0, columns: columns, createdAt: now),
            ]
            for board in boards {
                if board.machine == studio { studioState.boards[board.id] = board } else { laptopState.boards[board.id] = board }
            }
            var number = 200
            var conversations: [Conversation] = []
            var unreadKeys: Set<ConversationKey> = []
            func make(_ title: String, board: Board, phase: Conversation.Phase, minutesAgo: Double, pending: [ConversationRequest] = []) -> Conversation {
                number += 1
                let task = BoardTask(machine: board.machine, number: number, boardID: board.id, columnID: "working", title: title, createdAt: now, updatedAt: now)
                if board.machine == studio { studioState.tasks[task.id] = task } else { laptopState.tasks[task.id] = task }
                return Conversation(
                    id: "c\(number)", machine: board.machine, taskNumber: number, agentSessionID: "s\(number)", cwd: "/tmp", title: title, runner: .host,
                    phase: phase, pending: pending, createdAt: now.addingTimeInterval(-minutesAgo * 60 - 600), updatedAt: now.addingTimeInterval(-minutesAgo * 60))
            }
            // 対応待ち: 権限・質問 1 問・計画・応答の止まり・2 問の質問・権限の順に回す
            for index in 0..<mix.waiting {
                let since = now.addingTimeInterval(-Double(30 - index * 4) * 60)
                let id = "r\(index)"
                switch index % 6 {
                case 0, 5:
                    let request = ConversationRequest(
                        id: id, kind: .permission, toolName: "Bash", toolUseID: id,
                        waiting: RequestWaiting(id: id, since: since, permission: .init(tool: "Bash", summary: "pnpm run bench:search", detail: "検索のベンチマークを回す")),
                        suggestions: [PermissionSuggestion(id: "s\(index)", kind: .rule, subject: "Bash(pnpm run bench:*)", scope: .project)])
                    conversations.append(make(index == 0 ? "全文検索の index を足す" : "ブログの記事の OGP を作る", board: boards[index == 0 ? 0 : 2], phase: .waiting, minutesAgo: 30, pending: [request]))
                case 1:
                    let question = AskQuestion(
                        id: "q", question: "ランクを決める期間はどちらにしますか？",
                        options: [AskOption(label: "直近 12 か月", description: "毎月入れ替わる。下がることもある"), AskOption(label: "年度ごと", description: "4 月にまとめて決める")])
                    let request = ConversationRequest(id: id, kind: .question, toolName: "AskUserQuestion", toolUseID: id, waiting: RequestWaiting(id: id, since: since, questions: [question]))
                    conversations.append(make("会員ランクの計画", board: boards[0], phase: .waiting, minutesAgo: 25, pending: [request]))
                case 2:
                    let plan = "1. 注文履歴の画面に［CSV を書き出す］を追加する\n2. 期間の指定は今の絞り込みをそのまま使う\n3. 列は注文番号・日付・金額・状態\n4. 1 万件を超えたら分けて書き出す\n5. 文字コードは UTF-8（BOM 付き）\n6. テストを足す"
                    let request = ConversationRequest(id: id, kind: .plan, toolName: "ExitPlanMode", toolUseID: id, waiting: RequestWaiting(id: id, since: since), plan: plan)
                    conversations.append(make("注文履歴を CSV で書き出せるようにする", board: boards[0], phase: .waiting, minutesAgo: 20, pending: [request]))
                case 3:
                    var stalled = make("依存パッケージの脆弱性を調べる", board: boards[1], phase: .running, minutesAgo: 6)
                    stalled.stalledSince = now.addingTimeInterval(-5 * 60)
                    stalled.turnStartedAt = now.addingTimeInterval(-9 * 60)
                    conversations.append(stalled)
                default:
                    let questions = ["表示する件数", "並び順"].enumerated().map { offset, header in
                        AskQuestion(id: "q\(offset)", question: "\(header)はどうしますか？", header: header, options: [AskOption(label: "既定のまま"), AskOption(label: "変える")])
                    }
                    let request = ConversationRequest(id: id, kind: .question, toolName: "AskUserQuestion", toolUseID: id, waiting: RequestWaiting(id: id, since: since, questions: questions))
                    conversations.append(make("社内 wiki の検索を足す", board: boards[1], phase: .waiting, minutesAgo: 15, pending: [request]))
                }
            }
            // 実行中: ストアフロント・社内ツール・個人開発に 11:5:2 の割合で配る（40 本の図と同じ）
            for index in 0..<mix.running {
                let board = index % 9 == 8 ? boards[2] : (index % 3 == 2 ? boards[1] : boards[0])
                var running = make(Self.runningTitles[index % Self.runningTitles.count], board: board, phase: .running, minutesAgo: Double(index + 1))
                running.turnStartedAt = now.addingTimeInterval(-Double(index + 1) * 60)
                if index % 2 == 0 {
                    running.lastReply = ConversationReply(text: "戻り先の画面を足し、テストが 24 件通りました。決済の結果は戻り先の URL の値を信じず、API に問い合わせて確かめます。", at: now.addingTimeInterval(-90))
                    running.plan = (0..<5).map { ConversationPlanItem(id: "p\($0)", title: "手順\($0)", status: $0 < 3 ? .completed : .pending) }
                    running.diff = ConversationDiffSummary(isRepo: true, files: 7, insertions: 318, deletions: 64)
                }
                running.contextPercent = 41
                conversations.append(running)
            }
            for index in 0..<mix.unread {
                var unread = make("在庫 API の PR をレビュー \(index + 1)", board: boards[index % 2], phase: .idle, minutesAgo: Double(12 + index))
                unread.lastReply = ConversationReply(text: "レビューを書きました。CI の失敗は、カーソルの値を URL に載せるときに base64 の + が崩れているためです。", at: now.addingTimeInterval(-Double(12 + index) * 60))
                unreadKeys.insert(unread.key)
                conversations.append(unread)
            }
            for index in 0..<mix.idle {
                var idle = make(Self.idleTitles[index % Self.idleTitles.count], board: boards[index % 3], phase: .idle, minutesAgo: Double(60 + index * 10))
                idle.lastReply = ConversationReply(text: "終わりました。", at: now.addingTimeInterval(-Double(60 + index * 10) * 60))
                conversations.append(idle)
            }
            for conversation in conversations {
                if conversation.machine == studio { studioState.conversations[conversation.key] = conversation } else { laptopState.conversations[conversation.key] = conversation }
            }
            return ([studioState, laptopState], unreadKeys)
        }
    }
}
