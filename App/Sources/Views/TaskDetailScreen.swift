import SwiftUI
import TaskboardKit

/// iPhone のタスク画面。題と待ち理由、会話（委譲先を含む）、右の欄と同じ切り替え（文書・作業項目・状態・差分）を縦に並べる。
/// 会話を押すとその画面へ進む。題とメモは押してその場で直し、リンクはチップの並びの＋で足す。削除は上のバーのメニュー、リンクを外すのは長押し。Mac と iPad はパネル（`TaskPanel`）
struct TaskDetailScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let key: TaskKey
    @State private var deleting: BoardTask?
    @State private var editing: TaskEditSheet?

    var body: some View {
        if let task = model.fleet.task(for: key) {
            content(task)
        } else {
            EmptyState("このタスクはありません", symbol: "questionmark.square.dashed", message: "削除されたか、接続していないMacのタスクです。")
        }
    }

    private func content(_ task: BoardTask) -> some View {
        let sessions = model.taskSessions(for: task)
        let conversations = sessions.conversations
        let canLaunch = model.canWrite(key.machine)
        let canEdit = model.canWrite(task.machine)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                TaskHeader(task: task, signals: model.cardSignals(for: task), showsNote: false, editable: canEdit)
                VStack(alignment: .leading, spacing: Space.section) {
                    if !conversations.isEmpty || canEdit {
                        PageSection("会話") {
                            VStack(alignment: .leading, spacing: Space.row) {
                                ForEach(conversations) { conversation in
                                    NavigationLink(value: PhoneRoute.conversation(conversation.key)) {
                                        ConversationLinkRow(conversation: conversation)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { ConversationMenuItems(conversation: conversation) }
                                }
                                if canEdit {
                                    Button("セッションを紐づける…", systemImage: "link") { editing = .sessions }
                                        .buttonStyle(.borderless)
                                        .hitTarget()
                                }
                            }
                        }
                    }
                    TaskSidePane(task: task, editable: canEdit) { model.phoneTaskItem = $0 }
                        .environment(\.pageInset, 0)
                }
                .padding(.horizontal, inset)
            }
        }
        .contentMargins(.vertical, Space.block, for: .scrollContent)
        .navigationTitle("#\(task.number)")
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("起動", systemImage: "play.fill") { model.launchSheet = model.launchDraft(for: task) }
                    .disabled(!canLaunch)
            }
            if model.canWrite(task.machine) {
                ToolbarItem(placement: .secondaryAction) {
                    TaskDeleteButton(task: task, target: $deleting)
                }
            }
        }
        .taskDeleteDialog($deleting)
        .taskSessionSheets(task: task, launch: Binding(get: { model.launchSheet }, set: { model.launchSheet = $0 }), editing: $editing)
        // 文書の切り替えでシートを出し直さないよう、出すかどうかだけを item にせず Bool で持ち、中身が開いている文書を読む
        .sheet(isPresented: docSheetShown) {
            NavigationStack {
                DocumentSheetContent(task: key)
            }
        }
    }

    /// 文書はシートで出す
    private var docSheetShown: Binding<Bool> {
        Binding(
            get: { model.openDoc(in: key) != nil },
            set: { if !$0 { model.closeDoc() } })
    }
}

/// iPhone の文書のシートの中身。開いている文書が変わると、シートを開いたまま差し替える
struct DocumentSheetContent: View {
    @Environment(AppModel.self) private var model
    let task: TaskKey
    /// 閉じる途中（`openDoc` が nil になった後）も最後の文書を描く
    @State private var last: DocKey?

    var body: some View {
        let key = model.openDoc(in: task) ?? last
        Group {
            if let key {
                DocumentScreen(key: key, inSheet: true).id(key)
            }
        }
        .onChange(of: model.openDoc(in: task), initial: true) { _, shown in
            if let shown { last = shown }
        }
    }
}

/// 会話の 1 行（iPhone のタスク画面、タスクなしの画面、紐づけのシート）。状態・題
struct ConversationLinkRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let conversation: Conversation

    var body: some View {
        HStack(spacing: Space.row) {
            StatusGlyph(conversation: conversation)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle).font(.body).lineLimit(1)
                HStack(spacing: Space.inline) {
                    Text(model.statusText(of: conversation, now: today)).textRole(.caption)
                    BackgroundTasksGlyph(conversation: conversation)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: HitTarget.size)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// iPhone と iPad のナビゲーションバーの題を小さく出す（Mac では何もしない）
    func navigationBarTitleDisplayModeInline() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
