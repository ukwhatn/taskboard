import SwiftUI
import TaskboardKit

/// マシンの行の右クリックの［使っていないworktreeを削除…］で開くシートの対象
struct WorktreeCleanupTarget: Identifiable, Hashable {
    let machine: MachineID
    var id: String { machine.rawValue }
}

/// シートの段階。一覧を読み、選んで削除し、結果を 1 件ずつ出す
enum WorktreeCleanupPhase: Equatable {
    case loading
    /// 一覧を読めなかった（理由は下の帯。「ありません」とは言わない）
    case failed
    case loaded([WorktreeInfo])
    case finished([WorktreeRemoveResult])
}

/// 使っていないworktreeの削除。daemon が一覧に付けた「消せるか」で印を付けられるものを決め、［削除］を押すと daemon が 1 件ずつ今の状態を読み直して
/// 消せるものだけ消す。消すのは worktree とブランチ
struct WorktreeCleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machine: MachineID
    @State private var phase = WorktreeCleanupPhase.loading
    @State private var selection: Set<String> = []
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        WorktreeCleanupView(
            phase: phase, machineName: model.machineName(machine), selection: $selection, working: working, error: error,
            onDelete: { confirming = true }, onClose: { dismiss() }
        )
        .confirmationDialog("worktreeの削除", isPresented: $confirming, titleVisibility: .visible) {
            Button("削除", role: .destructive, action: remove)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .task { await load() }
    }

    private var selected: [WorktreeInfo] {
        guard case .loaded(let worktrees) = phase else { return [] }
        return worktrees.filter { selection.contains($0.path) }
    }

    private var confirmationMessage: String {
        let lines = selected.map { info in
            info.branch.map { "・\($0)（\(info.path)）" } ?? "・\(info.path)"
        }
        let head = String(localized: "選んだ\(selected.count)件のworktreeを削除しますか？　フォルダとブランチが消えます。この操作は元に戻せません。")
        return ([head] + lines).joined(separator: "\n")
    }

    private func load() async {
        do {
            phase = .loaded(try await model.requireSource(machine).worktrees())
        } catch {
            self.error = UserFacingError("worktreeを読み込めませんでした", error: error)?.text
            phase = .failed
        }
    }

    private func remove() {
        let paths = selected.map(\.path)
        guard !paths.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                phase = .finished(try await model.requireSource(machine).removeWorktrees(paths: paths))
            } catch {
                self.error = UserFacingError("worktreeを削除できませんでした", error: error)?.text
            }
            working = false
        }
    }
}

/// シートの中身。状態を持たず、`WorktreeCleanupSheet` が段階と選択を渡す（snapshot test も同じものを描く）
struct WorktreeCleanupView: View {
    let phase: WorktreeCleanupPhase
    let machineName: String
    @Binding var selection: Set<String>
    var working = false
    var error: String?
    var onDelete: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        SheetScaffold(
            title: String(localized: "使っていないworktreeの削除"), subtitle: machineName, error: error,
            notice: notice, width: 560,
            onCancel: isFinished ? nil : onClose
        ) {
            switch phase {
            case .loading:
                Section { Text("読み込み中…").foregroundStyle(.secondary) }
            case .loaded(let worktrees):
                loadedSections(worktrees)
            case .failed:
                EmptyView()
            case .finished(let results):
                Section("結果") {
                    ForEach(results) { WorktreeResultRow(result: $0) }
                }
            }
        } actions: {
            if isFinished {
                Button("閉じる", action: onClose).keyboardShortcut(.defaultAction)
            } else {
                Button("削除", role: .destructive, action: onDelete)
                    .disabled(selection.isEmpty || working)
            }
        }
    }

    private var isFinished: Bool {
        if case .finished = phase { return true }
        return false
    }

    private var notice: String? {
        guard case .loaded(let worktrees) = phase, error == nil else { return nil }
        let shown = Self.visible(worktrees)
        guard !shown.isEmpty else { return nil }
        return selection.isEmpty
            ? String(localized: "削除するworktreeを選んでください。") : String(localized: "\(selection.count)件を選んでいます。")
    }

    /// repo の本体の checkout は worktree として消す対象でないので出さない（daemon も本体は消さない）
    static func visible(_ worktrees: [WorktreeInfo]) -> [WorktreeInfo] {
        worktrees.filter { info in !info.blockers.contains { $0.kind == .main } }
    }

    @ViewBuilder
    private func loadedSections(_ worktrees: [WorktreeInfo]) -> some View {
        let groups = Dictionary(grouping: Self.visible(worktrees), by: \.repo).sorted { $0.key < $1.key }
        if groups.isEmpty {
            Section { Text("worktreeはありません").foregroundStyle(.secondary) }
        }
        ForEach(groups, id: \.key) { repo, infos in
            Section((repo as NSString).lastPathComponent) {
                // 消せるものが先
                ForEach(infos.sorted { ($0.removable ? 0 : 1, $0.path) < ($1.removable ? 0 : 1, $1.path) }) { info in
                    WorktreeRow(
                        info: info,
                        selected: Binding(
                            get: { selection.contains(info.path) },
                            set: { if $0 { selection.insert(info.path) } else { selection.remove(info.path) } }))
                }
            }
        }
    }
}

