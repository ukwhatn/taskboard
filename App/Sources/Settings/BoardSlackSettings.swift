import SwiftUI
import TaskboardKit

/// Slack の区分が下書きのほかに見せる値。daemon から読んだもの
struct SlackSettingsStatus: Hashable {
    /// 読み込み中は nil
    var slack: BoardSlack?
    var loadError: String?
    /// 届け先に選べるチャンネル。読み込み中は nil
    var channels: [SlackChannel]?
    var channelsError: String?
}

/// 届け先に選べるタスク。終わりの列とアーカイブした案件のタスクは選べない（表にあれば題は出す）
struct SlackTaskChoice: Hashable, Identifiable {
    let number: Int
    let title: String
    let boardName: String
    var selectable = true

    var id: Int { number }
    var label: String { "#\(number) \(title)" }

    /// 設定している案件を先に、ほかの案件を `boards` の順に続ける（同じワークスペースのほかの案件のチャンネルも、1 つのアプリで受けるため）
    static func choices(for board: Board, boards: [Board], tasks: some Collection<BoardTask>) -> [SlackTaskChoice] {
        let byBoard = Dictionary(grouping: tasks, by: \.boardID)
        return ([board] + boards.filter { $0.id != board.id }).flatMap { each in
            let terminal = Set(each.columns.filter { $0.kind == .terminal }.map(\.id))
            return (byBoard[each.id] ?? []).sorted { $0.number > $1.number }.map {
                SlackTaskChoice(number: $0.number, title: $0.title, boardName: each.name, selectable: !each.archived && !terminal.contains($0.columnID))
            }
        }
    }
}

/// 案件の設定の「Slack」「受け付ける人」「チャンネルの届け先」。見せる値が同じなら描き直さない（`ColumnSection` と同じ）
struct BoardSlackSections: View, Equatable {
    @Binding var draft: BoardSlackDraft?
    let status: SlackSettingsStatus
    let boardName: String
    let tasks: [SlackTaskChoice]
    let reload: () -> Void
    let disconnect: () -> Void
    private let shown: Key

    @State private var newMember = ""
    @State private var newChannel = ""
    @State private var newTask = 0
    @State private var confirmDisconnect = false

    init(
        draft: Binding<BoardSlackDraft?>, status: SlackSettingsStatus, boardName: String, tasks: [SlackTaskChoice], reload: @escaping () -> Void,
        disconnect: @escaping () -> Void
    ) {
        _draft = draft
        self.status = status
        self.boardName = boardName
        self.tasks = tasks
        self.reload = reload
        self.disconnect = disconnect
        shown = Key(draft: draft.wrappedValue, status: status, boardName: boardName, tasks: tasks)
    }

    private struct Key: Equatable {
        let draft: BoardSlackDraft?
        let status: SlackSettingsStatus
        let boardName: String
        let tasks: [SlackTaskChoice]
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.shown == b.shown }

    var body: some View {
        if let error = status.loadError {
            Section("Slack") {
                Text(error).textRole(.secondary)
                Button("再読み込み", systemImage: "arrow.clockwise", action: reload)
            }
        } else if let slack = status.slack, let current = draft {
            if current.configured {
                connectionSection(slack, current)
                membersSection(current)
                routesSection(current)
            } else {
                Section {
                    tokenFields(current)
                } header: {
                    Text("Slack")
                } footer: {
                    tokenFooter
                }
            }
        } else {
            Section("Slack") {
                Text("読み込み中…").textRole(.secondary)
            }
        }
    }

    // MARK: 接続

