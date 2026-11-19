import SwiftUI
import TaskboardKit

/// 1 マシンのオーケストレーターの画面（サイドバーのマシンの行のオーケストレーターの印、`taskboard://orchestrator/<machine>`）。委譲先が居れば札で並べ、押すとその場で替わる。
/// 上の帯にマシンの名前と状態・常駐のオン／オフ・操作（起動・停止・破棄して再起動…）、下に動いていれば会話（`ConversationView`）、
/// 止まっていれば空状態と最後の返事。題は上のバー（`navigationTitle`）に出し、帯には繰り返さない
struct OrchestratorScreen: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    /// 札で選んだ委譲先。nil ならオーケストレーター
    @State private var delegate: ConversationKey?

    var body: some View {
        let conversation = model.orchestratorConversation(on: machine)
        let info = model.fleet.machineState(for: machine)?.orchestrator
        let row = model.orchestratorRow(on: machine)
        let members = model.sessionSet(for: .orchestrator(machine)).rows
        let own = conversation?.key
        let shownDelegate = delegate.flatMap { key in members.first { $0.conversation.key == key && key != own }?.conversation }
        VStack(spacing: 0) {
            OrchestratorHeader(machine: machine, status: row?.statusLabel)
            Divider()
            // 委譲先が居るときだけ札を並べる。押すとその場で委譲先に替わる（オーケストレーターの札で戻る）
            if members.contains(where: { $0.depth > 0 }) {
                LinkedSessionPills(rows: members, current: shownDelegate?.key ?? own) { item in
                    model.logConversationSelect(item, via: "pill")
                    delegate = item == own ? nil : item
                }
                Divider()
            }
            if let shownDelegate {
                ConversationStage(conversation: shownDelegate)
            } else if let conversation {
                ConversationStage(conversation: conversation)
            } else {
                OrchestratorStopped(machine: machine, info: info, launchFailure: row?.launchFailure)
            }
        }
        .onChange(of: model.sessionFocus, initial: true) { _, focus in
            guard let focus, focus.scope == .orchestrator(machine) else { return }
            delegate = focus.item
            model.sessionFocus = nil
        }
        .frame(minHeight: 0)
        .navigationTitle("オーケストレーター")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // 動いている間は入力欄がオーケストレーターへの送信だけになるよう、セッションの画面と同じくタブバーを隠す
        .toolbar(conversation == nil ? .automatic : .hidden, for: .tabBar)
        #endif
    }
}

/// 上の帯。左にマシンの名前と状態、右に常駐のオン／オフと操作。1 行に入らない幅（iPhone）では操作を下の行に送る
private struct OrchestratorHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let machine: MachineID
    /// `OrchestratorRow.statusLabel`。マシンが見つからなければ nil
    let status: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.block) {
                summary
                Spacer(minLength: Space.row)
                controls
            }
            VStack(alignment: .leading, spacing: Space.row) {
                summary
                HStack(spacing: Space.block) { controls }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.row)
    }

    private var summary: some View {
        MetaLine(items: [model.machineName(machine)] + (status.map { [$0] } ?? []))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var controls: some View {
        OrchestratorResidentToggle(machine: machine)
        // 接続していないマシンには行が無い（操作も送れない）
        if let row = model.orchestratorRows.first(where: { $0.machine == machine }) {
            OrchestratorActions(row: row, style: .buttons)
        }
    }
}

/// 常駐のオン／オフ。設定の［セッション］の「オーケストレーターを常駐させる」と同じ値を、押した値を先に出して送る（失敗したら戻す）。
/// 古い daemon で設定が読めなければ出さない
private struct OrchestratorResidentToggle: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID
    @State private var pending = PendingValue<Bool>()

    var body: some View {
        if let settings = model.fleet.machineState(for: machine)?.settings {
            Toggle("常駐", isOn: .pending($pending, current: settings.orchestrator.enabled) { value in
                await model.saveSettings(on: machine, MachineSettingsUpdate(orchestratorEnabled: value))
            })
                .fixedSize()
                #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.small)
                #endif
                .help("オンにすると、停止しても自動で起動します。オフにすると停止します。")
                .onChange(of: settings.orchestrator.enabled) { _, _ in pending.settle() }
        }
    }
}

/// 起動・停止・破棄して再起動…。帯のボタンと、サイドバーのマシンの行の右クリック（長押し）のメニューで同じものを出す
struct OrchestratorActions: View {
    enum Style { case buttons, menu }

    @Environment(AppModel.self) private var model
    let row: OrchestratorRow
    let style: Style

    var body: some View {
        if row.canStart {
            Button("起動", systemImage: "play.fill") { model.startOrchestrator(on: row.machine) }
                .modifier(ActionStyle(style: style, prominent: true))
        }
        if row.canStop {
            Button("停止", systemImage: "stop.circle") {
                if let conversation = row.conversation { model.stop(conversation: conversation.key) }
            }
            .modifier(ActionStyle(style: style, prominent: false))
        }
        Button("破棄して再起動…", systemImage: "arrow.counterclockwise") { model.ask(.restartOrchestrator(row.machine)) }
            .modifier(ActionStyle(style: style, prominent: false))
    }

    private struct ActionStyle: ViewModifier {
        let style: Style
        let prominent: Bool

        @ViewBuilder
        func body(content: Content) -> some View {
            switch style {
            case .menu:
                content
            case .buttons:
                if prominent {
                    content.labelStyle(.titleOnly).buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    content.labelStyle(.titleOnly).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

/// 止まっているときの中身。常駐の見張りが起こせなかったときは帯、空状態と［起動］、最後の返事（チャットが無いので、ここで読めるようにする）
private struct OrchestratorStopped: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let machine: MachineID
    let info: OrchestratorInfo?
    let launchFailure: String?

    var body: some View {
        VStack(spacing: Space.section) {
            if let launchFailure {
                Banner(kind: .error, message: launchFailure)
            }
            EmptyState(title: String(localized: "オーケストレーターは停止しています"), symbol: "stop.circle") {
                Button("起動") { model.startOrchestrator(on: machine) }
                    .buttonStyle(.borderedProminent)
            }
            if let reply = info?.lastReply {
                VStack(alignment: .leading, spacing: Space.block) {
                    HStack {
                        Text("最後の応答").textRole(.sectionTitle)
                        Spacer()
                        RelativeTime(date: reply.at)
                    }
                    Card {
                        Text(reply.text)
                            .textRole(.body)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: ReadableWidth.text)
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 「破棄して再起動…」の確認。帯とサイドバーのメニューの両方から出すので、窓の根（`WindowRoot`）に置く
struct OrchestratorRestartDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window

    func body(content: Content) -> some View {
        let machine = model.confirmation(in: window).flatMap { if case .restartOrchestrator(let machine) = $0 { machine } else { nil } }
        content.confirmationDialog(
            "オーケストレーターの再起動", isPresented: Binding(get: { machine != nil }, set: { if !$0 { model.dismissConfirmation(in: window) } }),
            titleVisibility: .visible, presenting: machine
        ) { _ in
            Button("再起動", role: .destructive) { model.confirm(in: window) }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("今の会話を破棄して、新しく起動しますか？　この操作は元に戻せません。")
        }
    }
}
