import SwiftUI
import TaskboardKit

/// 作業ディレクトリの欄。ブックマークと最近使ったもの（daemon の起動の記録と動いているセッション）を候補に出し、今の値をブックマークに足せる。
/// 空ならそのマシンのホームで起動する（daemon が決める）
struct WorkdirField: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    @Binding var path: String
    @State private var completions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        let dirs = model.workingDirectories[machine]
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let marked = dirs?.isBookmarked(trimmed) ?? false
        let suggestions = dirs?.suggestions(for: trimmed, completions: completions) ?? completions
        StackedField(String(localized: "作業フォルダ")) {
            VStack(alignment: .leading, spacing: Space.inline) {
                HStack(spacing: Space.inline) {
                    TextField("作業フォルダ", text: $path, prompt: Text(verbatim: "~/"))
                        .font(.body.monospaced())
                        .focused($focused)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #else
                        .textInputSuggestions(suggestions, id: \.self) { dir in
                            Text(verbatim: dir).textInputCompletion(dir)
                        }
                        #endif
                    Menu {
                        candidates(dirs)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .hitTarget()
                    .disabled(dirs?.candidates.isEmpty ?? true)
                    .accessibilityLabel("作業フォルダの候補")
                    .help("作業フォルダの候補")
                    Button {
                        model.toggleBookmark(trimmed, on: machine)
                    } label: {
                        Image(systemName: marked ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .disabled(trimmed.isEmpty || !model.canWrite(machine))
                    .accessibilityLabel(marked ? "ブックマークから外す" : "ブックマークに追加")
                    .help(marked ? "ブックマークから外す" : "ブックマークに追加")
                }
                #if os(iOS)
                // iOS には入力欄の候補の部品（textInputSuggestions）が無いので、打っている間だけ欄の下に並べる
                if focused, !suggestions.isEmpty {
                    ForEach(suggestions.prefix(6), id: \.self) { dir in
                        Button { path = dir } label: {
                            Text(verbatim: dir).font(.body.monospaced()).lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .hitTarget()
                    }
                }
                #endif
            }
        }
        .task(id: machine) { await model.refreshWorkingDirectories(on: machine) }
        .task(id: [machine.rawValue, trimmed]) {
            // 打つたびに引かないよう、打つ手が止まってから引く（次の文字で task が取り消される）
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            completions = await model.completeWorkingDirectory(trimmed, on: machine)
        }
    }

    @ViewBuilder
    private func candidates(_ dirs: WorkingDirectories?) -> some View {
        if let dirs {
            if !dirs.bookmarks.isEmpty {
                Section("ブックマーク") {
                    ForEach(dirs.bookmarks) { bookmark in
                        Button { path = bookmark.path } label: { Text(verbatim: bookmark.path) }
                    }
                }
            }
            let recent = dirs.recent.filter { !dirs.isBookmarked($0) }
            if !recent.isEmpty {
                Section("最近使ったもの") {
                    ForEach(recent, id: \.self) { dir in
                        Button { path = dir } label: { Text(verbatim: dir) }
                    }
                }
            }
        }
    }
}
