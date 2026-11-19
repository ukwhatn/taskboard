import SwiftUI
import TaskboardKit

/// チャットの上に出す検索の欄
struct ChatSearchBar: View {
    @Binding var search: ChatSearch
    let messages: [ChatMessage]
    let size: Double
    var focused: FocusState<Bool>.Binding

    var body: some View {
        let count = ChatSearch.rows(in: messages, query: search.activeQuery).count
        let fonts = ChatFonts(size: size)
        HStack(spacing: Space.row) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("会話を検索", text: $search.query)
                .textFieldStyle(.plain)
                .font(fonts.body)
                .focused(focused)
                // ↩ で古い方へ、⇧↩ で新しい方へ（端末の検索と同じ向き）
                .onSubmit { search.step(-1, count: count); focused.wrappedValue = true }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    search.step(1, count: count)
                    return .handled
                }
                .onKeyPress(.upArrow) { search.step(-1, count: count); return .handled }
                .onKeyPress(.downArrow) { search.step(1, count: count); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            if let label = search.label(count: count) {
                Text(label).font(fonts.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Button("前の一致", systemImage: "chevron.up") { search.step(-1, count: count) }
                .disabled(count == 0)
                .hitTarget()
            Button("次の一致", systemImage: "chevron.down") { search.step(1, count: count) }
                .disabled(count == 0)
                .hitTarget()
            Button("閉じる", systemImage: "xmark", action: close)
                .hitTarget()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.vertical, Space.row)
        .onChange(of: search.query) { _, _ in search.position = nil }
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
    }

    private func close() {
        search = ChatSearch()
        focused.wrappedValue = false
    }
}
