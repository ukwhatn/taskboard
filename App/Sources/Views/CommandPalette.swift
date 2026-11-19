import SwiftUI
import TaskboardKit

/// ⌘K。タスク・セッション・PR・案件・コマンドと会話の発言を 1 つの欄から探して実行する。↑↓ とホバーで選び、↩ で実行、⌘↩ でタスクを別ウィンドウに開く
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    @State private var query = ""
    @State private var selection = 0
    /// 会話の全文検索の一致（打ち終えてから daemon に引く）
    @State private var conversations: [PaletteEntry] = []
    @State private var indexing = false
    @FocusState private var focused: Bool

    var body: some View {
        let all = model.paletteEntries
        let results = PaletteSearch.rank(all, query: query) + conversations
        VStack(spacing: 0) {
            HStack(spacing: Space.row) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("タスク・セッション・PR・案件・コマンド・会話を検索", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(results[safe: selection]) }
                    .onKeyPress(.upArrow) { step(-1, count: results.count); return .handled }
                    .onKeyPress(.downArrow) { step(1, count: results.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(Space.card)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            Button {
                                run(entry)
                            } label: {
                                PaletteRow(entry: entry, selected: index == selection)
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                            .onHover { inside in if inside { selection = index } }
                        }
                    }
                    .padding(.vertical, Space.inline)
                    if indexing {
                        Text("検索の準備中のため、まだ出ない会話があります")
                            .textRole(.caption)
                            .padding(.horizontal, Space.card)
                            .padding(.bottom, Space.row)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .onChange(of: selection) { _, index in
                    if let entry = results[safe: index] { proxy.scrollTo(entry.id) }
                }
            }
            .overlay {
                if results.isEmpty {
                    Text("条件に合う項目はありません").textRole(.secondary)
                }
            }
        }
        // ⌘↩ はメニューの［別ウィンドウで開く］が先に受け、パレットが開いていればここへ回す（TaskboardApp.swift）
        .onChange(of: model.paletteOpenSeparatelyRequests) { _, _ in
            if let entry = results[safe: selection] { openSeparately(entry) }
        }
        #if os(macOS)
        .frame(width: SheetMetrics.palette.width, height: SheetMetrics.palette.height)
        #endif
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .task(id: query) {
            // 1 字ごとに daemon を引かない
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.paletteConversations(matching: query)
            guard !Task.isCancelled else { return }
            conversations = found.entries
            indexing = found.indexing
        }
    }

    private func step(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func run(_ entry: PaletteEntry?) {
        guard let entry else { return }
        dismiss()
        model.runPalette(entry, query: query)
    }

    private func openSeparately(_ entry: PaletteEntry) {
        guard entry.kind == .task, supportsMultipleWindows, let key = entry.taskKey else { return run(entry) }
        dismiss()
        model.paletteOpen = false
        openWindow(value: key)
    }
}

/// 1 行。選んでいる行は背景で示し、読み上げにも伝える。ボタンの中身なので押せる範囲は行全体
private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.block) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).textRole(.caption)
                }
            }
            Spacer(minLength: Space.block)
            if let shortcut = entry.shortcut {
                Text(shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var symbol: String {
        switch entry.kind {
        case .command: "command"
        case .task: "square.text.square"
        case .pullRequest: "arrow.triangle.pull"
        case .board: "rectangle.grid.2x2"
        case .conversation: "text.bubble"
        }
    }
}

extension PaletteEntry {
    /// タスクの行なら、そのタスク
    var taskKey: TaskKey? {
        if case .task(let key, _, _, _)? = destination { key } else { nil }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
