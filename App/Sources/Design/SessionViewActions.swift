import SwiftUI

/// 今見えている端末かチャットが受ける操作。メニュー（表示・編集）とショートカットから呼ぶ。
/// 各画面が出たときに `AppModel.sessionActions` に置く。`@FocusedValue` で受けないのは、SwiftUI の Commands が
/// 値の変化で描き直されず、起動直後の nil（無効）のまま残るから
struct SessionViewActions {
    /// 置いた画面。消えるときに、自分が置いたものだけを外す
    var owner = UUID()
    /// ⌘F。検索の欄を開いて入力を受ける
    var find: () -> Void
    /// ⌘+ / ⌘- / ⌘0。端末とチャットで別々に覚える
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomReset: () -> Void
    /// メニューの［会話］。会話の画面だけが置き、端末とチャットでは nil（項目を選んでも何もしない）
    var conversation: ConversationMenuActions?
}

struct ConversationMenuActions {
    /// ⌥⌘O。末尾からフォークする
    var fork: () -> Void
    /// ⌘⇧M・⌘⇧I・⌘⇧E。入力欄の下の欄を開く（engine に無い欄は開かない）
    var openField: (ConversationField) -> Void
    /// ⌥⌘↑・⌥⌘↓。前・次の人の発言へ送る
    var jump: (_ forward: Bool) -> Void
}


/// 文字の大きさ（pt）。`@AppStorage` に置き、端末とチャットで別のキーを使う
enum SessionTextSize {

    #if os(macOS)
    /// 普段使っている Ghostty の設定（font-size = 15）に揃える
    static let terminalDefault = 15.0
    /// Claude Desktop の会話の本文と同じ
    static let chatDefault = 14.0
    #else
    static let terminalDefault = 12.0
    static let chatDefault = 15.0
    #endif

    static let range = 9.0...28.0
    static let step = 1.0

    static func clamp(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }

    static func current(_ key: String, default value: Double) -> Double {
        clamp(AppDefaults.store.object(forKey: key) as? Double ?? value)
    }

    /// `key` の大きさを 1 段変える。`delta` が nil なら既定に戻す。画面は `@AppStorage` で同じ値を見ている
    static func adjust(_ key: String, default value: Double, by delta: Double?) {
        let current = AppDefaults.store.object(forKey: key) as? Double ?? value
        AppDefaults.store.set(delta.map { clamp(current + $0) } ?? value, forKey: key)
    }
}
