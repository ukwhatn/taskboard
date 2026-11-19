import SwiftUI
import TaskboardKit

/// 会話の画面の上の帯。左にブランチ、右に［ターミナル］（会話のシェルの欄の開け閉め）・［フォルダ］・［差分］と、ほかの操作のメニュー。
/// iPhone はナビゲーションバーの ⋯ 1 つに、帯の操作とほかの操作をまとめる（`inNavigationBar`。ブランチは［状態］に出る）
struct ConversationTopBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pageInset) private var inset
    let conversation: Conversation
    let generating: Bool
    let perform: (ConversationTaskboardAction) -> Void
    /// 端末の欄を開いているか（［ターミナル］を押すと閉じる）
    var terminalOpen = false
    var toggleTerminal: () -> Void = {}
    let undoRewind: () -> Void
    let redoRewind: () -> Void
    /// ［状態］の出し先。会話の環境・コンテキスト・コネクタを、ポップオーバーか右の欄（タスクのパネル）に出す
    var info: Info
    var inNavigationBar = false

    enum Info {
        case popover(ConversationFeed)
        case sidePane(() -> Void)
    }
    @State private var copied = false
    /// 帯の幅・メニューの幅・ラベル付きの操作の幅（`labelsProbe`）。入らなければアイコンだけにする
    @State private var widths = Widths()

    struct Widths: Equatable {
        var bar: CGFloat = 0
        var menu: CGFloat = 0
        var labels: CGFloat = 0

        /// ラベル付きの操作が、メニューと余白を残して入る（ブランチの名前は詰める）。測る前（0）はラベル付き
        func fitsLabels(inset: CGFloat) -> Bool {
            guard bar > 0 else { return true }
            return labels + menu + inset * 2 + Space.row * 3 <= bar
        }
    }

    var body: some View {
        if inNavigationBar {
            phoneMenu
        } else {
            barWithProbe
        }
    }

    private var barWithProbe: some View {
        let diff = conversation.diff
        return FillWidth {
            bar(diff: diff)
        }
        .background(alignment: .leading) {
            labelsProbe
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.labels = $0 }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.bar = $0 }
    }

    private func bar(diff: ConversationDiffSummary?) -> some View {
        HStack(spacing: Space.row) {
            if let branch = diff?.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .textRole(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(conversation.cwd)
            }
            Spacer(minLength: Space.row)
            // ViewThatFits は測るたびに 2 つの形を作り直し、入力欄に 1 字打つたびの窓のレイアウトで 20 ms ほどかかった。幅を測って 1 つだけ置く
            Group {
                if widths.fitsLabels(inset: inset) {
                    actions.labelStyle(.titleAndIcon)
                } else {
                    actions.labelStyle(.iconOnly)
                }
            }
            .layoutPriority(1)
            menu
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.menu = $0 }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, inset)
        .padding(.vertical, Space.inline)
    }

    /// ラベル付きの操作の幅を測る見えない写し。ボタンを写すと［状態］のポップオーバーが 2 つ結ばれるので、ラベルだけを並べる（題と記号は `actions` のボタンと同じにする）
    private var labelsProbe: some View {
        let diff = conversation.diff
        return HStack(spacing: Space.row) {
            Label("ターミナル", systemImage: "terminal")
            Label(copied ? "パスをコピーしました" : "フォルダ", systemImage: copied ? "checkmark" : "folder")
            HStack(spacing: Space.inline) {
                Label("差分", systemImage: "plusminus")
                if let diff, diff.isRepo, diff.files > 0 { DiffCounts(insertions: diff.insertions, deletions: diff.deletions) }
            }
            Label("状態", systemImage: "info.circle")
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
    }

    /// 幅が足りないときはアイコンだけにする（ラベルを折り返さない）
    private var actions: some View {
        let diff = conversation.diff
        return HStack(spacing: Space.row) {
            Button("ターミナル", systemImage: "terminal", action: toggleTerminal)
                .symbolVariant(terminalOpen ? .fill : .none)
                .accessibilityAddTraits(terminalOpen ? .isSelected : [])
                .help(terminalOpen ? "ターミナルを閉じる" : "作業フォルダのシェルを開く")
            Button(copied ? "パスをコピーしました" : "フォルダ", systemImage: copied ? "checkmark" : "folder") { revealFolder() }
                .help(opensFinder ? "Finderで開く" : "作業フォルダのパスをコピー")
            Button {
                perform(.diff)
            } label: {
                HStack(spacing: Space.inline) {
                    Label("差分", systemImage: "plusminus")
                    if let diff, diff.isRepo, diff.files > 0 {
                        DiffCounts(insertions: diff.insertions, deletions: diff.deletions)
                    }
                }
                .fixedSize()
            }
            .disabled(diff?.isRepo == false)
            .help(diff?.isRepo == false ? "作業フォルダはGitのリポジトリではありません" : diff.map { "\($0.files)件のファイルの差分" } ?? "差分")
            switch info {
            case .popover(let feed):
                Button("状態", systemImage: "info.circle") { feed.showsInfo = true }
                    .popover(isPresented: Binding(get: { feed.showsInfo }, set: { feed.showsInfo = $0 })) {
                        let inspector = ConversationInspector(conversation: conversation, feed: feed)
                            .padding(Space.card)
                            #if os(iOS)
                            // シートでは画面の幅に合わせる（Slide Over は 320pt で、最小を 360pt にすると端が切れる）
                            .frame(minWidth: ConversationMetrics.fieldWidth.lowerBound, idealWidth: ConversationMetrics.fieldWidth.upperBound,
                                   maxWidth: .infinity, alignment: .leading)
                            #else
                            .frame(minWidth: ConversationMetrics.fieldWidth.upperBound, alignment: .leading)
                            #endif
                        // 狭い幅（iPad の Slide Over・分割）ではシートにする。ポップオーバーのままだと画面の左にはみ出した
                        ViewThatFits(in: .vertical) {
                            inspector
                            ScrollView { inspector }
                        }
                        .presentationCompactAdaptation(.sheet)
                        .presentationDetents([.medium, .large])
                    }
                    .help("会話の状態")
            case .sidePane(let show):
                Button("状態", systemImage: "info.circle", action: show)
                    .help("会話の状態")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// iPhone の ⋯。帯の操作を先頭の節に置く（状態は会話の画面のシートで開く）
    private var phoneMenu: some View {
        let diff = conversation.diff
        return Menu {
            if let task = model.taskKey(of: conversation) {
                Button {
                    model.openTaskFromPhoneConversation(conversation)
                } label: {
                    Label {
                        Text("タスクを開く")
                        Text(verbatim: "#\(task.number)")
                    } icon: {
                        Image(systemName: "rectangle.stack")
                    }
                }
            }
            Section {
                Button("ターミナル", systemImage: "terminal", action: toggleTerminal)
                Button(copied ? "パスをコピーしました" : "作業フォルダのパスをコピー", systemImage: copied ? "checkmark" : "folder") { revealFolder() }
                Button {
                    perform(.diff)
                } label: {
                    Label {
                        Text("差分")
                        if let diff, diff.isRepo, diff.files > 0 { Text(verbatim: "+\(diff.insertions) −\(diff.deletions)") }
                    } icon: {
                        Image(systemName: "plusminus")
                    }
                }
                .disabled(diff?.isRepo == false)
                Button("状態", systemImage: "info.circle") {
                    switch info {
                    case .popover(let feed): feed.showsInfo = true
                    case .sidePane(let show): show()
                    }
                }
            }
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("会話の操作")
    }

    private var menu: some View {
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("ほかの操作")
            .accessibilityLabel("ほかの操作")
    }

    @ViewBuilder
    private var menuItems: some View {
                if conversation.engine.supports(.fork) {
                    Button("末尾からフォーク", systemImage: "arrow.triangle.branch") { perform(.fork) }
                        .disabled(generating || conversation.phase == .running)
                }
                if conversation.canUndoRewind, conversation.engine.supports(.rewind) {
                    Button("巻き戻しを元に戻す", systemImage: "arrow.uturn.forward") { undoRewind() }
                }
                if conversation.canRedoRewind, conversation.engine.supports(.rewind) {
                    Button("巻き戻しをやり直す", systemImage: "arrow.clockwise") { redoRewind() }
                }
                // オーケストレーターは画面の帯の操作（起動・停止・破棄して再起動…）で扱う。常駐が入っている間は daemon が人の停止と終了を断る
                if conversation.purpose != .orchestrator {
                    Divider()
                    ConversationNameMenuItems(conversation: conversation)
                    ConversationEndItems(conversation: conversation)
                }
    }

    /// この Mac の会話は Finder で開き、ほかのマシンの会話と iPhone・iPad はパスをコピーする
    private var opensFinder: Bool {
        #if os(macOS)
        model.isThisMac(conversation.machine)
        #else
        false
        #endif
    }

    private func revealFolder() {
        #if os(macOS)
        if opensFinder {
            NSWorkspace.shared.open(URL(fileURLWithPath: conversation.cwd, isDirectory: true))
            return
        }
        #endif
        Pasteboard.copy(conversation.cwd)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// 足した行と消した行の数。色と記号（+・−）の両方で示す
struct DiffCounts: View {
    let insertions: Int?
    let deletions: Int?

    var body: some View {
        HStack(spacing: Space.inline) {
            if let insertions { Text(verbatim: "+\(insertions)").foregroundStyle(DiffPalette.added) }
            if let deletions { Text(verbatim: "−\(deletions)").foregroundStyle(DiffPalette.removed) }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(insertions ?? 0)行追加、\(deletions ?? 0)行削除")
    }
}
