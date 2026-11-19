import SwiftUI
import TaskboardKit

struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: NewTaskDraft
    @State private var submitting = false
    @State private var error: String?
    /// 起票はできて起動だけできなかったタスク。やり直すときは起動だけ送る（2 件目を作らない）
    @State private var created: BoardTask?
    @FocusState private var titleFocused: Bool
    /// 行に渡す下書きの Binding。`$draft` から作った Binding を持つ view は、下書きのどこが変わっても、`Redraw`・Equatable の行（`DueDateField`・`LaunchFields` の起動先の区分）の比べを通らずに描き直される
    private var editing: Binding<NewTaskDraft> { Binding(get: { draft }, set: { draft = $0 }) }

    var body: some View {
        SheetScaffold(
            title: String(localized: "タスクの追加"), subtitle: draft.attach.map { model.name(of: .conversation($0)) }, error: error, width: 560,
            onCancel: { dismiss() }
        ) {
            Section {
                StackedField(String(localized: "タイトル")) {
                    TextField("タイトル", text: editing.title, prompt: Text(verbatim: ""))
                        .focused($titleFocused)
                }
                Picker("案件", selection: Binding(get: { draft.board.id }, set: selectBoard)) {
                    ForEach(boards) { board in
                        Text(verbatim: "\(model.machineName(board.machine)) › \(board.name)").tag(board.id)
                    }
                }
                .disabled(created != nil)
                Picker("列", selection: editing.columnID) {
                    ForEach(draft.board.orderedColumns) { column in Text(verbatim: column.label).tag(column.id) }
                }
                .disabled(created != nil)
                .onChange(of: draft.columnID) { _, column in draft.launch.applyTemplate(for: column, in: draft.board) }
            }
            #if os(iOS)
            // iPhone の上のバーに 3 つ並べると題が消えるので、起動しない追加は題の節のすぐ下に置く（末尾ではキーボードに隠れた）
            if draft.attach == nil {
                Section {
                    Button("起動せずに追加") { submit(launch: false) }
                        .disabled(submitting || created != nil)
                }
            }
            #endif
            // 起票のたびに使う欄なので畳まない（畳むと開く手間が増え、入れた値も見えなかった）
            Section {
                DueDateField(due: editing.due)
                Redraw(on: draft.links) { LinkRowsField(links: editing.links) }
                Redraw(on: draft.note) {
                    StackedField(String(localized: "メモ")) {
                        MultilineTextField(label: String(localized: "メモ"), text: editing.note, lines: 3...8, style: .stacked)
                    }
                }
            }
            .disabled(created != nil)
            if draft.attach == nil {
                LaunchFields(draft: editing.launch, header: String(localized: "起動"), startsNow: true)
            }
        } actions: {
            if submitting { ProgressView().controlSize(.small) }
            if draft.attach != nil {
                // 追加できて紐づけだけできなかったら、紐づけだけやり直す
                Button(created == nil ? "追加" : "紐づける") { submit(launch: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || !canLaunch)
            } else {
                #if os(macOS)
                Button("追加") { submit(launch: false) }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(submitting || created != nil)
                #endif
                // ↩ を既定のボタンにしない。1 行の欄で ↩ を押すと、起票してセッションまで起動していた（⌘↩ で押す）
                Button(created == nil ? "追加して起動" : "起動") { submit(launch: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(submitting || !canLaunch)
            }
        }
        .commandReturn(enabled: !submitting && canLaunch) { submit(launch: draft.attach == nil) }
        .onAppear {
            titleFocused = true
            draft.links = NewTaskDraft.normalizedLinks(draft.links)
        }
    }

    /// 案件の選択肢。紐づける会話かセッションがあれば、そのマシンの案件だけ（紐づけられるのは同じマシンのタスク）
    private var boards: [Board] {
        draft.attach.map { model.orderedBoards(on: $0.machine) } ?? model.orderedBoardsAcrossMachines
    }

    private func selectBoard(_ id: String) {
        guard let board = model.orderedBoardsAcrossMachines.first(where: { $0.id == id }) else { return }
        draft.board = board
        if !board.columns.contains(where: { $0.id == draft.columnID }) {
            draft.columnID = board.defaultColumn?.id ?? board.orderedColumns.first?.id ?? ""
        }
        if board.machine != draft.launch.machine {
            // 別のマシンの案件なら、そのマシンの起動の初期値に入れ直す（作業ディレクトリはマシンごとのパス）
            draft.launch = LaunchDraft.initial(machine: board.machine, board: board, boardID: board.id, columnID: draft.columnID)
        } else {
            draft.launch.applyTemplate(for: draft.columnID, in: board)
        }
    }

    /// fixtures など書き込めない接続先では起動できない
    private var canLaunch: Bool { model.canWrite(draft.board.machine) }

    private func submit(launch: Bool) {
        submitting = true
        error = nil
        let request = draft.request
        let launchDraft = draft.launch
        let machine = draft.board.machine
        let boardID = draft.board.id
        let attach = draft.attach
        Task {
            let task: BoardTask
            if let created {
                task = created
            } else {
                do {
                    task = try await model.create(task: request, on: machine)
                } catch {
                    self.error = UserFacingError("タスクを追加できませんでした", error: error)?.text
                    submitting = false
                    return
                }
            }
            var focus: ConversationKey?
            if let attach {
                do {
                    try await model.attach(.conversation(attach), to: task)
                    focus = attach
                } catch {
                    created = task
                    let reason = UserFacingError("タスクに紐づけられませんでした", error: error)?.text ?? ""
                    self.error = String(localized: "タスク#\(task.number)を追加しました。") + reason
                    submitting = false
                    return
                }
            }
            if launch {
                do {
                    focus = try await model.launchSession(task: task, launchDraft).key
                    launchDraft.remember(board: boardID)
                } catch {
                    created = task
                    let reason = UserFacingError("起動できませんでした", error: error)?.text ?? ""
                    self.error = String(localized: "タスク#\(task.number)を追加しました。") + reason
                    submitting = false
                    return
                }
            }
            dismiss()
            // 起こした会話も開く先に入れる（iPhone は開くタスクが替わると積んだ画面が外れるので、タスクと一緒に渡す）
            model.navigate(to: .task(task.id, focus: focus), from: .app)
        }
    }
}

/// リンクの欄。1 件 1 行で、↩ で次の行へ、複数行を貼ったら行ごとに分ける（`NewTaskDraft.normalizedLinks`）。起票のシートとリンクの追加のシートで使う
struct LinkRowsField: View {
    @Binding var links: [String]
    @FocusState private var focus: Int?

    var body: some View {
        StackedField(String(localized: "リンク")) {
            VStack(alignment: .leading, spacing: Space.row) {
                ForEach(Array(links.indices), id: \.self) { index in
                    HStack(spacing: Space.inline) {
                        TextField("リンク", text: linkBinding(index), prompt: Text(verbatim: "https://"))
                            .focused($focus, equals: index)
                            .onSubmit { focus = min(index + 1, links.count - 1) }
                            .accessibilityLabel(String(localized: "リンク\(index + 1)"))
                            #if os(iOS)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        if !links[index].isEmpty {
                            Button {
                                links.remove(at: index)
                                links = NewTaskDraft.normalizedLinks(links)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .hitTarget()
                            .accessibilityLabel(String(localized: "リンク\(index + 1)を削除"))
                        }
                    }
                }
            }
        }
    }

    private func linkBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < links.count ? links[index] : "" },
            set: { value in
                guard index < links.count else { return }
                links[index] = value
                links = NewTaskDraft.normalizedLinks(links)
            })
    }
}
