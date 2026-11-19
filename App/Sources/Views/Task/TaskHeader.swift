import SwiftUI
import TaskboardKit

/// タスクの題と、列・リンク・期日のチップ。チップの段の右に `accessory`（タスクの画面では会話の札の行）を置き、その下に会話が帯に置いた計器（`PanelBand`）。
/// 待ち理由と対応待ちは、会話の中の権限・質問のカードとカードの右クリックの［対応待ちを非表示］で扱い、ここには出さない。
/// チップは入り切らなければ次の行へ送る（横に流すとパネルの端で切れる）。完了したリンクは後ろに並べ、多ければ［完了した{n}件を表示］に畳む
struct TaskHeader<Accessory: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    @Environment(\.today) private var today
    @Environment(\.pageInset) private var inset
    let task: BoardTask
    let signals: CardSignals
    /// パネルではメモを詳細の欄に全文で出すので、ここでは出さない
    var showsNote = true
    /// 題をその場で直せるか（書き込める接続先）。false なら題は選んでコピーできる文字のまま
    var editable = false
    @ViewBuilder var accessory: () -> Accessory

    @TaskState private var editing = false
    @TaskState private var draft = ""
    /// 保存を送った題。daemon から新しい題が届くまで、これを出す（確定した瞬間に元の題へ戻って見えないように）
    @TaskState private var pending = PendingValue<String>()
    @TaskState private var addingLink = false
    @TaskState private var linkDraft = ""
    /// 完了したリンク（マージ済み・クローズの PR など）を、畳んだ札から広げているか
    @TaskState private var showsSettled = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            title
            // チップと帯は次の回に組む（初めてパネルを開く回で、列の Menu とリンクのチップが 20 ms ほどかかった）
            DeferredMount { details }
            // 会話が帯に置いた計器（無ければ何も描かない）
            PanelBand(task: task)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.bottom, Space.block)
    }

    /// チップと右の部品、メモ
    private var details: some View {
        let board = model.fleet.board(id: task.boardID, on: task.machine)
        let statuses = Dictionary(signals.links.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: Space.row) {
            // チップと会話の札の行が 1 段に入れば並べ、入らなければ札の行を下の段に送る（狭いパネルで札を横に送ると、選んでいる札が途中で切れた）
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Space.block) {
                    chips(board: board, statuses: statuses).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    accessory().fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: Space.row) {
                    chips(board: board, statuses: statuses)
                    accessory()
                }
            }
            if showsNote && !task.note.isEmpty {
                Text(task.note).textRole(.secondary).lineLimit(3)
            }
        }
    }

    /// 列・リンク・期日のチップ。入り切らなければ次の行へ送る
    private func chips(board: Board?, statuses: [String: LinkStatus]) -> some View {
        FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
            if let board {
                Menu {
                    ForEach(board.orderedColumns) { column in
                        Button(column.label) { model.move(task: task, to: column.id) }.disabled(column.id == task.columnID)
                    }
                } label: {
                    Text(board.columns.first { $0.id == task.columnID }?.label ?? task.columnID)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .accessibilityLabel("列：\(board.columns.first { $0.id == task.columnID }?.label ?? task.columnID)")
                .accessibilityHint("押すと移動先の列を選べます")
            }
            let order = TaskLink.ordered(task.links, statuses: statuses)
            let collapses = order.settled.count > TaskHeaderMetrics.settledLinksShown
            ForEach(order.active) { link in linkChip(link, status: statuses[link.url]) }
            if collapses {
                ChipButton(
                    text: showsSettled ? String(localized: "完了した\(order.settled.count)件を非表示") : String(localized: "完了した\(order.settled.count)件を表示"),
                    symbol: showsSettled ? "chevron.down" : "chevron.right"
                ) { showsSettled.toggle() }
                .help("マージ済み・クローズのPRと完了したリンク")
            }
            if !collapses || showsSettled {
                ForEach(order.settled) { link in linkChip(link, status: statuses[link.url]) }
            }
            if let due = task.due {
                let label = TaskCard.dueLabel(due, today: today)
                Chip(text: label, symbol: "calendar")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("期日\(label)")
            }
            if editable {
                addLink
            }
        }
    }

    /// リンクのチップ。PR は詳細の欄で中身を出す（GitHub へはそこから）
    @ViewBuilder
    private func linkChip(_ link: TaskLink, status: LinkStatus?) -> some View {
        if link.kind == .githubPR {
            Button {
                model.show(pr: link.url)
            } label: {
                LinkChip(link: link, status: status)
            }
            .buttonStyle(.plain)
            .help("PRの中身を見る")
            .contextMenu { TaskLinkMenuItems(task: task, link: link) }
        } else if let url = URL(string: link.url) {
            Link(destination: url) { LinkChip(link: link, status: status) }
                .buttonStyle(.plain)
                .help(link.url)
                .contextMenu { TaskLinkMenuItems(task: task, link: link) }
        }
    }

    /// 題。直せるときは押すとその場で欄になり、↩ か欄の外を押すと保存、Esc で元に戻す（`InlineField`）。文字の選択は外す（押したときに選択が先に取ってしまうため）
    @ViewBuilder
    private var title: some View {
        let font = Font.title3.weight(.semibold)
        if editing {
            InlineField(label: String(localized: "タイトル"), text: $draft, font: .title, lines: 1...3, commit: commit, cancel: cancel)
        } else {
            let text = Text(pending.shown(task.title))
                .font(font)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(task.title)
            if editable {
                text
                    .inlineEditTarget(menuTitle: "タイトルを編集", hint: "押すとタイトルを編集できます") {
                        draft = pending.shown(task.title)
                        editing = true
                    }
                    .onChange(of: task.title) { _, _ in pending.settle() }
            } else {
                text.textSelection(.enabled)
            }
        }
    }

    private func cancel() {
        editing = false
    }

    /// 確定。空白だけ・元のままなら送らない。送った題は daemon の新しい題が届くまで出し続ける
    private func commit() {
        editing = false
        guard let title = AppModel.titleChange(draft, from: task.title) else { return }
        pending.send(title)
        Task {
            do {
                try await model.saveTitle(title, of: task)
            } catch {
                pending.failed(title)
                model.fail("タスクを保存できませんでした", error, in: window)
            }
        }
    }

    // MARK: リンクの追加

    /// チップの並びの末尾の＋。押すと URL の欄になり、↩ か欄の外を押すと足す（空白で区切って複数可。このタスクにある URL は除く）。Esc で取りやめ
    @ViewBuilder
    private var addLink: some View {
        if addingLink {
            InlineField(label: String(localized: "リンクのURL"), text: $linkDraft, font: .callout, lines: 1...1, prompt: "https://", commit: commitLink) {
                addingLink = false
            }
            .frame(minWidth: TaskHeaderMetrics.linkField.lowerBound, maxWidth: TaskHeaderMetrics.linkField.upperBound)
        } else {
            ChipButton(text: String(localized: "リンクを追加"), symbol: "plus") {
                linkDraft = ""
                addingLink = true
            }
        }
    }

    private func commitLink() {
        addingLink = false
        let urls = AppModel.newLinks([linkDraft], existing: task.links)
        guard !urls.isEmpty else { return }
        Task {
            do {
                try await model.addLinks(urls, to: task)
            } catch {
                model.fail("リンクを追加できませんでした", error, in: window)
            }
        }
    }
}

extension TaskHeader where Accessory == EmptyView {
    init(task: BoardTask, signals: CardSignals, showsNote: Bool = true, editable: Bool = false) {
        self.init(task: task, signals: signals, showsNote: showsNote, editable: editable) { EmptyView() }
    }
}

/// リンクのチップの右クリック（iPhone と iPad は長押し）。確認は挟まない（外しても URL を足し直せる）
struct TaskLinkMenuItems: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    let link: TaskLink

    var body: some View {
        if model.canWrite(task.machine) {
            Button("このタスクから外す", systemImage: "minus.circle") { model.removeLink(link, from: task) }
        }
    }
}
