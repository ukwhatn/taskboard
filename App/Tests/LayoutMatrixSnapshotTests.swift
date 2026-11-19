import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 崩れの確認の組（docs/ui-system.md「確かめ方」）。fixtures `stress`（長い題、長い待ち理由、62 枚の列、空の列）を、
/// 幅と外観を変えて描く。`List` を使う画面（サイドバー、一覧）はウィンドウの外で描かれないので、実ウィンドウの撮影（scripts/ui）で見る
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct LayoutMatrixSnapshotTests {
    nonisolated static let appearances = [BoardSnapshotTests.Variant(name: "light", appearance: .aqua), BoardSnapshotTests.Variant(name: "dark", appearance: .darkAqua)]
    /// Mac の画面の幅（13 インチ、14 インチ、外部ディスプレイ）
    nonisolated static let boardWidths: [CGFloat] = [1280, 1728, 2560]
    /// タスクのパネルの幅（最小、既定、広げたとき、中央モーダル）。906 から詳細とセッションが左右に並ぶ
    nonisolated static let panelWidths: [CGFloat] = [420, 640, 906, 1180]
    /// 文書の画面の幅（サイドビューの既定、中央モーダル）。1180 ではコメントの欄が本文の右に並ぶ
    nonisolated static let documentWidths: [CGFloat] = [640, 1180]

    nonisolated static func cases(_ widths: [CGFloat]) -> [String] {
        widths.flatMap { width in appearances.map { "\(Int(width))-\($0.name)" } }
    }

    static func parse(_ name: String) throws -> (width: CGFloat, appearance: BoardSnapshotTests.Variant) {
        let parts = name.split(separator: "-")
        let width = try #require(Double(parts[0]))
        let appearance = try #require(appearances.first { $0.name == parts[1] })
        return (CGFloat(width), appearance)
    }

    static func model() -> AppModel {
        AppDefaults.useScratch("snapshot")
        return AppModel(options: LaunchOptions(scenario: "stress"))
    }

    /// 部品の枠が 2 回続けて変わらなくなるまで配置を回す。入力欄（NSTextField・NSTextView）の高さと LazyVStack の高さの見積もりは、1 回目の配置の後に決まる
    static func settle(_ view: NSView) {
        var last: [CGRect] = []
        for _ in 0..<20 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
            let frames = frames(in: view)
            if frames == last { return }
            last = frames
        }
    }

    static func frames(in view: NSView) -> [CGRect] {
        [view.frame] + view.subviews.flatMap { frames(in: $0) }
    }

    static func loaded(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || (model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.tasks.count ?? 0) < 70 {
            try #require(ContinuousClock.now < deadline, "fixtures stress を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("全体のボード", arguments: cases(boardWidths))
    func overview(name: String) async throws {
        let (width, appearance) = try Self.parse(name)
        let model = Self.model()
        try await Self.loaded(model)
        let view = NavigationStack { OverviewBoard() }.environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("長い題と長い待ち理由のタスクのパネル", arguments: cases(panelWidths))
    func panel(name: String) async throws {
        let (width, appearance) = try Self.parse(name)
        let model = Self.model()
        try await Self.loaded(model)
        let machine = model.fleet.allBoards[0].machine
        let view = TaskPanel(key: TaskKey(machine: machine, number: 200)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 800), variant: appearance), named: name)
    }

    @Test("文書の画面（質問の付いた文書）", arguments: cases(documentWidths))
    func document(name: String) async throws {
        let (width, appearance) = try Self.parse(name)
        let model = Self.model()
        try await Self.loaded(model)
        let machine = model.fleet.allBoards[0].machine
        let key = DocKey(machine: machine, id: 1)
        try #require(model.fleet.document(for: key) != nil, "fixtures stress の文書 1 が無い")
        let view = DocumentScreen(key: key, inWindow: true).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 760), variant: appearance), named: name)
    }

    /// パネルの中の文書の上の帯。#120 は文書が 2 つ（1 が新しい）で、2 を開くと前だけ押せる。#137 は文書 3 だけで、前と次を出さず題も押せない
    @Test("文書の画面の上の帯（前と次、題の一覧）", arguments: appearances.flatMap { appearance in [2, 3].map { "\($0)-\(appearance.name)" } })
    func documentBar(name: String) async throws {
        let parts = name.split(separator: "-")
        let id = try #require(Int64(parts[0]))
        let appearance = try #require(Self.appearances.first { $0.name == parts[1] })
        let model = Self.model()
        try await Self.loaded(model)
        let machine = model.fleet.allBoards[0].machine
        let key = DocKey(machine: machine, id: id)
        try #require(model.fleet.document(for: key) != nil, "fixtures stress の文書 \(id) が無い")
        let view = DocumentScreen(key: key).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 640, height: 160), variant: appearance), named: "doc\(name)")
    }

    /// fixtures `work-graph`。#301 は依存のある 11 件（並行の段・合流・待ち・完了・見送り）、#302 は依存の無い 60 件。
    /// 幅は右の欄の最小と最大（Mac と、iPad の左右並び）と、iPad の上下重ね
    @Test("作業項目の段と依存の線", arguments: [301, 302].flatMap { task in cases([320, 440, 640]).map { "\(task)-\($0)" } })
    func workGraph(argument: String) async throws {
        let parts = argument.split(separator: "-", maxSplits: 1).map(String.init)
        let (width, appearance) = try Self.parse(parts[1])
        AppDefaults.useScratch("snapshot")
        let model = AppModel(options: LaunchOptions(scenario: "work-graph"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || (model.fleet.machineState(for: model.fleet.allBoards[0].machine)?.workItems.count ?? 0) < 71 {
            try #require(ContinuousClock.now < deadline, "fixtures work-graph を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        let key = TaskKey(machine: model.fleet.allBoards[0].machine, number: try #require(Int(parts[0])))
        let task = try #require(model.fleet.task(for: key))
        let view = ScrollView {
            WorkItemList(task: task, items: model.fleet.workItems(for: key)).padding(Space.card)
        }
        .environment(model).environment(\.taskScope, key).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1000), variant: appearance), named: argument)
    }

    @Test("部品（帯、チップ、空状態、補足の並び）", arguments: cases([360, 640]))
    func components(name: String) async throws {
        let (width, appearance) = try Self.parse(name)
        let model = Self.model()
        let long = "接続先のMacに接続できません。ネットワークと、接続先のMacが起動しているかを確認してください。"
        let view = VStack(alignment: .leading, spacing: Space.block) {
            Banner(kind: .waiting, message: "実機の iPhone で Mac Studio の QR コードを読んで接続できることを確かめる（ユーザー）。登録を解除した端末が接続できなくなることも確かめる")
            Banner(kind: .error, message: long, onClose: {})
            Banner(kind: .notice, message: "定期起動「PR 棚卸し」を実行しました。", detail: "#12 PR の棚卸し")
            HStack(spacing: Space.inline) {
                Chip(text: "#41 doorman", symbol: "arrow.triangle.pull", tint: .green)
                Chip(text: "PROJ-807 とても長いチケットの題が入ったチップ", symbol: "ticket")
                ChipButton(text: "選んだ", selected: true) {}
                ChipButton(text: "選んでいない") {}
            }
            MetaLine(items: ["このMac", "taskboard", "feature/ui-system", "3分前", "長い補足の項目がここに入る"])
            EmptyState("作業項目はありません", symbol: "checklist", message: "下の欄から追加できます。")
                .frame(height: 180)
        }
        .padding(Space.card)
        .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }
}
