import SwiftUI
import TaskboardKit

/// iPhone のタスク画面の欄。上の切り替えで、文書・作業項目・状態・差分のどれか 1 つを出す（Mac と iPad は `TaskSideArea` に並べる）。
/// 中の部品は左右の余白を持たない（この欄の余白に揃う）
struct TaskSidePane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let task: BoardTask
    /// メモをその場で直せるか（書き込める接続先）
    var editable = false
    /// 終了した会話を開く（札に無い会話を画面に出す）
    var openConversation: (ConversationKey) -> Void = { _ in }

    /// このタスクで選んだ欄
    @TaskState private var picked: SidePanel?
    @AppStorage(AppPreferences.taskSidePaneTabKey) private var preferred: SidePanel = .docs

    var body: some View {
        let filled = SidePanelBody.filled(task: task, conversation: nil, model: model)
        let side = PanelSideItem(task: task.id, model: model)
        // 選んだ部品の欄が外されたら、前に選んだ欄に戻す
        let tab = SidePanel.shown(picked: picked == .part && side == nil ? nil : picked, preferred: preferred, filled: filled)
        VStack(spacing: 0) {
            Picker("サイドパネル", selection: Binding(get: { tab }, set: { picked = $0; preferred = $0 })) {
                ForEach(SidePanel.phoneTabs(hasPart: side != nil)) { item in
                    Text(item == .part ? side?.title ?? item.label : item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, Space.row)
            Divider()
            SidePanelBody(panel: tab, task: task, editable: editable, scrolls: false, openConversation: openConversation)
        }
        .onChange(of: model.prFocusRequest) { _, _ in
            if task.pullRequestLinks.contains(where: { $0.url == model.selectedPR }) { picked = .status }
        }
    }
}

/// 右側の 1 つの欄の中身（Mac と iPad の格子の欄と、iPhone の切り替え）
struct SidePanelBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let panel: SidePanel
    let task: BoardTask
    var editable = false
    /// 画面が出している会話。あれば状態に環境・コンテキスト・コネクタ、差分にその作業フォルダの差分を出す
    var conversation: ConversationKey?
    /// false なら自前でスクロールしない（iPhone のタスク画面の縦並びに入れるとき）
    var scrolls = true
    /// 状態の欄をこの id の節まで送る知らせ（入ったら送って nil に戻す）
    var scrollTarget: Binding<String?> = .constant(nil)
    var openConversation: (ConversationKey) -> Void = { _ in }

    /// 状態の欄の PR の節の id（PR を開く知らせでここまで送る）
    static let prAnchor = "pr"

    /// 欄に中身があるか（iPhone の初めの欄・Mac の初めの組を決める）。状態はいつもある
    static func filled(task: BoardTask, conversation: ConversationKey?, model: AppModel) -> (SidePanel) -> Bool {
        let documents = !model.fleet.documents(for: task.id).isEmpty
        let workItems = !model.fleet.workItems(for: task.id).isEmpty
        let part = model.panelParts(task.id, in: .side) != nil
        return { panel in
            switch panel {
            case .docs: documents
            case .work: workItems
            case .status: true
            case .changes: conversation != nil
            case .part: part
            }
        }
    }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("SidePanelBody")
        #endif
        switch panel {
        case .docs:
            let documents = model.fleet.documents(for: task.id)
            if documents.isEmpty, model.fleet.machineState(for: task.machine)?.reviewRequests[task.id] == nil {
                placeholder(EmptyState("文書はありません", symbol: "doc.text"))
            } else {
                scrolling { DocumentList(task: task, documents: documents) }
            }
        case .work:
            let workItems = model.fleet.workItems(for: task.id)
            scrolling {
                VStack(alignment: .leading, spacing: Space.block) {
                    if let progress = TaskProgress.derive(workItems)?.fractionLabel {
                        Text(progress).textRole(.caption).monospacedDigit()
                    }
                    WorkItemList(task: task, items: workItems)
                }
            }
        case .status:
            scrolling(to: scrollTarget) {
                TaskStatusSections(task: task, editable: editable, conversation: conversation, openConversation: openConversation)
            }
        case .part:
            scrolling { PanelSideBody(task: task) }
        case .changes:
            if let conversation {
                ConversationDiffScreen(feed: model.conversationFeed(for: conversation), inPanel: true).id(conversation)
            } else {
                placeholder(EmptyState("差分はありません", symbol: "plusminus", message: "会話を選ぶと、その作業フォルダの差分を表示します。"))
            }
        }
    }

    /// `target` に節の id が入ったら、その節を上に送る（自前でスクロールしないときは送らない）
    @ViewBuilder
    private func scrolling<Body: View>(to target: Binding<String?> = .constant(nil), @ViewBuilder _ body: () -> Body) -> some View {
        if scrolls {
            let content = body()
            ScrollViewReader { proxy in
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, inset)
                }
                .contentMargins(.vertical, Space.block, for: .scrollContent)
                .onChange(of: target.wrappedValue, initial: true) { _, section in
                    guard let section else { return }
                    target.wrappedValue = nil
                    proxy.scrollTo(section, anchor: .top)
                }
            }
        } else {
            body().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, inset).padding(.vertical, Space.block)
        }
    }

    private func placeholder(_ state: some View) -> some View {
        state.frame(maxWidth: .infinity, maxHeight: scrolls ? .infinity : nil).padding(.vertical, Space.section)
    }
}

