import Foundation
import Testing
@testable import Taskboard

@Suite struct TerminalSettingsTests {
    private func emptyDefaults() -> UserDefaults {
        let name = "TerminalSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsFollowGhosttyConfig() {
        let settings = TerminalSettings(defaults: emptyDefaults())
        #expect(settings.fontFamilies == ["JetBrainsMono Nerd Font", "BIZ UDGothic"])
        #expect(settings.lightTheme == "GitHub Light Default")
        #expect(settings.optionAsMeta)
    }

    @Test func storedValuesOverrideDefaults() {
        let defaults = emptyDefaults()
        defaults.set(["Menlo"], forKey: AppPreferences.terminalFontFamiliesKey)
        defaults.set(false, forKey: AppPreferences.terminalOptionAsMetaKey)
        let settings = TerminalSettings(defaults: defaults)
        #expect(settings.fontFamilies == ["Menlo"])
        #expect(!settings.optionAsMeta)
    }

    @Test func emptyFontListFallsBackToDefaults() {
        let defaults = emptyDefaults()
        defaults.set([String](), forKey: AppPreferences.terminalFontFamiliesKey)
        #expect(TerminalSettings(defaults: defaults).fontFamilies == TerminalSettings.defaultFontFamilies)
    }
}
