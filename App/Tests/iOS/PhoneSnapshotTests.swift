import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
import UIKit
@testable import Taskboard

/// iPhone の幅の画面を PNG で固定する。fixtures `conversations` の、タスクの一覧・タスクの画面・会話の画面（キーボードなし）を描く。
/// ガラスの部品（タブバー・ナビゲーションバー）は key window に載せないと描かれないので、そのシミュレータの窓で描く。
/// 端末は窓の大きさで決め、17e と 18 Pro のシミュレータでそれぞれ回す（`scripts/snapshot-test.sh --ios <udid>`）
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct PhoneSnapshotTests {
    struct Device: Sendable {
        let name: String
        let size: CGSize
        let safeArea: UIEdgeInsets
    }

    /// 画面の大きさは各シミュレータで測った値（17e は 1170 × 2532 px、18 Pro は 1206 × 2622 px の 3 倍）。上の safe area は 17e がノッチ、18 Pro が Dynamic Island の分
    nonisolated static let devices = [
        Device(name: "iphone17e", size: CGSize(width: 390, height: 844), safeArea: UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)),
        Device(name: "iphone18pro", size: CGSize(width: 402, height: 874), safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)),
    ]

    enum Screen: String, CaseIterable {
        case tasks, task, conversation
    }

    nonisolated static let screens = Screen.allCases.map(\.rawValue)

    /// 日数の表示（期日まで N 日・最後の動きから N 日）が実行日で変わらないように固定する（Mac の snapshot と同じ日）
    static let today = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00+09:00")!
    static let machine = MachineID(rawValue: "fixture-studio")

    static func model() -> AppModel {
        AppDefaults.useScratch("snapshot")
        return AppModel(options: LaunchOptions(scenario: "conversations"))
    }

    static func config(_ device: Device) -> ViewImageConfig {
        let traits = UITraitCollection { traits in
            traits.userInterfaceIdiom = .phone
            traits.horizontalSizeClass = .compact
            traits.verticalSizeClass = .regular
            traits.userInterfaceStyle = .light
        }
        return ViewImageConfig(safeArea: device.safeArea, size: device.size, traits: traits)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "fixtures conversations を読み込めない")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// 回しているシミュレータ。知らない大きさの端末なら nil
    static var device: Device? {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return window.flatMap { window in devices.first { $0.size == window.bounds.size } }
    }

    @Test(arguments: screens)
    func screen(name: String) async throws {
        try #require(AppModel.isPhone, "iPhone のシミュレータで回す")
        let device = try #require(Self.device, "iPhone 17e か 18 Pro のシミュレータで回す")
        let screen = try #require(Screen(rawValue: name))
        let model = Self.model()
        try await waitUntil { (model.fleet.machineState(for: Self.machine)?.tasks.count ?? 0) > 0 }
        switch screen {
        case .tasks: break
        case .task: model.open(URL(string: "taskboard://task/fixture-studio/137")!, from: .debug)
        // 生成中でなく、問いのカードも出ていない会話
        case .conversation: model.open(URL(string: "taskboard://conversation/fixture-studio/c-limit")!, from: .debug)
        }
        let root = RootView()
            .modifier(WindowRoot(model: model))
            .environment(\.today, Self.today)
            .environment(\.liveClock, false)
            .environment(\.defersMount, false)
        let controller = UIHostingController(rootView: root)
        // 会話の行と一覧は配置の後に読み込むので、描くまで少し待つ。タブバーのガラスが下の文字を屈折させる描き方は回ごとに変わり、
        // ぼかしが下の広い範囲に少しずつ効く。17e のタスクの一覧で画素の 1.4% がわずかに違った（RGB の差が 10 を越えたのは 0.13%）ので、2% までの違いは通す
        assertSnapshot(
            of: controller,
            as: .wait(for: 1.5, on: .image(on: Self.config(device), drawHierarchyInKeyWindow: true, precision: 0.98, perceptualPrecision: 0.98)),
            named: "\(device.name)-\(name)")
    }

    /// fixtures `overview-panels` の #214。題の下の帯、会話の上の折りたたんだ部品、欄の切り替えの最後の部品の欄
    @Test func taskWithParts() async throws {
        try #require(AppModel.isPhone, "iPhone のシミュレータで回す")
        let device = try #require(Self.device, "iPhone 17e か 18 Pro のシミュレータで回す")
        AppDefaults.useScratch("snapshot-parts")
        let model = AppModel(options: LaunchOptions(scenario: "overview-panels"))
        try await waitUntil { (model.fleet.machineState(for: MachineID(rawValue: "demo-studio"))?.panels.count ?? 0) > 0 }
        model.open(URL(string: "taskboard://task/demo-studio/214")!, from: .debug)
        let root = RootView()
            .modifier(WindowRoot(model: model))
            .environment(\.today, Self.today)
            .environment(\.liveClock, false)
            .environment(\.defersMount, false)
        let controller = UIHostingController(rootView: root)
        assertSnapshot(
            of: controller,
            as: .wait(for: 1.5, on: .image(on: Self.config(device), drawHierarchyInKeyWindow: true, precision: 0.98, perceptualPrecision: 0.98)),
            named: "\(device.name)-task-parts")
    }
}
