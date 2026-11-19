import SwiftUI
import TaskboardKit

@main
struct TaskboardApp: App {
    @State private var model: AppModel
    #if os(iOS)
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate
    #endif

    init() {
        var options = LaunchOptions.parse(CommandLine.arguments)
        // fixtures・test host・debug の口で起こしたアプリは、ユーザーの設定と別の保存先を空から使う（AppDefaults）。
        // 本物の daemon に繋いだ確かめでも、案件ごとの実行方法や開き方をユーザーのアプリの値として残さない
        let testHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        if testHost {
            AppDefaults.useScratch("test-host")
            // test host の窓の model はテストが使わない。確かめるたびにユーザーの Keychain の接続と本物の daemon に触らない
            options.offline = true
            #if os(macOS)
            // xcodebuild が起こす test host をユーザーの窓の前に出さない（snapshot は窓を使わずに描く）
            NSApplication.shared.setActivationPolicy(.prohibited)
            #endif
        } else if options.scenario != nil {
            AppDefaults.useScratch("fixtures-\(options.debugPort ?? 0)")
        } else if let port = options.debugPort {
            AppDefaults.useScratch("debug-\(port)", seed: options.defaultsFile.flatMap { NSDictionary(contentsOfFile: $0) as? [String: Any] })
        }
        let model = AppModel(options: options)
        _model = State(initialValue: model)
        #if DEBUG
        if let port = options.debugPort {
            DebugServer.shared.start(port: port, model: model)
        }
        #endif
        // fixtures（snapshot test）・test host・`--no-notifications` では通知の許可を求めない
        if options.scenario == nil, !options.noNotifications, !testHost {
            InboxNotifier.shared.start(model: model, provisional: options.provisionalNotifications)
        }
    }

