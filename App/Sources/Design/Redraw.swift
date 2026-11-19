import SwiftUI

/// 親が描き直されても、`key` が変わったときだけ中身を描き直す入れ物。中身が見せる値を `key` に渡す。
/// 下書きの Binding を受ける view は、下書きのどこが変わっても変わったとみなされる。設定の案件の Form では、起動プロンプトを 1 字打つたびに全部の行が組み直され、
/// iPad で入れた直後に 100 ms を超えた。中身は前の Binding のまま残るが、Binding は書き込み先の場所を指すので、書いた値は今の下書きに入る。
/// `@State` から作った Binding（`$draft`）を中身に渡すと、State が変わるたびに親を通らずに描き直されて効かない。`Binding(get:set:)` で渡す。
/// Form の区分（Section）と、Form の行を 2 つ以上出す view は包まない。Form が 1 行として扱い、見出しと注記が枠の中に入り、行の間の区切りが消える。
/// それらは view を Equatable にして見せる値を比べる（`ColumnSection`・`DueDateField`）
struct Redraw<Key: Equatable, Content: View>: View {
    let key: Key
    let content: Content

    init(on key: Key, @ViewBuilder content: () -> Content) {
        self.key = key
        self.content = content()
    }

    var body: some View {
        EquatableView(content: Keyed(key: key, content: content))
    }

    private struct Keyed: View, Equatable {
        let key: Key
        let content: Content

        nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

        var body: some View { content }
    }
}