    private func connectionSection(_ slack: BoardSlack, _ current: BoardSlackDraft) -> some View {
        Section {
            LabeledContent("ワークスペース", value: slack.workspace ?? "")
            LabeledContent("ボット", value: slack.botName ?? "")
            LabeledContent("接続") { connectionLabel(slack.connection) }
            if case .failed(let message) = slack.connection {
                // 役割の色（secondary）を重ねると、暗い外観で赤が沈んで読めない（`ConnectionRow`）
                Text(verbatim: message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if current.replacingTokens {
                tokenFields(current)
            } else {
                Button("トークンを入れ替える", systemImage: "key") { draft?.replacingTokens = true }
            }
            Button("連携を解除", systemImage: "xmark.circle", role: .destructive) { confirmDisconnect = true }
        } header: {
            Text("Slack")
        } footer: {
            if current.replacingTokens { tokenFooter }
        }
        .confirmationDialog("Slackの連携の解除", isPresented: $confirmDisconnect) {
            Button("解除", role: .destructive, action: disconnect)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(boardName)」のSlackの連携を解除しますか？　トークンと、受け付ける人、チャンネルの届け先の設定も消えます。この操作は元に戻せません。")
        }
    }

    @ViewBuilder
    private func connectionLabel(_ connection: SlackConnection) -> some View {
        switch connection {
        case .connected: Label("接続済み", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: Label("接続しています…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .failed: Label("接続できませんでした", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .off: Label("未接続", systemImage: "circle").foregroundStyle(.secondary)
        }
    }

    // MARK: トークン

    @ViewBuilder
    private func tokenFields(_ current: BoardSlackDraft) -> some View {
        LabeledContentField(String(localized: "ボットトークン（必須）")) {
            SecureField("ボットトークン（必須）", text: binding(\.botToken), prompt: Text(verbatim: "xoxb-"))
        }
        if let issue = current.botTokenIssue { fieldIssue(issue) }
        LabeledContentField(String(localized: "アプリレベルトークン（必須）")) {
            SecureField("アプリレベルトークン（必須）", text: binding(\.appToken), prompt: Text(verbatim: "xapp-"))
        }
        if let issue = current.appTokenIssue { fieldIssue(issue) }
    }

    private var tokenFooter: some View {
        Text("Slackアプリの、「xoxb-」で始まるボットトークンと、「xapp-」で始まるアプリレベルトークンを入力してください。")
    }

    private func fieldIssue(_ text: String) -> some View {
        Text(verbatim: text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 受け付ける人

    private func membersSection(_ current: BoardSlackDraft) -> some View {
        Section {
            if current.members.isEmpty {
                Text("受け付ける人はいません。追加するまで、Slackの依頼はどこにも届きません。").textRole(.secondary)
            }
            ForEach(current.members) { member in
                HStack(spacing: Space.row) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: member.name ?? member.id).textRole(.body)
                        if member.name != nil { Text(verbatim: member.id).textRole(.mono) }
                    }
                    Spacer(minLength: Space.row)
                    Button("「\(member.name ?? member.id)」を削除", systemImage: "minus.circle", role: .destructive) {
                        draft?.members.removeAll { $0.id == member.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                }
            }
            LabeledTextField(label: String(localized: "メンバーID"), text: $newMember, prompt: "U0123ABCD", monospaced: true)
                .onSubmit(addMember)
            if let issue = current.memberIssue(newMember) { fieldIssue(issue) }
            Button("受け付ける人を追加", systemImage: "plus", action: addMember)
                .disabled(newMember.trimmingCharacters(in: .whitespaces).isEmpty || current.memberIssue(newMember) != nil)
        } header: {
            Text("受け付ける人")
        } footer: {
            Text("ここにいる人がメンションした依頼だけを受け付けます。メンバーIDは、Slackのプロフィールの［メンバーIDをコピー］で取得できます。")
        }
    }

    private func addMember() {
        guard var current = draft, current.addMember(newMember) else { return }
        draft = current
        newMember = ""
    }

    // MARK: チャンネルの届け先

    private func routesSection(_ current: BoardSlackDraft) -> some View {
        let channels = (status.channels ?? []).filter { channel in !current.routes.contains { $0.channelID == channel.id } }
        return Section {
            ForEach(current.routes) { route in
                HStack(spacing: Space.row) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "#\(route.channelName ?? route.channelID)").textRole(.body)
                        Text(verbatim: taskLabel(route.taskNumber)).textRole(.secondary)
                    }
                    Spacer(minLength: Space.row)
                    Button("「#\(route.channelName ?? route.channelID)」の届け先を削除", systemImage: "minus.circle", role: .destructive) {
                        draft?.routes.removeAll { $0.channelID == route.channelID }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                }
            }
            if let error = status.channelsError {
                Text(error).textRole(.secondary)
                Button("再読み込み", systemImage: "arrow.clockwise", action: reload)
            } else if status.channels == nil {
                Text("読み込み中…").textRole(.secondary)
            } else if channels.isEmpty {
                Text("追加できるチャンネルはありません。ボットをチャンネルに追加すると、ここで選べます。").textRole(.secondary)
            } else {
                Picker("チャンネル", selection: $newChannel) {
                    Text("未選択").tag("")
                    ForEach(channels) { Text(verbatim: "#\($0.name)").tag($0.id) }
                }
                Picker("タスク", selection: $newTask) {
                    Text("未選択").tag(0)
                    ForEach(taskGroups, id: \.name) { group in
                        Section {
                            ForEach(group.tasks) { Text(verbatim: $0.label).tag($0.number) }
                        } header: {
                            Text(verbatim: group.name)
                        }
                    }
                }
                Button("届け先を追加", systemImage: "plus") {
                    guard let channel = channels.first(where: { $0.id == newChannel }), newTask != 0 else { return }
                    draft?.setRoute(channel, taskNumber: newTask)
                    newChannel = ""
                    newTask = 0
                }
                .disabled(newChannel.isEmpty || newTask == 0)
            }
        } header: {
            Text("チャンネルの届け先")
        } footer: {
            Text("ここにないチャンネルの依頼は、オーケストレーターに届きます。")
        }
    }

    /// 選べるタスクを案件ごとに区切る（`tasks` は案件ごとに続いて並ぶ）
    private var taskGroups: [(name: String, tasks: [SlackTaskChoice])] {
        tasks.filter(\.selectable).reduce(into: []) { groups, task in
            if groups.last?.name == task.boardName { groups[groups.count - 1].tasks.append(task) } else { groups.append((task.boardName, [task])) }
        }
    }

    private func taskLabel(_ number: Int) -> String {
        guard let task = tasks.first(where: { $0.number == number }) else { return "#\(number)" }
        return task.boardName == boardName ? task.label : "\(task.label)（\(task.boardName)）"
    }

    private func binding(_ path: WritableKeyPath<BoardSlackDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0 })
    }
}
