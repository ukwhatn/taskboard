import SwiftUI

/// その場で直す欄（タスクの題・メモ・足すリンク）。出た瞬間にフォーカスを取り、↩ か欄の外を押す（フォーカスが外れる）と `commit`、
/// Esc（Mac）で `cancel`。どちらも 1 回だけ呼ぶ（↩ の後にフォーカスが外れても 2 回目は呼ばない）。
/// 複数行の欄では ⇧↩・⌥↩ がカーソルの位置への改行（チャットの入力欄と同じ）
struct InlineField: View {
    let label: String
    @Binding var text: String
    var font: MultilineTextFont = .body
    var lines: ClosedRange<Int> = 1...3
    /// 書式の見本だけ（説明は書かない）。無ければ `label` を空の欄に出す
    var prompt: String?
    let commit: () -> Void
    let cancel: () -> Void

    @FocusState private var focused: Bool
    @State private var finished = false

    var body: some View {
        Group {
            if lines.upperBound > 1 {
                MultilineTextField(label: label, placeholder: prompt ?? label, text: $text, lines: lines, font: font, submit: { finish(commit) })
            } else {
                // 1 行の欄（足すリンク）は長い文でも 1 行を組むだけで止まらないので、TextField のまま
                TextField(label, text: $text, prompt: prompt.map { Text(verbatim: $0) }, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font.swiftUI)
                    .lineLimit(lines)
                    .onSubmit { finish(commit) }
                    .accessibilityLabel(label)
            }
        }
        .focused($focused)
        .submitLabel(.done)
        .onChange(of: focused) { _, now in if !now { finish(commit) } }
        .onAppear { focused = true }
        .background(InlineEditHighlight())
        #if os(macOS)
        .onExitCommand { finish(cancel) }
        #endif
    }

    private func finish(_ action: () -> Void) {
        guard !finished else { return }
        finished = true
        action()
    }
}

/// 欄の枠。文字の位置を動かさずに周りへ広げて敷く（押せる文字のホバー中と、欄が出ている間）
struct InlineEditHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control).fill(.quaternary).padding(-Space.inline)
    }
}

/// 押すとその場の欄に変わる文字。Mac はホバーで枠が出て、iPhone と iPad は長押しのメニューからも入る。
/// 読み上げにはボタンとして伝える
private struct InlineEditTarget: ViewModifier {
    let menuTitle: LocalizedStringKey
    let hint: LocalizedStringKey
    let begin: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: begin)
            #if os(macOS)
            .onHover { hovering = $0 }
            .background { if hovering { InlineEditHighlight() } }
            #else
            .contextMenu { Button(menuTitle, systemImage: "pencil", action: begin) }
            #endif
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
    }
}

extension View {
    /// 押すとその場の欄に変わる文字にする。`menuTitle` は iPhone と iPad の長押しの項目（「題を編集」）、`hint` は読み上げ（「押すと題を編集できます」）
    func inlineEditTarget(menuTitle: LocalizedStringKey, hint: LocalizedStringKey, begin: @escaping () -> Void) -> some View {
        modifier(InlineEditTarget(menuTitle: menuTitle, hint: hint, begin: begin))
    }
}
