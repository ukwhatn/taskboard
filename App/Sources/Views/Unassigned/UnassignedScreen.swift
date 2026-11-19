import SwiftUI
import TaskboardKit

/// マシンのタスクなしの画面（サイドバーのマシンの「タスクなし」、`taskboard://unassigned/<machine>`）。どのタスクにも紐づいていない
/// 会話・定期起動を種類ごとに件数付きで並べる（件数の和がサイドバーの数）。PR は一覧に並べず、通知・URL からタスクに結ばれていない PR を開いたときだけここで開く。
/// 会話と PR は、行の［ほかの操作］と開いた画面の上の帯から、タスクを追加して紐づけるか既存のタスクに紐づける。
/// 行を押すとその場で開き、［一覧に戻る］で戻る（iPhone は会話を積む）
struct UnassignedScreen: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID

    @State private var opened: ConversationKey?
    @State private var expandedSchedules: Set<ScheduleKey> = []
    @State private var linking: TaskLinkTarget?

    var body: some View {
        let contents = model.unassigned(on: machine)
        content(contents)
            .navigationTitle("タスクなし")
            .sheet(item: $linking) { TaskLinkSheet(target: $0) }
            .onChange(of: model.sessionFocus, initial: true) { _, focus in
                guard let focus, focus.scope == .unassigned(machine) else { return }
                open(focus.item)
                model.sessionFocus = nil
            }
            .onChange(of: model.prFocusRequest) { _, _ in opened = nil }
    }

    @ViewBuilder
    private func content(_ contents: UnassignedContents) -> some View {
        if let url = model.selectedPR, model.tasks(linkedTo: url).isEmpty, let pr = model.fleet.pullRequest(url: url) {
            VStack(spacing: 0) {
                OpenedBar(target: .pullRequest(url: pr.url, title: pr.title, machine: machine), link: { linking = $0 }) { model.selectedPR = nil }
                Divider()
                PRDetailView(url: pr.url, preferring: machine).id(pr.url)
            }
        } else if !AppModel.isPhone, let item = opened, let row = contents.sessions.rows.first(where: { $0.conversation.key == item }) {
            VStack(spacing: 0) {
                OpenedBar(target: .conversation(item), link: { linking = $0 }) { opened = nil }
                Divider()
                ConversationStage(conversation: row.conversation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if contents.isEmpty {
            EmptyState("タスクに紐づいていないものはありません", symbol: "tray")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list(contents)
        }
    }

    private func list(_ contents: UnassignedContents) -> some View {
        Page(maxWidth: ReadableWidth.text) {
            if !contents.sessions.rows.isEmpty {
                PageSection(String(localized: "会話（\(contents.sessions.rows.count)件）")) {
                    let reserves = contents.sessions.rows.contains { model.canAttach(.conversation($0.conversation.key)) }
                    VStack(alignment: .leading, spacing: Space.row) {
                        ForEach(contents.sessions.rows, id: \.conversation.id) { row in
                            let target = TaskLinkTarget.conversation(row.conversation.key)
                            HStack(spacing: Space.row) {
                                conversationLink(row.conversation)
                                AttachMenu(target: target, reservesSpace: reserves) { linking = $0 }
                            }
                            .contextMenu { AttachItems(target: target) { linking = $0 } }
                        }
                    }
                }
            }
            if !contents.schedules.isEmpty {
                PageSection(String(localized: "定期起動（\(contents.schedules.count)件）")) {
                    VStack(alignment: .leading, spacing: Space.block) {
                        ScheduleRows(schedules: contents.schedules, expanded: $expandedSchedules)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// iPhone は会話を積み、ほかはその場で開く
    @ViewBuilder
    private func conversationLink(_ conversation: Conversation) -> some View {
        if AppModel.isPhone {
            NavigationLink(value: PhoneRoute.conversation(conversation.key)) { ConversationLinkRow(conversation: conversation) }
                .buttonStyle(.plain)
        } else {
            Button { open(conversation.key) } label: { ConversationLinkRow(conversation: conversation) }
                .buttonStyle(.plain)
        }
    }

    private func open(_ item: ConversationKey) {
        opened = item
        model.selectedPR = nil
    }
}

/// 開いた会話・PR の上の帯。左に［一覧に戻る］、右に［タスクを追加…］［タスクに紐づける…］
private struct OpenedBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let target: TaskLinkTarget
    let link: (TaskLinkTarget) -> Void
    let back: () -> Void

    var body: some View {
        HStack(spacing: Space.row) {
            Button("一覧に戻る", systemImage: "chevron.left", action: back)
                .hitTarget()
            Spacer(minLength: Space.row)
            AttachItems(target: target, link: link)
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, inset)
        .padding(.vertical, Space.inline)
    }
}

/// ［タスクを追加…］［タスクに紐づける…］。書き込めない接続先と、オーケストレーターと、会話 ID がまだ無い会話には出さない
private struct AttachItems: View {
    @Environment(AppModel.self) private var model
    let target: TaskLinkTarget
    let link: (TaskLinkTarget) -> Void

    var body: some View {
        if model.canAttach(target) {
            Button("タスクを追加", systemImage: "plus.square") { model.newTaskSheet = model.newTaskDraft(for: target) }
                .disabled(model.orderedBoards(on: target.machine).isEmpty)
            Button("タスクに紐づける…", systemImage: "link") { link(target) }
        }
    }
}

/// 一覧の行の右の［ほかの操作］。中身は `AttachItems`。`reservesSpace` なら、出さない行にも同じ幅を空ける（行の右端を揃える）
private struct AttachMenu: View {
    @Environment(AppModel.self) private var model
    let target: TaskLinkTarget
    var reservesSpace = false
    let link: (TaskLinkTarget) -> Void

    var body: some View {
        if !model.canAttach(target) {
            if reservesSpace { label.hitTarget().hidden() }
        } else {
            Menu {
                AttachItems(target: target, link: link)
            } label: {
                label
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hitTarget()
            .help("ほかの操作")
            .accessibilityLabel("ほかの操作")
        }
    }

    private var label: some View { Image(systemName: "ellipsis.circle") }
}