/// 右側の状態の欄。会話の環境（会話を出しているとき）、メモ、PR、終了したセッション、再開の予定、PR・issueの監視、定期起動。中身の無い節は出さない
private struct TaskStatusSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    let task: BoardTask
    let editable: Bool
    let conversation: ConversationKey?
    let openConversation: (ConversationKey) -> Void

    @TaskState private var editingNote = false
    @TaskState private var noteDraft = ""
    /// 保存を送ったメモ。daemon から新しいメモが届くまで、これを出す
    @TaskState private var pendingNote = PendingValue<String>()

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("TaskStatusSections")
        #endif
        let sessions = model.taskSessions(for: task)
        let shownConversation = conversation.flatMap { model.fleet.conversation(for: $0) }
        VStack(alignment: .leading, spacing: Space.section) {
            if let shownConversation {
                section(String(localized: "会話")) {
                    ConversationInspector(conversation: shownConversation, feed: model.conversationFeed(for: shownConversation.key), showsDelegates: false)
                }
            }
            if !task.note.isEmpty || editable {
                section(String(localized: "メモ")) { note }
            }
            if !task.pullRequestLinks.isEmpty {
                section(String(localized: "PR")) { TaskPRPane(task: task) }
                    .id(SidePanelBody.prAnchor)
            }
            let finished = model.finishedSessions(of: task, in: sessions)
            if !finished.isEmpty {
                section(String(localized: "終了したセッション")) {
                    FinishedSessionList(task: task, finished: finished, open: openConversation)
                }
            }
            let wakes = model.wakes(forTask: task.id)
            if !wakes.isEmpty {
                section(String(localized: "再開の予定")) { TaskWakeList(wakes: wakes) }
            }
            let watches = model.watches(forTask: task.id)
            if !watches.isEmpty {
                section(String(localized: "監視")) { TaskWatchList(watches: watches) }
            }
            if !model.schedules(forTask: task.id).isEmpty {
                section(String(localized: "定期起動")) { TaskScheduleList(task: task) }
            } else if AppModel.canEditSchedules {
                // 節の見出しは置かず、［定期起動を追加］だけを出す
                TaskScheduleList(task: task)
            }
        }
    }

    private func section<Body: View>(_ title: String, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Text(title).textRole(.sectionTitle).accessibilityAddTraits(.isHeader)
            body()
        }
    }

    /// メモ。直せるときは押すとその場で欄になり、↩ か欄の外を押すと保存（⇧↩・⌥↩ で改行）、Esc で元に戻す。空にして保存するとメモを消す。
    /// 空のときは「メモはありません」を押して書き始める
    @ViewBuilder
    private var note: some View {
        let shown = pendingNote.shown(task.note)
        if editingNote {
            InlineField(label: String(localized: "メモ"), text: $noteDraft, lines: 3...20, commit: commitNote) { editingNote = false }
        } else if editable {
            Group {
                if shown.isEmpty {
                    Text("メモはありません").textRole(.secondary)
                } else {
                    Text(shown).textRole(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .inlineEditTarget(menuTitle: "メモを編集", hint: "押すとメモを編集できます") {
                noteDraft = shown
                editingNote = true
            }
            .onChange(of: task.note) { _, _ in pendingNote.settle() }
        } else {
            Text(shown).textRole(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commitNote() {
        editingNote = false
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note != task.note else { return }
        pendingNote.send(note)
        Task {
            do {
                try await model.saveNote(note, of: task)
            } catch {
                pendingNote.failed(note)
                model.fail("タスクを保存できませんでした", error, in: window)
            }
        }
    }
}

/// 終了したセッションの一覧。新しい順に、閉じたセッションの記録は会話の題（無ければ最後の指示）・ブランチ・最後の発言の時刻で見分けて［再開］、
/// 終了した会話は題と最後の更新で見分けて［開く］（記録は残っていて、送れば戻る）
struct FinishedSessionList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let task: BoardTask
    let finished: [FinishedSession]
    let open: (ConversationKey) -> Void
    @TaskState private var showsAll = false

    /// 初めに出す数。残りは「さらにN件」
    static let limit = 3

    var body: some View {
        let canLaunch = model.canWrite(task.machine)
        VStack(alignment: .leading, spacing: Space.block) {
            ForEach(showsAll ? finished : Array(finished.prefix(Self.limit))) { item in
                switch item {
                case .record(let ref, let history):
                    FinishedRecordRow(ref: ref, history: history, taskTitle: task.title, canResume: canLaunch) {
                        model.resumeSession(ref, task: task.id)
                    }
                case .conversation(let conversation):
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: conversation.displayTitle).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            MetaLine(items: model.nextWakeText(for: conversation, now: today).map { [$0] } ?? [], date: conversation.updatedAt)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        Button("開く") { open(conversation.key) }
                            .controlSize(.small)
                    }
                }
            }
            if !showsAll, finished.count > Self.limit {
                Button("さらに\(finished.count - Self.limit)件") { showsAll = true }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .hitTarget()
            }
        }
    }
}

struct FinishedRecordRow: View {
    let ref: TaskSessionRef
    let history: SessionHistory?
    let taskTitle: String
    let canResume: Bool
    let resume: () -> Void

    var body: some View {
        let title = history?.title(taskTitle: taskTitle)
        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? ref.displayName).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                MetaLine(items: (title == nil ? [] : [ref.displayName]) + (history?.branch.map { [$0] } ?? []), date: history?.updatedAt ?? ref.linkedAt)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("再開", action: resume)
                .controlSize(.small)
                .disabled(!canResume)
        }
    }
}

