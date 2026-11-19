import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// マイクの許可を変える画面を開く（Mac は［システム設定］の［マイク］、iPhone・iPad は［設定］のこのアプリ）
enum VoiceDictationSettings {
    #if os(macOS)
    static var openLabel: String { String(localized: "システム設定を開く") }
    private static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    #else
    static var openLabel: String { String(localized: "設定を開く") }
    private static let url = URL(string: UIApplication.openSettingsURLString)
    #endif

    @MainActor
    static func open() {
        guard let url else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
