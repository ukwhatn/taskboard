import SwiftUI

extension View {
    /// ⌘↩ で `action` を呼ぶ。複数行の欄では ↩ が改行になり、既定のボタン（↩）に届かないため。
    /// ボタン 1 つに割り当てられるキーは 1 つなので、見えないボタンを裏に置く
    func commandReturn(enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        background {
            Button("", action: action)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
