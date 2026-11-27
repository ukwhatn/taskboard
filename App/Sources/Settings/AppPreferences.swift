import SwiftUI
import TaskboardKit

/// この端末の設定（UserDefaults）のキー。読み書きは `DevicePrefs`。案件・列・起動の既定は daemon に置くのでここには無い（47 §5）。
/// キーはすべてここに置く。文字を変えると保存した値が読めなくなるので変えない。設定画面の項目のキーは daemon に写すので `ClientPref` が決める
enum AppPreferences {
    static let appearanceKey = ClientPref.appearance.rawValue
    static let notifyKindsKey = ClientPref.notifyKinds.rawValue
    static let notifyTurnsKey = ClientPref.notifyTurns.rawValue
    static let notifySoundKey = ClientPref.notifySound.rawValue
    static let usageWindowsKey = ClientPref.usageWindows.rawValue
    static let collapseToolsKey = ClientPref.chatCollapseTools.rawValue
    static let chatFontSizeKey = ClientPref.chatFontSize.rawValue
    /// 入力欄の［音声入力］のボタン（Mac は ⌥Space も）
    static let voiceInputKey = ClientPref.chatVoiceInput.rawValue
    /// 音声入力で、AirPods などをつないでいても内蔵のマイクで聞く（既定はオン）
    static let preferBuiltInMicrophoneKey = ClientPref.chatPreferBuiltInMicrophone.rawValue
    /// 巻き戻した会話の［元に戻す］のバーを消した・送った印（`RewindNoticeDismissals`）
    static let rewindNoticeDismissalsKey = "chat.rewindNoticeDismissals"
    static let terminalFontSizeKey = ClientPref.terminalFontSize.rawValue
    static let terminalFontFamiliesKey = ClientPref.terminalFontFamilies.rawValue
    static let terminalLightThemeKey = ClientPref.terminalLightTheme.rawValue
    static let terminalDarkThemeKey = ClientPref.terminalDarkTheme.rawValue
    static let terminalOptionAsMetaKey = ClientPref.terminalOptionAsMeta.rawValue
    static let terminalBellKey = ClientPref.terminalBell.rawValue
    static let hiddenMachinesKey = "sidebar.hiddenMachines"
    static let sidebarMachineOrderKey = "sidebar.machineOrder"
    static let sidebarCollapsedKey = "sidebar.collapsed"
    static let sidebarToggledNodesKey = "sidebar.toggledNodes"
    /// サイドバーのタスクの行の「未読」の印（`UnreadMarks`）。未読の会話
    static let unreadConversationsKey = "sidebar.unreadConversations"
    /// サイドバーの並べ方（`SidebarArrangement`）
    static let sidebarGroupingKey = "sidebar.grouping"
    static let sidebarTaskOrderKey = "sidebar.taskOrder"
    /// サイドバーの先頭に出すタスク（［ピン留め］）
    static let pinnedTasksKey = "sidebar.pinnedTasks"
    static let onlyMachineEnabledKey = ClientPref.onlyMachineEnabled.rawValue
    static let onlyMachineIDKey = "onlyMachine.id"
    static let taskPresentationKey = ClientPref.taskPresentation.rawValue
    /// ホームの形（`HomeLayout`。⌘B）
    static let homeLayoutKey = "home.layout"
    static let taskPanelWidthKey = "taskPanel.width"
    static let taskPanelSidePaneHiddenKey = "taskPanel.detailsHidden"
    /// iPhone のタスク画面で前に選んだ欄（`SidePanel`）
    static let taskSidePaneTabKey = "taskPanel.sidePaneTab"
    /// Mac と iPad のタスク画面の右側に開いている欄の組と大きさ（`SidePanelSet` の JSON）
    static let taskSidePanelsKey = "taskPanel.sidePanels"
    /// Mac と iPad のタスク画面の右側の幅（境目を動かして残した幅。0 なら既定）
    static let taskSideWidthKey = "taskPanel.sideWidth"
    /// 会話の頭の部品を折りたたんでいるか（`PanelHead`。タスクによらず 1 つ）
    static let taskPanelHeadCollapsedKey = "taskPanel.headCollapsed"
    /// Mac と iPad のタスク画面の下の端末の欄の高さ（境目を動かして残した高さ。0 なら既定）
    static let taskTerminalHeightKey = "taskPanel.terminalHeight"
    /// 文書ごとに、リモートコンテンツを読み込むと許したホスト（`DocumentRemoteContent`）
    static let docRemoteHostsKey = "doc.remoteHosts"
    /// 文書の［エディタで開く］の URL（`{path}` を元のファイルのパスに置き換える）
    static let docEditorURLKey = ClientPref.docEditorURL.rawValue
    /// セッションの画面でチャットと端末のどちらを出すか

    static func sidebarBoardOrderKey(machine: String) -> String { "sidebar.boardOrder.\(machine)" }

    /// 案件ごとに前回の起動で選んだもの
    enum LaunchField: String { case cwd, kind, args }
    static func launchKey(_ field: LaunchField, board: String) -> String { "launch.\(field.rawValue).\(board)" }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "システムに合わせる")
        case .light: String(localized: "ライト")
        case .dark: String(localized: "ダーク")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    init(_ scheme: ColorScheme?) {
        switch scheme {
        case .light: self = .light
        case .dark: self = .dark
        default: self = .system
        }
    }
}

/// マシンの見出しに出す利用枠のバー
enum UsageWindowChoice: String, CaseIterable, Identifiable {
    case claudeFiveHour = "Claude/5h"
    case claudeWeek = "Claude/1w"
    case codex = "Codex"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeFiveHour: String(localized: "Claude 5時間")
        case .claudeWeek: String(localized: "Claude 1週間")
        case .codex: "Codex"
        }
    }

    /// Claude の窓は、マシンのログイン（`Claude/5h`）と taskboard のアカウント（`Claude:<名前>/5h`）のどちらの行にも当てる
    func includes(_ row: UsageRowModel) -> Bool {
        switch self {
        case .codex: row.group == "Codex"
        default: row.id == rawValue || (row.id.hasPrefix("Claude:") && row.id.hasSuffix(rawValue.dropFirst("Claude".count)))
        }
    }
}
