import CoreGraphics

/// 設定画面の寸法
enum SettingsMetrics {
    /// 左の区分の一覧の幅。区分の名前（最長は「ショートカット」）とアイコンが 1 行に入る幅。iPad は指で押すので行が広い
    #if os(macOS)
    static let sectionListWidth: CGFloat = 180
    #else
    static let sectionListWidth: CGFloat = 220
    #endif
}