extension TaskSessionRef {
    /// 紐づけの記録の名前（ラベル、無ければエージェントの名前）
    var displayName: String {
        if !label.isEmpty { return label }
        return agent == "codex" ? "Codex" : "Claude Code"
    }
}

/// タスクに結んだ定期起動。行を開くとプロンプト・設定・履歴（各回）・操作。［追加］はこのタスクに結んで作る。無ければ［追加］だけ
struct TaskScheduleList: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    @TaskState private var expanded: Set<ScheduleKey> = []

    var body: some View {
        let schedules = model.schedules(forTask: task.id)
        VStack(alignment: .leading, spacing: Space.block) {
            ScheduleRows(schedules: schedules, expanded: $expanded)
            if AppModel.canEditSchedules {
                Button("定期起動を追加", systemImage: "plus") {
                    var draft = ScheduleDraft(machine: task.machine)
                    draft.destination = .existing
                    draft.taskNumber = task.number
                    model.scheduleSheet = draft
                }
                .buttonStyle(.borderless)
                .hitTarget()
                .disabled(!model.canWrite(task.machine))
            }
        }
    }
}

/// 定期起動の行を並べる（タスクの右の欄・タスクなしの画面）
struct ScheduleRows: View {
    @Environment(AppModel.self) private var model
    let schedules: [Schedule]
    @Binding var expanded: Set<ScheduleKey>

    var body: some View {
        ForEach(schedules) { schedule in
            ScheduleRowView(schedule: schedule, expanded: expanded.contains(schedule.id), canEdit: AppModel.canEditSchedules) {
                if expanded.contains(schedule.id) { expanded.remove(schedule.id) } else { expanded.insert(schedule.id) }
            } edit: {
                model.scheduleSheet = ScheduleDraft(schedule)
            }
        }
    }
}
