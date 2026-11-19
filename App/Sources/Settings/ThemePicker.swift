import GhosttyTheme
import SwiftUI

/// 端末のテーマを選ぶ先（ライトとダーク）
enum ThemeSlot: String, Identifiable {
    case light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: String(localized: "ライトのテーマ")
        case .dark: String(localized: "ダークのテーマ")
        }
    }
}

/// 端末のテーマの一覧。数百あるので、名前で絞り込んで選ぶ（docs/ui-system.md「選択の形」）。押すとすぐ決まって閉じる
struct ThemePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let slot: ThemeSlot
    @Binding var selection: String
    @State private var query = ""

    static let names = GhosttyThemeCatalog.allThemes.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    var body: some View {
        let matches = query.isEmpty ? Self.names : Self.names.filter { $0.localizedCaseInsensitiveContains(query) }
        SheetScaffold(title: slot.title, onCancel: { dismiss() }) {
            Section {
                FormSearchField(query: $query)
            }
            Section {
                if matches.isEmpty {
                    Text("条件に合うテーマはありません").foregroundStyle(.secondary)
                }
                ForEach(matches, id: \.self) { name in
                    Button {
                        selection = name
                        dismiss()
                    } label: {
                        HStack(spacing: Space.row) {
                            Text(verbatim: name).foregroundStyle(.primary)
                            Spacer(minLength: Space.row)
                            if name == selection {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(name == selection ? .isSelected : [])
                }
            }
        } actions: {
            EmptyView()
        }
        #if os(macOS)
        .frame(minHeight: SheetMetrics.themeMinHeight)
        #endif
    }
}