/// 一覧の 1 件。消せるものは印を付けられ、消せないものは理由を並べて選べない
private struct WorktreeRow: View {
    let info: WorktreeInfo
    @Binding var selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Toggle(isOn: $selected) { Text(verbatim: title) }
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .disabled(!info.removable)
                .accessibilityLabel(title)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).textRole(.title)
                Text(verbatim: info.path).textRole(.mono).foregroundStyle(.secondary)
                if let base = info.base {
                    Text("比べ先：\(base)").textRole(.caption).foregroundStyle(.secondary)
                }
                ForEach(info.blockers, id: \.self) { blocker in
                    BlockerLabel(text: blocker.text(base: info.base))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String { info.branch ?? (info.path as NSString).lastPathComponent }
}

/// 消せない理由 1 つ。印だけを注意の色にする（オレンジの文字は明るい地で読みにくい）
private struct BlockerLabel: View {
    let text: String

    var body: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
        }
        .textRole(.secondary)
    }
}

/// 削除の結果 1 件
private struct WorktreeResultRow: View {
    let result: WorktreeRemoveResult

    var body: some View {
        HStack(alignment: .top, spacing: Space.row) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result.branch ?? (result.path as NSString).lastPathComponent).textRole(.title)
                Text(verbatim: result.path).textRole(.mono).foregroundStyle(.secondary)
                Text(headline).textRole(.secondary)
                ForEach(result.blockers, id: \.self) { blocker in
                    BlockerLabel(text: blocker.text(base: nil))
                }
                // git が断った文は、そのまま理由として出す
                if let message = result.message {
                    Text(verbatim: message).textRole(.secondary).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        switch result.outcome {
        case .removed:
            if result.branch == nil { return String(localized: "worktreeを削除しました。") }
            return result.branchDeleted
                ? String(localized: "worktreeとブランチを削除しました。") : String(localized: "worktreeを削除しました。ブランチは残っています。")
        case .refused:
            return String(localized: "削除しませんでした。")
        case .failed:
            return String(localized: "削除できませんでした。")
        }
    }

    private var symbol: String {
        switch result.outcome {
        case .removed: result.branchDeleted || result.branch == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .refused: "minus.circle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch result.outcome {
        case .removed: result.branchDeleted || result.branch == nil ? .green : .orange
        case .refused: .secondary
        case .failed: .red
        }
    }
}

extension WorktreeBlocker {
    /// 消せない理由の文（docs/ui-copy.md）。`base` は未マージの比べ先
    func text(base: String?) -> String {
        let n = count ?? 0
        switch kind {
        case .main: return String(localized: "repoの本体のフォルダです")
        case .locked: return String(localized: "ロックされています")
        case .inUse: return String(localized: "使っているセッションがあります（\(n)件）")
        case .uncommitted: return String(localized: "未コミットの変更があります（\(n)件）")
        case .untracked: return String(localized: "追跡していないファイルがあります（\(n)件）")
        case .unpushed: return String(localized: "pushしていないコミットがあります（\(n)件）")
        case .unmerged:
            return base.map { String(localized: "\($0)に入っていないコミットがあります（\(n)件）") }
                ?? String(localized: "比べ先に入っていないコミットがあります（\(n)件）")
        case .noBase: return String(localized: "比べ先のブランチが見つかりません")
        case .noBranch: return String(localized: "ブランチがありません")
        case .missing: return String(localized: "フォルダがありません")
        case .unknown: return String(localized: "状態を調べられませんでした")
        }
    }
}
