import SwiftUI

/// 押した値を先に出し、daemon の値が届くか保存に失敗するまで持つ（docs/ui-system.md「設定」）。
/// 失敗で戻すのは、押した値がまだその値のときだけ（続けて押し直していたら、後に押した値を残す）
struct PendingValue<Value: Equatable> {
    private var value: Value?

    func shown(_ current: Value) -> Value {
        value ?? current
    }

    mutating func send(_ newValue: Value) {
        value = newValue
    }

    mutating func failed(_ sent: Value) {
        if value == sent { value = nil }
    }

    /// daemon の値が届いた
    mutating func settle() {
        value = nil
    }
}

extension Binding {
    /// 設定の欄の Binding。押した値を `pending` に置いて `save` を呼び、`save` が失敗（false）なら戻す。
    /// daemon の値が届いたときの `settle` は、呼び出し側が `onChange` で行う
    @MainActor
    static func pending(_ pending: Binding<PendingValue<Value>>, current: Value, save: @escaping @MainActor (Value) async -> Bool) -> Binding<Value>
    where Value: Equatable {
        Binding(
            get: { pending.wrappedValue.shown(current) },
            set: { value in
                pending.wrappedValue.send(value)
                Task { @MainActor in
                    if await !save(value) { pending.wrappedValue.failed(value) }
                }
            })
    }
}
