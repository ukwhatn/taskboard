import SwiftUI
import TaskboardKit

/// タスクの開いている質問と承認を待つ送る文面（右の欄の「文書」の節の先頭）。押すと文書を開き、本文の中のその欄まで送る
struct DocumentJudgments: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let documents: [Document]

    struct Item: Identifiable {
        var id: String
        var doc: Document
        var slot: String
        var symbol: String
        var title: String
        var detail: String
    }

    /// 文書の新しい順に、質問（束の中は並び順）、送る文面の順
    static func items(documents: [Document], asks: [Ask]) -> [Item] {
        documents.flatMap { doc -> [Item] in
            let questions = asks.filter { $0.docID == doc.docID && $0.status == .open }.flatMap { ask in
                ask.questions.map { q in
                    let recommended = q.options.first(where: \.isRecommended).map { String(localized: "推奨：\($0.displayLabel)") }
                    return Item(
                        id: "ask/\(ask.askID)/\(q.id)", doc: doc, slot: AppModel.formSlot(for: ask, question: q.id), symbol: "questionmark.bubble",
                        title: q.question, detail: [doc.displayTitle, recommended].compactMap { $0 }.joined(separator: "・"))
                }
            }
            let drafts = doc.openDrafts.map { draft in
                Item(
                    id: "draft/\(doc.docID)/\(draft.id)", doc: doc, slot: DocMarker(kind: .draft, id: draft.id).slot, symbol: "paperplane",
                    title: draft.draft.title.isEmpty ? String(localized: "送る文面の承認") : draft.draft.title,
                    detail: [String(localized: "宛先：\(draft.draft.to)"), doc.displayTitle].joined(separator: "・"))
            }
            return questions + drafts
        }
    }

    var body: some View {
        let state = model.fleet.machineState(for: task.machine)
        // 終わったタスクの待ちは古い記録なので出さない（受信箱と同じ）
        let terminal = state?.isTerminal(task) ?? false
        let items = terminal ? [] : Self.items(documents: documents, asks: state.map { Array($0.asks.values) } ?? [])
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.inline) {
                Text("判断待ち").textRole(.sectionTitle)
                ForEach(items) { item in
                    Button {
                        model.openDocument(item.doc.id, at: item.slot, from: .link)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Image(systemName: item.symbol).foregroundStyle(.orange).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout).lineLimit(1).truncationMode(.tail)
                                Text(item.detail).textRole(.caption).lineLimit(1).truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, Space.inline)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .help(item.title)
                }
            }
            .padding(.bottom, Space.block)
        }
    }
}
