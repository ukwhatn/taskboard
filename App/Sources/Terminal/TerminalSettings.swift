import Foundation
import GhosttyTerminal
import GhosttyTheme

/// 端末の見た目と入力の設定。初期値は普段使っている Ghostty の設定に揃える。設定画面（P6）で変えた値は UserDefaults に置く
struct TerminalSettings {

    /// 先頭から順に字形を探す。日本語は 2 番目の BIZ UDGothic で描く
    static let defaultFontFamilies = ["JetBrainsMono Nerd Font", "BIZ UDGothic"]
    static let defaultLightTheme = "GitHub Light Default"
    static let defaultDarkTheme = "GitHub Dark Default"
    /// ⌥ を Meta として送る（tmux や shell の ⌥← などのため）
    static let defaultOptionAsMeta = true
    static let defaultBell = false
    /// 端末へ文字を送るだけの割り当て。⇧↩ で Claude Code の改行を送る
    static let inputBindings = ["shift+enter=text:\\x1b\\r"]

    var fontFamilies: [String]
    var lightTheme: String
    var darkTheme: String
    var optionAsMeta: Bool
    /// ベル（BEL）で音を鳴らす
    var bell: Bool

    init(defaults: UserDefaults = AppDefaults.store) {
        fontFamilies = (defaults.stringArray(forKey: AppPreferences.terminalFontFamiliesKey)).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultFontFamilies
        lightTheme = defaults.string(forKey: AppPreferences.terminalLightThemeKey) ?? Self.defaultLightTheme
        darkTheme = defaults.string(forKey: AppPreferences.terminalDarkThemeKey) ?? Self.defaultDarkTheme
        optionAsMeta = defaults.object(forKey: AppPreferences.terminalOptionAsMetaKey) as? Bool ?? Self.defaultOptionAsMeta
        bell = defaults.object(forKey: AppPreferences.terminalBellKey) as? Bool ?? Self.defaultBell
    }

    func apply(to configuration: TerminalConfiguration) -> TerminalConfiguration {
        var result = configuration
        for family in fontFamilies { result = result.custom("font-family", "\"\(family)\"") }
        #if os(macOS)
        result = result.custom("macos-option-as-alt", optionAsMeta ? "true" : "false")
        #endif
        for binding in Self.inputBindings { result = result.custom("keybind", binding) }
        return result
    }

    /// 一覧に無い名前は、既定のテーマに戻す
    var theme: TerminalTheme {
        let light = GhosttyThemeCatalog.theme(named: lightTheme) ?? GhosttyThemeCatalog.theme(named: Self.defaultLightTheme)
        let dark = GhosttyThemeCatalog.theme(named: darkTheme) ?? GhosttyThemeCatalog.theme(named: Self.defaultDarkTheme)
        guard let light, let dark else { return .default }
        return TerminalTheme(light: light.toTerminalConfiguration(), dark: dark.toTerminalConfiguration())
    }
}
