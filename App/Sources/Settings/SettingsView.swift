import SwiftUI
import TaskboardKit

/// 設定画面。左に区分、右に中身。iPhone は区分の一覧から押して開く
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if sizeClass == .compact {
                // 行に移動先を直接持たせると、他の画面から区分を指定して開けない（［案件の設定を開く］など）ので、開く区分を model に持つ
                List(SettingsSection.shown) { section in
                    Button {
                        model.compactSettingsSection = section
                    } label: {
                        HStack {
                            Label {
                                Text(section.title).foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: section.symbol)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                }
                .navigationTitle("設定")
                .navigationDestination(item: Bindable(model).compactSettingsSection) { section in
                    SettingsSectionView(section: section)
                }
            } else {
                split
            }
            #else
            split
            #endif
        }
        .pageInsets()
        #if os(macOS)
        // ⌘, の設定ウィンドウは主ウィンドウと別の窓なので、この窓で始めた操作の失敗はここの帯に出す
        .modifier(FailureBanner())
        #endif
    }

    /// Mac と iPad: 左に区分、右に中身。区分を移るときは、保存していない変更を確かめる
    private var split: some View {
        HStack(spacing: 0) {
            List(SettingsSection.shown, selection: Binding<SettingsSection?>(
                get: { model.settingsSection },
                set: { if let section = $0, section != model.settingsSection { model.leaveSettings(.section(section)) } })
            ) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: SettingsMetrics.sectionListWidth)
            Divider()
            SettingsSectionView(section: model.settingsSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("設定")
    }
}

/// 1 区分の中身。中身の幅は区分ごとに `settingsContentWidth()` で揃える（保存の帯は幅いっぱいに置くので、ここでは包まない）
struct SettingsSectionView: View {
    @Environment(AppModel.self) private var model
    let section: SettingsSection

    var body: some View {
        Group {
            switch section {
            case .connections: ConnectionSettings()
            case .boards: BoardSettings()
            case .sessions: SessionSettingsForm()
            case .terminal: TerminalSettingsForm()
            case .chat: ChatSettingsForm()
            case .notifications: NotificationSettingsForm()
            case .display: DisplaySettingsForm()
            case .usage: UsageSettings()
            case .shortcuts: ShortcutSettingsList().settingsContentWidth()
            }
        }
        .navigationTitle(section.title)
        .confirmationDialog(
            "変更の破棄", isPresented: Binding(get: { model.settingsLeaveRequest != nil }, set: { if !$0 { model.settingsLeaveRequest = nil } }),
            presenting: model.settingsLeaveRequest
        ) { destination in
            Button("破棄", role: .destructive) { model.performSettingsLeave(destination) }
            Button("キャンセル", role: .cancel) { model.settingsLeaveRequest = nil }
        } message: { _ in
            Text("「\(model.settingsBoardPath.first.flatMap(model.settingsBoard)?.name ?? "")」の保存していない変更を破棄しますか？　この操作は元に戻せません。")
        }
    }
}

extension View {
    /// 設定の中身の幅。区分ごとに中身の幅で決まると、行き来するたびに欄の位置が変わる
    @ViewBuilder func settingsContentWidth() -> some View {
        #if os(iOS)
        // 絞った幅の外にも Form と同じ背景を敷く（iPad の横で、Form の左右に白い帯が出た）
        frame(maxWidth: ReadableWidth.form).frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        #else
        frame(maxWidth: ReadableWidth.form).frame(maxWidth: .infinity)
        #endif
    }

    /// 設定の帯（保存の帯、案件の見出し）の中身。帯の背景は幅いっぱいに引き、中身の左右の端は Form の中身の幅に揃える
    func settingsBarContent() -> some View {
        modifier(SettingsBarContent())
    }
}

private struct SettingsBarContent: ViewModifier {
    @Environment(\.pageInset) private var inset

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, inset)
            .padding(.vertical, Space.row)
            .frame(maxWidth: ReadableWidth.form)
            .frame(maxWidth: .infinity)
    }
}

