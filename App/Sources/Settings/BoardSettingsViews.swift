import SwiftUI
import TaskboardKit

/// 書き込めるマシンが無いときの空状態
struct NoWritableMachine: View {
    var body: some View {
        EmptyState("編集できる接続先はありません", symbol: "network.slash", message: String(localized: "接続先に接続すると、ここで編集できます。"))
    }
}

// MARK: - 案件の一覧

/// 設定の「案件」。案件の一覧から 1 件開くと、その中で名前・マージしたら・列・起動を設定する
struct BoardSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let machines = model.settingsMachines
        if machines.isEmpty {
            NoWritableMachine()
        } else if let key = model.settingsBoardPath.first, let scope = machines.first(where: { $0.fleetID == key.fleetID }), let board = scope.state.boards[key.boardID] {
            BoardDetailSettings(board: board, scope: scope, kept: model.settingsBoardDrafts[key])
                .id(key)
        } else {
            BoardList(machines: machines)
        }
    }
}

private struct BoardList: View {
    @Environment(AppModel.self) private var model
    let machines: [SettingsBoardScope]
    @State private var creating: NewBoardDraft?

    var body: some View {
        Form {
            ForEach(Array(machines.enumerated()), id: \.element.fleetID) { index, scope in
                let boards = model.orderedBoards(scope.state, fleetID: scope.fleetID, includeArchived: true)
                Section {
                    ForEach(Array(boards.enumerated()), id: \.element.id) { position, board in
                        BoardListRow(board: board, taskCount: scope.state.tasks.values.count(where: { $0.boardID == board.id })) {
                            model.openBoardSettings(SettingsBoardKey(fleetID: scope.fleetID, boardID: board.id))
                        }
                        .contextMenu {
                            Button("上へ移動", systemImage: "arrow.up") { model.moveBoard(board, fleetID: scope.fleetID, by: -1) }
                                .disabled(position == 0)
                            Button("下へ移動", systemImage: "arrow.down") { model.moveBoard(board, fleetID: scope.fleetID, by: 1) }
                                .disabled(position == boards.count - 1)
                        }
                    }
                    .onMove { source, destination in
                        model.moveBoards(scope.state, fleetID: scope.fleetID, includeArchived: true, from: source, to: destination)
                    }
                    Button("案件を追加", systemImage: "plus") { creating = NewBoardDraft(machine: scope.machine) }
                } header: {
                    if machines.count > 1 { Text(model.machineName(fleetID: scope.fleetID, state: scope.state)) }
                } footer: {
                    if index == machines.count - 1 {
                        Text("アーカイブした案件は、ボード、サイドバー、検索に表示されません。")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentWidth()
        .sheet(item: $creating) { draft in
            NewBoardSheet(draft: draft) { board in
                guard let fleetID = model.settingsMachines.first(where: { $0.machine == board.machine })?.fleetID else { return }
                model.openBoardSettings(SettingsBoardKey(fleetID: fleetID, boardID: board.id))
            }
        }
    }
}

private struct BoardListRow: View {
    let board: Board
    let taskCount: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Space.row) {
                Text(board.name)
                    .textRole(.body)
                    .foregroundStyle(board.archived ? .secondary : .primary)
                if board.archived { Chip(text: String(localized: "アーカイブ済み")) }
                Spacer(minLength: Space.row)
                Text("\(taskCount)件").textRole(.secondary).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("案件の設定を開く")
    }
}

// MARK: - 案件の中身

/// 案件 1 件の設定。名前・マージしたら・列・起動を同じ保存の帯で保存し、アーカイブ・タスクの移動・削除はその場で行う
struct BoardDetailSettings: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let board: Board
    let scope: SettingsBoardScope
    @State private var draft: BoardSettingsDraft
    @State private var baseline: BoardSettingsDraft
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?
    @State private var moving = false
    @State private var confirmDelete = false
    @State private var slack: SlackSettingsStatus
    private let loadsSlack: Bool

    /// `kept` は設定の窓を閉じる前に保存していなかった下書き。あれば続きから始める。
    /// `slack` を渡すと daemon から読まずにそれを出す（snapshot test）
    init(board: Board, scope: SettingsBoardScope, kept: BoardSettingsEdit? = nil, slack: SlackSettingsStatus? = nil) {
        self.board = board
        self.scope = scope
        var loaded = BoardSettingsDraft(board)
        if let value = slack?.slack { loaded.slack = BoardSlackDraft(value) }
        _draft = State(initialValue: kept?.draft ?? loaded)
        _baseline = State(initialValue: kept?.baseline ?? loaded)
        _slack = State(initialValue: slack ?? SlackSettingsStatus())
        loadsSlack = slack == nil
    }

    private var key: SettingsBoardKey { SettingsBoardKey(fleetID: scope.fleetID, boardID: board.id) }
    private var dirty: Bool { draft.differs(from: baseline) }
    /// Form の行に渡す下書きの Binding。`$draft` から作った Binding を持つ view は、下書きのどこが変わっても、親での比べ（`Redraw`・Equatable の区分）を通らずに描き直される
    private var editing: Binding<BoardSettingsDraft> { Binding(get: { draft }, set: { draft = $0 }) }

    var body: some View {
        let tasks = scope.state.tasks.values.filter { $0.boardID == board.id }
        let counts = Dictionary(grouping: tasks, by: \.columnID).mapValues(\.count)
        let needsTarget = draft.removedColumns(of: board).filter { (counts[$0.id] ?? 0) > 0 }
        Form {
            Section {
                LabeledTextField(label: String(localized: "名前"), text: editing.name)
                // 「デプロイ中」を消した案件では、daemon はマージしたタスクを完了へ移動する
                if draft.columns.contains(where: { $0.id == MergeTarget.deploying.columnID }) {
                    LabeledSegmentedPicker(String(localized: "マージしたら"), selection: editing.mergeTarget) {
                        Text("デプロイ中へ").tag(MergeTarget.deploying)
                        Text("完了へ").tag(MergeTarget.done)
                    }
                } else {
                    LabeledContent("マージしたら", value: String(localized: "完了へ"))
                }
            } footer: {
                Text("紐づくPRがマージされたタスクを移動する列です。")
            }
            ColumnSection(draft: editing, counts: counts, compact: compact)
            if !needsTarget.isEmpty {
                Section("削除する列のタスクの移動先") {
                    ForEach(needsTarget) { column in
                        Picker("「\(column.label)」の\(counts[column.id] ?? 0)件", selection: Binding(
                            get: { draft.reassign[column.id] ?? "" }, set: { draft.reassign[column.id] = $0 })
                        ) {
                            Text("未選択").tag("")
                            // 足した列は保存するまで id が無いので、保存済みの列だけ
                            ForEach(draft.columns.compactMap { column in column.id.map { ($0, column.label) } }, id: \.0) { id, label in
                                Text(label).tag(id)
                            }
                        }
                    }
                }
            }
            LaunchDefaultsSection(hasDefaults: editing.hasLaunchDefaults, draft: editing.launch)
            Section {
                Redraw(on: draft.promptTemplate) {
                    LabeledTextEditor(label: String(localized: "案件"), text: editing.promptTemplate)
                }
            } header: {
                Text("起動プロンプト")
            } footer: {
                Text("空欄のときは何も送りません。\(PromptTemplate.placeholders.map { "\($0)（\(Self.placeholderLabel($0))）" }.joined(separator: "、"))は、起動時に置き換わります。")
            }
            columnPrompts
            BoardSlackSections(
                draft: Binding(get: { draft.slack }, set: { draft.slack = $0 }), status: slack, boardName: board.name,
                tasks: SlackTaskChoice.choices(
                    for: board, boards: model.orderedBoards(scope.state, fleetID: scope.fleetID, includeArchived: true), tasks: scope.state.tasks.values),
                reload: { Task { await loadSlack() } }, disconnect: disconnectSlack)
            Section {
                Button(board.archived ? "アーカイブから戻す" : "アーカイブ", systemImage: "archivebox") { archive(!board.archived) }
                Button("タスクを別の案件に移動…", systemImage: "arrow.right.doc.on.clipboard") { moving = true }
                    .disabled(tasks.isEmpty)
                Button("案件を削除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .disabled(!tasks.isEmpty)
            } footer: {
                if !tasks.isEmpty {
                    Text("タスクがある案件は削除できません。先にタスクを別の案件に移動してください。")
                }
            }
        }
        .formStyle(.grouped)
        .settingsContentWidth()
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SettingsSaveBar(message: message, error: error, saving: saving, dirty: dirty, revert: revert) {
                save(needsTarget: needsTarget)
            }
        }
        .onChange(of: dirty, initial: true) { _, new in
            model.settingsDirty = new
            if new { message = nil }
        }
        // 窓を閉じても続きから編集できるよう、変わるたびに model に残す
        .onChange(of: BoardSettingsEdit(draft: draft, baseline: baseline)) { _, edit in model.keepBoardDraft(edit, for: key) }
        .onChange(of: board) { _, new in
            // 保存していない間に daemon から届いた変更は下書きに入れる（編集中は上書きしない）
            if !dirty, !saving { load(new) }
        }
        .onDisappear { model.settingsDirty = false }
        .task {
            if loadsSlack { await loadSlack() }
        }
        .sheet(isPresented: $moving) {
            TaskMoveSheet(source: board, scope: scope)
        }
        .confirmationDialog("案件の削除", isPresented: $confirmDelete) {
            Button("削除", role: .destructive) { delete() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(board.name)」を削除しますか？　この操作は元に戻せません。")
        }
        #if os(iOS)
        // iPad は中身の見出し（［‹ 案件］と案件の名前）があるので、題は区分の名前にする（案件の名前が二重に並んだ）
        .navigationTitle(compact ? board.name : SettingsSection.boards.title)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if compact {
                ToolbarItem(placement: .topBarLeading) {
                    Button("案件", systemImage: "chevron.left") { model.leaveSettings(.boardList) }
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        #endif
    }

    private var columnPrompts: some View {
        Section {
            ForEach(editing.columns, id: \.key) { $column in
                let label = column.label.isEmpty ? String(localized: "新しい列") : column.label
                Redraw(on: ColumnPromptKey(label: label, template: column.template)) {
                    LabeledTextEditor(label: label, text: $column.template, lines: 1...8)
                }
            }
        } header: {
            Text("列ごとの起動プロンプト")
        } footer: {
            Text("空欄の列では、案件の起動プロンプトを使います。")
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// Mac と iPad の上の見出し（一覧へ戻る）。iPhone はナビゲーションバーに戻るを置く
    @ViewBuilder
    private var header: some View {
        if !compact {
            VStack(spacing: 0) {
                HStack(spacing: Space.row) {
                    Button("案件", systemImage: "chevron.left") { model.leaveSettings(.boardList) }
                        .buttonStyle(.borderless)
                        .hitTarget()
                    Text(board.name).textRole(.sectionTitle).lineLimit(1)
                    if board.archived { Chip(text: String(localized: "アーカイブ済み")) }
                    Spacer(minLength: 0)
                }
                .settingsBarContent()
                Divider()
            }
            .background(.bar)
        }
    }

    static func placeholderLabel(_ placeholder: String) -> String {
        switch placeholder {
        case "{{id}}": String(localized: "番号")
        case "{{title}}": String(localized: "タイトル")
        case "{{status}}": String(localized: "列")
        case "{{note}}": String(localized: "メモ")
        case "{{links}}": String(localized: "リンク")
        default: ""
        }
    }

    /// 案件の分だけ読み直す。Slack の下書きは別に読むので残す
    private func load(_ board: Board) {
        var loaded = BoardSettingsDraft(board)
        loaded.slack = draft.slack
        draft = loaded
        loaded.slack = baseline.slack
        baseline = loaded
        error = nil
    }

    private func loadSlack(_ value: BoardSlack) {
        slack.slack = value
        slack.loadError = nil
        draft.slack = BoardSlackDraft(value)
        baseline.slack = draft.slack
    }

    /// 窓を閉じる前の下書き（`kept`）があれば、下書きは上書きせず見せる値だけ読む
    private func loadSlack() async {
        slack.loadError = nil
        do {
            let value = try await model.boardSlack(board)
            if draft.slack == nil || !dirty {
                loadSlack(value)
            } else {
                slack.slack = value
            }
            if value.configured { await loadChannels() }
        } catch {
            slack.loadError = UserFacingError("Slackの設定を読み込めませんでした", error: error)?.text
        }
    }

    private func loadChannels() async {
        slack.channelsError = nil
        do {
            slack.channels = try await model.slackChannels(board)
        } catch {
            slack.channelsError = UserFacingError("チャンネルを読み込めませんでした", error: error)?.text
        }
    }

    private func disconnectSlack() {
        error = nil
        message = nil
        Task {
            do {
                try await model.deleteBoardSlack(board)
                loadSlack(BoardSlack())
                slack.channels = nil
                message = String(localized: "Slackの連携を解除しました。")
            } catch {
                self.error = UserFacingError("Slackの連携を解除できませんでした", error: error)?.text
            }
        }
    }

    private func revert() {
        draft = baseline
        error = nil
    }

    /// 案件と Slack は別の API なので、変わった方だけを順に送る。案件だけ通ったら、Slack の下書きは残して帯で知らせる
    private func save(needsTarget: [BoardColumn]) {
        guard !saving else { return }
        error = nil
        message = nil
        if draft.slack?.hasIssue == true {
            error = UserFacingError("案件の設定を保存できませんでした", cause: String(localized: "Slackのトークンの形式が正しくありません"), remedy: String(localized: "「xoxb-」で始まるボットトークンと、「xapp-」で始まるアプリレベルトークンを入力してください"))
                .text
            return
        }
        saving = true
        let boardRequest = draft.boardDiffers(from: baseline) ? draft.request(from: baseline, board: board, needsTarget: needsTarget) : nil
        let slackRequest = draft.slackRequest(from: baseline)
        Task {
            defer { saving = false }
            if let boardRequest {
                do {
                    load(try await model.updateBoard(board, boardRequest))
                } catch {
                    self.error = UserFacingError("案件の設定を保存できませんでした", error: error)?.text
                    return
                }
            }
            if let slackRequest {
                do {
                    let updated = try await model.updateBoardSlack(board, slackRequest)
                    loadSlack(updated)
                    if updated.configured { await loadChannels() }
                } catch {
                    self.error = UserFacingError("Slackの設定を保存できませんでした", error: error)?.text
                    return
                }
            }
            message = String(localized: "案件の設定を保存しました。")
        }
    }

    private func archive(_ archived: Bool) {
        error = nil
        Task {
            do {
                _ = try await model.updateBoard(board, BoardUpdateRequest(archived: archived))
            } catch {
                let event: LocalizedStringResource = archived ? "アーカイブできませんでした" : "アーカイブから戻せませんでした"
                self.error = UserFacingError(event, error: error)?.text
            }
        }
    }

    private func delete() {
        error = nil
        Task {
            do {
                try await model.deleteBoard(board)
                model.settingsBoardDrafts[key] = nil
                model.performSettingsLeave(.boardList)
            } catch {
                self.error = UserFacingError("案件を削除できませんでした", error: error)?.text
            }
        }
    }
}

// MARK: - 起動の初期値

/// 列ごとの起動プロンプトの 1 行が見せる値
private struct ColumnPromptKey: Equatable {
    let label: String
    let template: String
}

/// 見せる値が同じなら描き直さない（`ColumnSection` と同じ）
private struct LaunchDefaultsSection: View, Equatable {
    @Binding var hasDefaults: Bool
    @Binding var draft: LaunchDraft
    /// オンのときだけ中身を見せる
    private let shown: LaunchDraft?

    init(hasDefaults: Binding<Bool>, draft: Binding<LaunchDraft>) {
        _hasDefaults = hasDefaults
        _draft = draft
        shown = hasDefaults.wrappedValue ? draft.wrappedValue : nil
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.shown == b.shown }

    var body: some View {
        Section {
            Toggle("起動の初期値を指定する", isOn: $hasDefaults)
            if hasDefaults {
                LaunchChoiceFields(choice: $draft.choice, machine: draft.machine)
                LabeledTextField(label: String(localized: "作業フォルダ"), text: $draft.cwd, monospaced: true)
            }
        } header: {
            Text("起動時の初期値")
        } footer: {
            if hasDefaults {
                Text("作業フォルダが空欄のときは、この案件で最後に使ったフォルダで起動します。")
            } else {
                Text("オフのときは、この案件で最後に起動したときの選択と作業フォルダを使います。")
            }
        }
    }
}
