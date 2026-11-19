import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// この端末の設定の読み書き。保存の形（キーごとの値の型と並び）は、前の版が書いた値を読めるよう今の形のまま
@Suite struct DevicePrefsTests {
    private func store() -> UserDefaults {
        let name = "tb-device-prefs-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("非表示のマシンは既定で空。並べた文字の配列で保存する")
    func hiddenMachines() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.hiddenMachines.isEmpty)
        prefs.hiddenMachines = ["conn:b", "conn:a"]
        #expect(defaults.stringArray(forKey: "sidebar.hiddenMachines") == ["conn:a", "conn:b"])
        #expect(DevicePrefs(defaults: defaults).hiddenMachines == ["conn:a", "conn:b"])
    }

    @Test("外観は既定でシステムに合わせる。知らない値もシステムに合わせる")
    func appearance() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.appearance == .system)
        prefs.appearance = .dark
        #expect(defaults.string(forKey: "appearance") == "dark")
        #expect(DevicePrefs(defaults: defaults).appearance == .dark)
        defaults.set("sepia", forKey: "appearance")
        #expect(prefs.appearance == .system)
    }

    @Test("利用枠は既定で全部。並べた文字の配列で保存し、知らない値は捨てる。空も保てる")
    func usageWindows() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.usageWindows == Set(UsageWindowChoice.allCases))
        prefs.usageWindows = [.codex, .claudeFiveHour]
        #expect(defaults.stringArray(forKey: "usage.windows") == ["Claude/5h", "Codex"])
        defaults.set(["Codex", "Gemini"], forKey: "usage.windows")
        #expect(prefs.usageWindows == [.codex])
        prefs.usageWindows = []
        #expect(prefs.usageWindows.isEmpty)
    }

    @Test("通知の種類は既定で全部。並べた文字の配列で保存する。音は既定で鳴らす")
    func notifications() {
        let defaults = store()
        let prefs = DevicePrefs(defaults: defaults)
        #expect(prefs.notifyKinds == Set(NotifyKind.allCases))
        #expect(prefs.notifySound)
        prefs.notifyKinds = []
        #expect(defaults.stringArray(forKey: "notify.kinds") == [])
        #expect(prefs.notifyKinds.isEmpty)
        let all = Set(NotifyKind.allCases)
        prefs.notifyKinds = all
        #expect(defaults.stringArray(forKey: "notify.kinds") == all.map(\.rawValue).sorted())
        defaults.set(false, forKey: "notify.sound")
        #expect(!prefs.notifySound)
    }
}
