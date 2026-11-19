import SwiftUI
import TaskboardKit

/// 同じタスクの文書の並びの中の前後。並びは `DocumentList` と同じ（`Fleet.documents(for:)` の新しい順）。
/// 今の文書が並びに無ければ（削除された）、前も次も無い
struct DocumentSequence {
    let documents: [Document]
    let current: DocKey

    init(documents: [Document], current: DocKey) {
        self.documents = documents
        self.current = current
    }

    @MainActor
    init(model: AppModel, current: DocKey) {
        let task = model.fleet.document(for: current).map { TaskKey(machine: $0.machine, number: $0.taskNumber) }
        self.init(documents: task.map { model.fleet.documents(for: $0) } ?? [], current: current)
    }

    /// 切り替えられる文書があるか（2 つ以上）
    var canSwitch: Bool { documents.count > 1 }

    private var index: Int? { documents.firstIndex { $0.id == current } }

    /// 一覧で 1 つ上（新しい方）
    var previous: DocKey? {
        guard let index, index > 0 else { return nil }
        return documents[index - 1].id
    }

    /// 一覧で 1 つ下（古い方）
    var next: DocKey? {
        guard let index, index + 1 < documents.count else { return nil }
        return documents[index + 1].id
    }
}

/// 文書の画面で Esc を押したときにすること。書きかけの文を失わないよう、閉じる前に入力を見る
enum DocumentEscape: Equatable {
    /// 空のコメントの入力欄を閉じる（文書は開いたまま）
    case closeComposer
    /// 書きかけの文があるので何もしない（［キャンセル］か［戻る］で明示して閉じる）
    case keep
    case closeDocument

    /// - Parameters:
    ///   - composerText: コメントの入力欄の文。入力欄を開いていなければ nil
    ///   - pendingInput: 返信・質問の回答の書きかけがあるか（`DocumentPendingInputKey`）
    static func action(composerText: String?, pendingInput: Bool) -> Self {
        if let composerText {
            return composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .closeComposer : .keep
        }
        return pendingInput ? .keep : .closeDocument
    }
}

/// 文書の画面の中に、送っていない入力（返信・質問の回答・コメント）があるか。中の部品が立て、文書の画面とタスクのパネルが Esc の前に見る
struct DocumentPendingInputKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// 前・次の文書のボタン（⌥⌘↑ / ⌥⌘↓）。端では押せない
struct DocumentStepButtons: View {
    let sequence: DocumentSequence
    let switchTo: (DocKey) -> Void

    var body: some View {
        Button("前の文書を表示", systemImage: "chevron.up") { if let previous = sequence.previous { switchTo(previous) } }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .hitTarget()
            .disabled(sequence.previous == nil)
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .help("前の文書を表示")
        Button("次の文書を表示", systemImage: "chevron.down") { if let next = sequence.next { switchTo(next) } }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .hitTarget()
            .disabled(sequence.next == nil)
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .help("次の文書を表示")
    }
}

/// 文書の題。押すと同じタスクの文書の一覧が出て、選ぶと切り替わる。文書が 1 つだけなら題を出すだけ
struct DocumentTitleMenu<Label: View>: View {
    let sequence: DocumentSequence
    let switchTo: (DocKey) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if sequence.canSwitch {
            Menu {
                Picker("文書", selection: Binding(get: { sequence.current }, set: { if $0 != sequence.current { switchTo($0) } })) {
                    ForEach(sequence.documents) { doc in
                        Text(doc.displayTitle).tag(doc.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                    label()
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityHint("押すと同じタスクの文書を選べます")
            .help("文書を切り替える")
        } else {
            label()
        }
    }
}
