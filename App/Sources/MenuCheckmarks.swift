#if os(macOS)
import AppKit
import SwiftUI

/// メニューの切り替えの項目（開き方、1台だけ表示）のチェックを、メニューを開くたびに model の値で付け直す。
/// SwiftUI の Commands は model の変化で描き直されず（TaskboardApp.swift の BoardCommands）、Picker と Toggle のチェックが起動時の値のまま残るため。
/// 項目は題でなくキーで探す（題は文言の直しで変わる）
@MainActor
enum MenuCheckmarks {
    private static var observer: (any NSObjectProtocol)?

    static func start(model: AppModel) {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply(model) }
        }
    }

    static func apply(_ model: AppModel) {
        guard let menu = NSApp.mainMenu else { return }
        let presentations = TaskPresentation.allCases
        for item in items(in: menu) {
            let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            if mask == [.option, .command], let n = Int(item.keyEquivalent), presentations.indices.contains(n - 1) {
                item.state = presentations[n - 1] == model.taskPresentation ? .on : .off
            } else if mask == [.control, .command], item.keyEquivalent == "1" {
                item.state = model.onlyMachineEnabled ? .on : .off
            }
        }
    }

    private static func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items(in:)) ?? []) }
    }
}
#endif
