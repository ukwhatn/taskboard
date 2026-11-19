import Foundation
import Testing
@testable import Taskboard

/// 設定のキーの文字。変えるとユーザーが保存した値が読めなくなるので、今の文字のまま固定する
@Suite struct PreferenceKeyTests {
    @Test("この端末の設定のキーは今の文字のまま")
    func keys() {
        let keys: [(String, String)] = [
            (AppPreferences.appearanceKey, "appearance"),
            (AppPreferences.notifyKindsKey, "notify.kinds"),
            (AppPreferences.notifySoundKey, "notify.sound"),
            (AppPreferences.usageWindowsKey, "usage.windows"),
            (AppPreferences.collapseToolsKey, "chat.collapseTools"),
            (AppPreferences.chatFontSizeKey, "chat.fontSize"),
            (AppPreferences.voiceInputKey, "chat.voiceInput"),
            (AppPreferences.preferBuiltInMicrophoneKey, "chat.preferBuiltInMicrophone"),
            (AppPreferences.rewindNoticeDismissalsKey, "chat.rewindNoticeDismissals"),
            (AppPreferences.unreadConversationsKey, "sidebar.unreadConversations"),
            (AppPreferences.sidebarGroupingKey, "sidebar.grouping"),
            (AppPreferences.sidebarTaskOrderKey, "sidebar.taskOrder"),
            (AppPreferences.pinnedTasksKey, "sidebar.pinnedTasks"),
            (AppPreferences.terminalFontSizeKey, "terminal.fontSize"),
            (AppPreferences.terminalFontFamiliesKey, "terminal.fontFamilies"),
            (AppPreferences.terminalLightThemeKey, "terminal.theme.light"),
            (AppPreferences.terminalDarkThemeKey, "terminal.theme.dark"),
            (AppPreferences.terminalOptionAsMetaKey, "terminal.optionAsMeta"),
            (AppPreferences.terminalBellKey, "terminal.bell"),
            (AppPreferences.hiddenMachinesKey, "sidebar.hiddenMachines"),
            (AppPreferences.sidebarMachineOrderKey, "sidebar.machineOrder"),
            (AppPreferences.sidebarCollapsedKey, "sidebar.collapsed"),
            (AppPreferences.sidebarToggledNodesKey, "sidebar.toggledNodes"),
            (AppPreferences.onlyMachineEnabledKey, "onlyMachine.enabled"),
            (AppPreferences.onlyMachineIDKey, "onlyMachine.id"),
            (AppPreferences.taskPresentationKey, "task.presentation"),
            (AppPreferences.taskPanelWidthKey, "taskPanel.width"),
            (AppPreferences.taskPanelSidePaneHiddenKey, "taskPanel.detailsHidden"),
            (AppPreferences.taskSidePaneTabKey, "taskPanel.sidePaneTab"),
            (AppPreferences.taskSidePanelsKey, "taskPanel.sidePanels"),
            (AppPreferences.taskSideWidthKey, "taskPanel.sideWidth"),
            (AppPreferences.taskTerminalHeightKey, "taskPanel.terminalHeight"),
            (AppPreferences.sidebarBoardOrderKey(machine: "local"), "sidebar.boardOrder.local"),
            (AppPreferences.launchKey(.cwd, board: "b1"), "launch.cwd.b1"),
            (AppPreferences.launchKey(.kind, board: "b1"), "launch.kind.b1"),
            (AppPreferences.launchKey(.args, board: "b1"), "launch.args.b1"),
        ]
        for (key, expected) in keys {
            #expect(key == expected)
        }
    }
}
