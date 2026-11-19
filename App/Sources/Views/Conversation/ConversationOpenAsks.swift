import SwiftUI
import TaskboardKit

/// 会話が `ask_user`・`doc_publish` で出した文書の質問のうち、まだ答えていないもの。答えるのは文書の画面で、ここは入口だけにする
struct ConversationOpenAsks: View {
    @Environment(AppModel.self) private var model
    let feed: ConversationFeed
    let machine: MachineID

    var body: some View {
        let asks = model.fleet.machineState(for: machine)?.asks ?? [:]
        let open = Self.unanswered(DocumentToolRef.refs(in: feed.messages)) { asks[AskKey(machine: machine, id: $0)]?.status == .open }
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: Space.inline) {
                ForEach(open, id: \.askID) { document in
                    HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                        Text("未回答の質問\(document.questionCount ?? 1)問・\(document.docName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                        ChipButton(text: String(localized: "質問を開く")) { model.open(document.url, from: .link) }
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 同じ質問の束は 1 つにする（再 publish で同じ束を返す）
    static func unanswered(_ refs: [DocumentToolRef], isOpen: (Int64) -> Bool) -> [DocumentToolRef] {
        var seen: Set<Int64> = []
        return refs.filter { ref in
            guard let id = ref.askID, isOpen(id) else { return false }
            return seen.insert(id).inserted
        }
    }
}

/// 会話のタスクで頼まれている手作業（作業項目の手作業待ち）。頼んだ文をそのまま出し、［対応済みにする］で作業中に戻して済んだことを会話へ届ける
struct ConversationManualWork: View {
    @Environment(AppModel.self) private var model
    let key: ConversationKey

    var body: some View {
        let items = model.manualWork(forConversation: key)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.inline) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                        Text("手作業の依頼：\(item.blockerText.isEmpty ? item.codedTitle : item.blockerText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .layoutPriority(-1)
                        ChipButton(text: String(localized: "対応済みにする")) { model.finishManualWork(item) }
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
