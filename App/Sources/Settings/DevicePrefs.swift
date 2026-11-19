import Foundation
import TaskboardKit

/// この端末の設定の読み書き（`AppDefaults.store`）。キーは `AppPreferences`。案件・列・起動の既定は daemon に置く
struct DevicePrefs {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
    }

    var machineOrder: [String] {
        get { defaults.stringArray(forKey: AppPreferences.sidebarMachineOrderKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: AppPreferences.sidebarMachineOrderKey) }
    }

    func boardOrder(machine: String) -> [String] {
        defaults.stringArray(forKey: AppPreferences.sidebarBoardOrderKey(machine: machine)) ?? []
    }

    func setBoardOrder(_ order: [String], machine: String) {
        defaults.set(order, forKey: AppPreferences.sidebarBoardOrderKey(machine: machine))
    }

    var collapsedMachines: Set<String> {
        get { Set(defaults.stringArray(forKey: AppPreferences.sidebarCollapsedKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: AppPreferences.sidebarCollapsedKey) }
    }

    var toggledSidebarNodes: Set<String> {
        get { Set(defaults.stringArray(forKey: AppPreferences.sidebarToggledNodesKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: AppPreferences.sidebarToggledNodesKey) }
    }

    /// 1 台だけ表示の間か。画面共有の途中で再起動しても戻らないよう、覚えておく
    var onlyMachineEnabled: Bool {
        get { defaults.bool(forKey: AppPreferences.onlyMachineEnabledKey) }
        nonmutating set { defaults.set(newValue, forKey: AppPreferences.onlyMachineEnabledKey) }
    }

    /// 1 台だけ表示で残すマシン（fleet の id）。設定画面かツールバーのメニューで決める。nil は未設定
    var onlyMachineID: String? {
        get { defaults.string(forKey: AppPreferences.onlyMachineIDKey) }
        nonmutating set { defaults.set(newValue, forKey: AppPreferences.onlyMachineIDKey) }
    }

    var taskPresentation: TaskPresentation {
        get { defaults.string(forKey: AppPreferences.taskPresentationKey).flatMap(TaskPresentation.init(rawValue:)) ?? .side }
        nonmutating set { defaults.set(newValue.rawValue, forKey: AppPreferences.taskPresentationKey) }
    }

    /// 知らない値（新しい版が足した形）は既定（会話）に戻す
    var homeLayout: HomeLayout {
        get { defaults.string(forKey: AppPreferences.homeLayoutKey).flatMap(HomeLayout.init(rawValue:)) ?? .conversations }
        nonmutating set { defaults.set(newValue.rawValue, forKey: AppPreferences.homeLayoutKey) }
    }

    /// 知らない値（新しい版が足した分け方など）は既定に戻す
    var sidebarArrangement: SidebarArrangement {
        get {
            SidebarArrangement(
                grouping: defaults.string(forKey: AppPreferences.sidebarGroupingKey).flatMap(SidebarArrangement.Grouping.init(rawValue:)) ?? .boards,
                order: defaults.string(forKey: AppPreferences.sidebarTaskOrderKey).flatMap(SidebarArrangement.Order.init(rawValue:)) ?? .number)
        }
        nonmutating set {
            defaults.set(newValue.grouping.rawValue, forKey: AppPreferences.sidebarGroupingKey)
            defaults.set(newValue.order.rawValue, forKey: AppPreferences.sidebarTaskOrderKey)
        }
    }

    /// 読めない値は捨てる
    var pinnedTasks: Set<TaskKey> {
        get {
            Set(
                (defaults.stringArray(forKey: AppPreferences.pinnedTasksKey) ?? []).compactMap { stored in
                    let parts = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2, let number = Int(parts[1]) else { return nil }
                    return TaskKey(machine: MachineID(rawValue: String(parts[0])), number: number)
                })
        }
        nonmutating set { defaults.set(newValue.map { "\($0.machine.rawValue)\n\($0.number)" }.sorted(), forKey: AppPreferences.pinnedTasksKey) }
    }

    var hiddenMachines: Set<String> {
        get { Set(defaults.stringArray(forKey: AppPreferences.hiddenMachinesKey) ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: AppPreferences.hiddenMachinesKey) }
    }

    /// 知らない値はシステムに合わせる
    var appearance: AppearanceChoice {
        get { defaults.string(forKey: AppPreferences.appearanceKey).flatMap(AppearanceChoice.init(rawValue:)) ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: AppPreferences.appearanceKey) }
    }

    /// 未設定なら全部
    var usageWindows: Set<UsageWindowChoice> {
        get { defaults.stringArray(forKey: AppPreferences.usageWindowsKey).map { Set($0.compactMap(UsageWindowChoice.init(rawValue:))) } ?? Set(UsageWindowChoice.allCases) }
        nonmutating set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: AppPreferences.usageWindowsKey) }
    }

    /// 未設定なら全部
    var notifyKinds: Set<NotifyKind> {
        get { defaults.stringArray(forKey: AppPreferences.notifyKindsKey).map { Set($0.compactMap(NotifyKind.init(rawValue:))) } ?? Set(NotifyKind.allCases) }
        nonmutating set { defaults.set(newValue.map(\.rawValue).sorted(), forKey: AppPreferences.notifyKindsKey) }
    }

    /// ターンの完了の通知。未設定なら出さない。設定画面は `@AppStorage` で同じキーを書く
    var notifyTurns: TurnNotify {
        defaults.string(forKey: AppPreferences.notifyTurnsKey).flatMap(TurnNotify.init(rawValue:)) ?? .never
    }

    /// 未設定なら鳴らす。設定画面は `@AppStorage` で同じキーを書く
    var notifySound: Bool { defaults.object(forKey: AppPreferences.notifySoundKey) as? Bool ?? true }
}