/// 下書きを daemon に送る区分（案件）の下の帯。保存の結果とエラーもここに出す。変更が無いときは押せない
struct SettingsSaveBar: View {
    var message: String?
    var error: String?
    let saving: Bool
    let dirty: Bool
    let revert: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let message {
                    Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.block)
                if saving { ProgressView().controlSize(.small) }
                Button("キャンセル", action: revert).disabled(saving || !dirty)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saving || !dirty)
            }
            .font(.callout)
            .settingsBarContent()
        }
        .background(.bar)
    }
}

// MARK: - 端末

struct TerminalSettingsForm: View {
    @AppStorage(AppPreferences.terminalFontSizeKey) private var fontSize = SessionTextSize.terminalDefault
    @AppStorage(AppPreferences.terminalLightThemeKey) private var lightTheme = TerminalSettings.defaultLightTheme
    @AppStorage(AppPreferences.terminalDarkThemeKey) private var darkTheme = TerminalSettings.defaultDarkTheme
    @AppStorage(AppPreferences.terminalOptionAsMetaKey) private var optionAsMeta = TerminalSettings.defaultOptionAsMeta
    @AppStorage(AppPreferences.terminalBellKey) private var bell = TerminalSettings.defaultBell
    @State private var fonts = TerminalSettings().fontFamilies.joined(separator: ", ")
    @State private var picking: ThemeSlot?

    var body: some View {
        Form {
            Section {
                LabeledTextField(label: String(localized: "フォント"), text: $fonts, prompt: TerminalSettings.defaultFontFamilies.joined(separator: ", "))
                    .onChange(of: fonts) { _, _ in saveFonts() }
                Stepper(value: $fontSize, in: SessionTextSize.range, step: 1) {
                    LabeledContent("文字の大きさ", value: String(localized: "\(Int(fontSize))pt"))
                }
            } footer: {
                Text("フォントはカンマで区切って、優先する順に入力してください。")
            }
            Section("テーマ") {
                ThemeRow(label: String(localized: "ライト"), theme: lightTheme) { picking = .light }
                ThemeRow(label: String(localized: "ダーク"), theme: darkTheme) { picking = .dark }
            }
            Section("入力") {
                #if os(macOS)
                Toggle("⌥をMetaキーとして使う", isOn: $optionAsMeta)
                #endif
                Toggle("ベルで音を鳴らす", isOn: $bell)
            }
            Section {
                Button("初期値に戻す") { reset() }
            }
        }
        .formStyle(.grouped)
        .settingsContentWidth()
        .sheet(item: $picking) { slot in
            ThemePickerSheet(slot: slot, selection: slot == .light ? $lightTheme : $darkTheme)
        }
    }

    private func saveFonts() {
        let families = fonts.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if families.isEmpty || families == TerminalSettings.defaultFontFamilies {
            AppDefaults.store.removeObject(forKey: AppPreferences.terminalFontFamiliesKey)
        } else {
            AppDefaults.store.set(families, forKey: AppPreferences.terminalFontFamiliesKey)
        }
    }

    private func reset() {
        for key in [AppPreferences.terminalFontFamiliesKey, AppPreferences.terminalLightThemeKey, AppPreferences.terminalDarkThemeKey, AppPreferences.terminalOptionAsMetaKey, AppPreferences.terminalBellKey, AppPreferences.terminalFontSizeKey] {
            AppDefaults.store.removeObject(forKey: key)
        }
        fonts = TerminalSettings.defaultFontFamilies.joined(separator: ", ")
        lightTheme = TerminalSettings.defaultLightTheme
        darkTheme = TerminalSettings.defaultDarkTheme
        optionAsMeta = TerminalSettings.defaultOptionAsMeta
        bell = TerminalSettings.defaultBell
        fontSize = SessionTextSize.terminalDefault
    }
}

/// テーマの行。押すと検索できる一覧を開く（テーマは数百ある）
private struct ThemeRow: View {
    let label: String
    let theme: String
    let open: () -> Void

