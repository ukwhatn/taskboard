import SwiftUI
import TaskboardKit

/// タスク画面で 2 つ並べたときの左（札で選んだもの）と右（2 つ目）
enum SplitSide: Hashable {
    case leading
    case trailing
}

/// タスク画面の右に 2 つ目として並べる会話（iPhone では並べない）
enum TaskSplit {
    /// 右に出すもの。札にあって左と違うものだけ（終了したもの・札から消えたものは出さない）
    static func visible(_ second: ConversationKey?, primary: ConversationKey?, rows: [SessionMemberRow]) -> Conversation? {
        guard let second, second != primary else { return nil }
        return rows.map(\.conversation).first { $0.key == second }
    }

    /// ［並べる］の相手: 札の並びで、左でない最初の会話
    static func partner(of primary: ConversationKey?, rows: [SessionMemberRow]) -> ConversationKey? {
        guard primary != nil else { return nil }
        return rows.map(\.conversation.key).first { $0 != primary }
    }
}

/// 並べた欄の間で入力を移すキー（Claude Desktop と同じ ⌃] で右、⌃[ で左）。会話の入力欄だけが受ける。
/// メニューに置かないのは、端末の ⌃[ は Esc で、ghostty の端末は ⌃ のキーを一度メニューに回すため（置くと端末の Esc を奪う）
enum SplitFocusKeys {
    static func side(for key: KeyEquivalent, modifiers: EventModifiers) -> SplitSide? {
        guard modifiers == .control else { return nil }
        switch key.character {
        case "]": return .trailing
        case "[": return .leading
        default: return nil
        }
    }

    /// 入力欄のキーから呼ぶ形。並べていなければ（`move` が nil）使わない
    static func handle(_ key: KeyEquivalent, modifiers: EventModifiers, move: ((SplitSide) -> Void)?) -> Bool {
        guard let move, let side = side(for: key, modifiers: modifiers) else { return false }
        move(side)
        return true
    }
}

extension EnvironmentValues {
    /// 並べた欄の入力欄に、もう一方の欄へ入力を移す口を渡す（`TaskPanel` が 2 つ並べている間だけ置く）
    @Entry var splitFocus: ((SplitSide) -> Void)?
}