    var body: some Scene {
        // 窓の id は固定する。無いと窓の識別子（大きさを覚える鍵）が中身の型の名前になり、窓の根の modifier を変えるたびに変わる
        WindowGroup(id: "main") {
            RootView()
                .windowMinimum(WindowMetrics.main)
                .modifier(WindowRoot(model: model))
                .onOpenURL { url in model.open(url, from: .url) }
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 820)
        #endif
        .commands {
            // サイドバーの切り替えを、ほかの Mac のアプリと同じ［表示］に置く（⌃⌘S）
            SidebarCommands()
            BoardCommands(model: model)
            SessionCommands(model: model)
        }

        // ⌘ クリックで開く別ウィンドウ。1 タスク 1 ウィンドウ（同じタスクをもう一度開くと前のウィンドウが前に出る）
        WindowGroup("タスク", id: "task", for: TaskKey.self) { $key in
            if let key {
                TaskPanel(key: key, inWindow: true)
                    .windowMinimum(WindowMetrics.task)
                    .navigationTitle(model.fleet.task(for: key).map { "#\($0.number) \($0.title)" } ?? "タスク")
                    .modifier(FailureBanner())
                    .modifier(WindowRoot(model: model))
            }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif

        // 文書の別ウィンドウ。読む幅とコメントの欄を並べて出す
        WindowGroup("文書", id: "document", for: DocKey.self) { $key in
            if let key {
                // 同じタスクの別の文書へは、このウィンドウの中で切り替える
                DocumentScreen(key: key, inWindow: true) { $key.wrappedValue = $0 }
                    .id(key)
                    .windowMinimum(WindowMetrics.document)
                    .navigationTitle(model.fleet.document(for: key)?.displayTitle ?? "文書")
                    .pageInsets()
                    .modifier(FailureBanner())
                    .modifier(WindowRoot(model: model))
            }
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif

        #if os(macOS)
        // ⌘, の設定ウインドウ。同じ AppModel を渡す（新しく作ると接続が二重になる）
        Settings {
            SettingsView()
                .modifier(WindowRoot(model: model))
                .frame(
                    minWidth: WindowMetrics.settings.width, idealWidth: WindowMetrics.settingsIdeal.width,
                    minHeight: WindowMetrics.settings.height, idealHeight: WindowMetrics.settingsIdeal.height)
        }
        #endif
    }
}

/// メニュー。標準の構成（ファイル・編集・表示・ウィンドウ・ヘルプ）に、このアプリの［移動］と［タスク］を足す。
/// 修飾キーの無いキー（↩・矢印・hjkl・Esc）と ⌘⌫ はメニューに置かない（入力欄のキーを奪うので、ボードと応答のシートが受ける）。
/// 項目は状態で無効にせず、使えないときは何もしない。Commands は model の変化で描き直されず（`let model`・ObservableObject・
/// focusedSceneValue のどれでも起動直後のまま残った）、案件が届く前の無効・0 件で固まるため。
/// 切り替えの項目（開き方、1台だけ表示）のチェックは、メニューを開くたびに `MenuCheckmarks` が付ける
struct BoardCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("タスクを追加…") { model.startNewTask() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("移動") {
            Button("検索・コマンド…") { model.paletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
            // Codex Desktop の「Next chat needing attention」と同じキー
            Button("次の入力待ちへ移動") { model.openNextAttention() }
                .keyboardShortcut("a", modifiers: [.option, .command])
            Divider()
            // 案件はサイドバーの順に 1〜9。メニューは描き直されないので、名前は番号で固定する
            ForEach(1...9, id: \.self) { slot in
                Button("案件\(slot)") { model.selectSidebarBoard(slot) }
                    .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .command)
            }
        }
        CommandMenu("タスク") {
            Button("別ウインドウで開く") {
                // パレットを開いていれば、パレットで選んでいる行を開く（ボードで選んでいるタスクではない）
                if model.paletteOpen {
                    model.paletteOpenSeparatelyRequests += 1
                } else if let key = model.keyboardTarget {
                    openWindow(value: key)
                }
            }
                .keyboardShortcut(.return, modifiers: .command)
            Button("セッションを起動…") { model.launchForTarget() }
            Divider()
            Button("左の列へ移動") { model.moveSelectedTask(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Button("右の列へ移動") { model.moveSelectedTask(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Divider()
            Button("セッションの入力欄へ移動") { model.requestSessionFocus() }
                .keyboardShortcut("l", modifiers: .command)
            Button("次のセッションを表示") { model.cycleSession(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("前のセッションを表示") { model.cycleSession(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Divider()
            ForEach(Array(TaskPresentation.allCases.enumerated()), id: \.element) { index, presentation in
                Button(presentation.label) { model.present(presentation, from: .key) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.option, .command])
            }
        }
        // 標準のヘルプの項目（ヘルプブック）は持たないので、ショートカットの一覧に置き換える
        CommandGroup(replacing: .help) {
            Button("ショートカットの一覧を表示") { model.shortcutsOpen = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}

struct SessionCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("検索…") { model.sessionActions?.find() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            // 端末もチャットも出ていなければ何もしない（項目は常に有効。上の `SessionViewActions` の理由）
            Button("拡大") { model.sessionActions?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("縮小") { model.sessionActions?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("実際のサイズ") { model.sessionActions?.zoomReset() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("1台だけ表示") { model.toggleOnlyMachine() }
                .keyboardShortcut("1", modifiers: [.control, .command])
            Divider()
            // Commands は描き直されないので、今の形によらない名前にする
            Button("会話と列を切り替える") { model.toggleHomeLayout() }
                .keyboardShortcut("b", modifiers: .command)
            Button("ボードに戻る") {
                Self.leaveTerminal()
                model.boardFocusRequests += 1
            }
                .keyboardShortcut("j", modifiers: .command)
        }
        // キーは Claude Desktop と同じ。Esc（生成を停止）・⌘↩（応答が終わってから送信）・⌥⌘↩（フォークして送信）は入力欄が受ける
        CommandMenu("会話") {
            Button("末尾からフォーク") { model.sessionActions?.conversation?.fork() }
                .keyboardShortcut("o", modifiers: [.option, .command])
            Divider()
            Button("権限のモードを変更…") { model.sessionActions?.conversation?.openField(.permission) }
                .keyboardShortcut("m", modifiers: [.shift, .command])
            Button("モデルを変更…") { model.sessionActions?.conversation?.openField(.model) }
                .keyboardShortcut("i", modifiers: [.shift, .command])
            Button("エフォートを変更…") { model.sessionActions?.conversation?.openField(.effort) }
                .keyboardShortcut("e", modifiers: [.shift, .command])
            Divider()
            Button("前のメッセージへ移動") { model.sessionActions?.conversation?.jump(false) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button("次のメッセージへ移動") { model.sessionActions?.conversation?.jump(true) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
        }
    }

    /// 端末やチャットの入力からフォーカスを外す。キーがボード（⌥⌘← → など）に届くようになる
    @MainActor
    static func leaveTerminal() {
        #if os(macOS)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #else
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }
}