    var body: some View {
        LabeledContent(label) {
            Button(action: open) {
                HStack(spacing: Space.inline) {
                    Text(verbatim: theme).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(label)のテーマ（\(theme)）")
        }
    }
}

// MARK: - チャット

struct ChatSettingsForm: View {
    @AppStorage(AppPreferences.chatFontSizeKey) private var fontSize = SessionTextSize.chatDefault
    @AppStorage(AppPreferences.collapseToolsKey) private var collapseTools = true
    @AppStorage(AppPreferences.voiceInputKey) private var voiceInput = true
    @AppStorage(AppPreferences.preferBuiltInMicrophoneKey) private var preferBuiltInMicrophone = true

    var body: some View {
        Form {
            Stepper(value: $fontSize, in: SessionTextSize.range, step: 1) {
                LabeledContent("文字の大きさ", value: String(localized: "\(Int(fontSize))pt"))
            }
            Toggle("ツールの実行を初めから折りたたむ", isOn: $collapseTools)
            Toggle("音声入力のボタンを表示する", isOn: $voiceInput)
            Toggle("内蔵のマイクを優先する", isOn: $preferBuiltInMicrophone)
                .disabled(!voiceInput)
        }
        .formStyle(.grouped)
        .settingsContentWidth()
    }
}

// MARK: - 通知

struct NotificationSettingsForm: View {
    @AppStorage(AppPreferences.notifySoundKey) private var sound = true
    @AppStorage(AppPreferences.notifyTurnsKey) private var turns = TurnNotify.never
    @State private var kinds = DevicePrefs().notifyKinds

    var body: some View {
        Form {
            Section {
                ForEach(NotifyKind.allCases) { kind in
                    Toggle(isOn: Binding(
                        get: { kinds.contains(kind) },
                        set: { on in
                            if on { kinds.insert(kind) } else { kinds.remove(kind) }
                            DevicePrefs().notifyKinds = kinds
                        })
                    ) {
                        Text(kind.label)
                        if let detail = kind.detail { Text(detail) }
                    }
                }
            } header: {
                Text("通知する種類")
            } footer: {
                Text("オフにした種類も、サイドバーとアイコンのバッジには表示されます。")
            }
            Section {
                Picker("応答の完了", selection: $turns) {
                    ForEach(TurnNotify.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("セッションと会話が応答を終えたときに通知します。")
            }
            Section {
                Toggle("音を鳴らす", isOn: $sound)
            }
            #if os(iOS)
            PushDeliverySection()
            #endif
        }
        .formStyle(.grouped)
        .settingsContentWidth()
    }
}

/// アプリを閉じているときに、接続先ごとに通知が届くか（iPhone・iPad だけ。Mac のアプリは裏に回っても止まらない）
struct PushDeliverySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.connections.isEmpty {
            Section("アプリを閉じているときの通知") {
                ForEach(model.connections) { connection in
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text(verbatim: connection.name)
                        Text(PushCenter.shared.status(for: connection, hidden: !model.fleet.isVisible(fleetID: connection.fleetID)).text)
                    }
                }
            }
        }
    }
}

// MARK: - 表示

struct DisplaySettingsForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledSegmentedPicker(String(localized: "外観"), selection: Binding(
                    get: { AppearanceChoice(model.appearanceOverride) },
                    set: { model.appearanceOverride = $0.colorScheme })
                ) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                }
                if !AppModel.isPhone {
                    // iPhone のタスクは常に画面を移って開くので、開き方を選べない
                    LabeledSegmentedPicker(String(localized: "タスクの開き方"), selection: $model.taskPresentation) {
                        ForEach(TaskPresentation.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            Section {
                Toggle("1台だけ表示", isOn: $model.onlyMachineEnabled)
                Picker("表示するMac", selection: $model.onlyMachineID) {
                    ForEach(model.onlyMachineCandidates, id: \.id) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }
                .disabled(!model.onlyMachineEnabled)
            } footer: {
                #if os(macOS)
                Text("選んだMac以外の画面、通知、Dockのバッジを非表示にします。⌃⌘1で切り替えられます。")
                #else
                Text("選んだMac以外の画面と通知を非表示にします。")
                #endif
            }
            Section("Macの見出しに表示する利用枠") {
                ForEach(UsageWindowChoice.allCases) { window in
                    Toggle(window.label, isOn: Binding(
                        get: { model.usageWindows.contains(window) },
                        set: { on in
                            if on { model.usageWindows.insert(window) } else { model.usageWindows.remove(window) }
                        }))
                }
            }
            Section {
                Button("案件の設定を開く") { model.leaveSettings(.section(.boards)) }
            } footer: {
                Text("初めから折りたたむ列は、［案件］で案件ごとに設定します。")
            }
        }
        .formStyle(.grouped)
        .settingsContentWidth()
    }
}
