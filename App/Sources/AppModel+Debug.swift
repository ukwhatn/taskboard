import Foundation
import SwiftUI
import TaskboardKit

extension AppModel {
    /// サイドバーの木（マシン → 案件 → 列 → タスクの札と委譲先の進み、タスクなしの数）
    private var sidebarTreeDescription: [[String: Any]] {
        let waiting = waitingItemsByTask
        return orderedMachines.map { machine in
            let state = machine.state
            let active = sidebarActiveTasks(state)
            let boards = orderedBoards(state, fleetID: machine.id).map { board -> [String: Any] in
                let columns = board.orderedColumns.compactMap { column -> [String: Any]? in
                    let tasks = sidebarTasks(in: board, column: column, state: state, waiting: waiting, active: active)
                    guard !tasks.isEmpty else { return nil }
                    return [
                        "id": column.id, "expanded": isSidebarNodeExpanded("column/\(board.machine.rawValue)/\(board.id)/\(column.id)", collapsedByDefault: column.collapsed),
                        "tasks": tasks.map { task in
                            ["number": task.number, "status": rowStatus(of: task, waiting: waiting[task.id] ?? []).map(\.label) as Any, "progress": delegateProgress(of: task)?.label as Any]
                        },
                    ]
                }
                return ["id": board.id, "columns": columns]
            }
            let unassigned = state.machine.map { self.unassigned(on: $0.id) }
            let row = { (task: BoardTask, status: TaskRowStatus?) -> [String: Any] in ["number": task.number, "status": status?.label as Any] }
            let arranged: Any
            switch sidebarArrangement.grouping {
            case .boards: arranged = NSNull()
            case .state:
                arranged = sidebarStateGroups(on: state, fleetID: machine.id, waiting: waiting, active: active)
                    .map { ["group": $0.group.label, "tasks": $0.rows.map(row)] as [String: Any] }
            case .none:
                arranged = sidebarTasks(on: state, fleetID: machine.id, waiting: waiting, active: active)
                    .map { row($0, rowStatus(of: $0, waiting: waiting[$0.id] ?? [])) }
            }
            return [
                "machine": machine.id, "boards": boards, "arranged": arranged, "pinned": pinnedSidebarTasks(on: state).map(\.number),
                "unassigned": unassigned.map { ["sessions": $0.sessions.rows.map(\.conversation.id), "schedules": $0.schedules.map(\.scheduleID)] } as Any,
            ]
        }
    }

    /// DebugServer の `/state` が返す、画面の今。
    var debugDescription: [String: Any] {
        [
            "sidebar": sidebar.id,
            "sidebarArrangement": ["grouping": sidebarArrangement.grouping.rawValue, "order": sidebarArrangement.order.rawValue],
            "settingsSection": settingsSection.rawValue,
            "taskPresentation": taskPresentation.rawValue,
            "sessionFocus": sessionFocus.map { "\($0.scope)/\($0.item)" } as Any,
            "selectedTask": selectedTask.map { "\($0.machine.rawValue)/\($0.number)" } as Any,
            "phoneTaskConversation": phoneTaskItem?.description as Any,
            "activeConversation": activeConversation?.debugDescription as Any,
            "subscribedConversations": fleet.subscribedConversations.map { ["key": $0.key.description, "count": $0.value] },
            "keepsSubscriptions": fleet.keepsSubscriptions,
            "home": homeDebugDescription,
            "cursorTask": cursorTask.map { "\($0.machine.rawValue)/\($0.number)" } as Any,
            "paletteOpen": paletteOpen,
            "shortcutsOpen": shortcutsOpen,
            "newBoardSheet": newBoardSheet != nil,
            "newTaskSheet": newTaskSheet != nil,
            "launchSheet": launchSheet != nil,
            "openDoc": openDoc.map { "\($0.machine.rawValue)/doc/\($0.id)" } as Any,
            "selectedPR": selectedPR as Any,
            "prs": fleet.allPullRequests.map { ["url": $0.url, "label": $0.shortLabel, "category": $0.category.rawValue, "checks": $0.checks?.rawValue as Any, "machine": $0.machine.rawValue] },
            "onlyMachine": ["enabled": onlyMachineEnabled, "id": onlyMachineID, "label": onlyMachineLabel as Any, "visible": Array(fleet.machines.keys)],
            "inbox": [
                "waiting": inboxWaitingCount,
                "hiddenIncluded": inboxItemsIncludingHidden.count, "posted": InboxNotifier.shared.recentlyPosted,
                "items": inboxItems.map { ["id": $0.id, "group": $0.group == .waiting ? "waiting" : "notice", "title": $0.title, "detail": $0.detail, "task": $0.taskNumber as Any] },
                "dismissed": fleet.inbox.dismissed.map(\.id), "pending": inboxPending.count,
            ],
            "prewarm": lastPrewarm.map { record in
                [
                    "machine": record.call?.target.machine.rawValue as Any, "cwd": record.call?.target.request.cwd as Any,
                    "model": record.call?.target.request.model as Any, "effort": record.call?.target.request.effort as Any,
                    "at": record.call.map { ISO8601DateFormatter().string(from: $0.at) } as Any, "error": record.error as Any,
                ]
            } as Any,
            "sidebarTree": sidebarTreeDescription,
            "sidebarOrchestrators": orchestratorRows.map { row in
                [
                    "machine": row.machine.rawValue, "status": row.statusLabel, "badge": row.badge,
                    "conversation": row.conversation?.id as Any, "canStart": row.canStart,
                    "canStop": row.canStop,
                ]
            },
            "orchestrator": orchestratorMachine.map { machine in
                [
                    "machine": machine.rawValue,
                    "conversation": fleet.orchestratorConversation(on: machine).map { ["id": $0.id, "phase": $0.phase.rawValue] } as Any,
                    "history": (orchestratorHistory[machine] ?? []).map(\.text),
                ]
            } as Any,
            "scenario": scenario as Any,
            "connectionNote": connectionNote as Any,
            "failure": failure(in: activeWindow)?.text as Any,
            // 開いている窓ごとの失敗と確認。開いたか前に出た順で、最後が前に出ている窓
            "windows": windowOrder.map { ["failure": failure(in: $0)?.text as Any, "confirmation": confirmation(in: $0).map { String(describing: $0) } as Any] },
            "appearance": appearanceOverride.map { $0 == .dark ? "dark" : "light" } ?? "system",
            "terminal": activeTerminal?.debugDescription as Any,
            "parkedTerminals": terminalShelf.parkedKeys.map { "\($0.machine.rawValue)/\($0.pane.rawValue)" },
            "events": eventLog.debugDescription,
            "machines": fleet.machines.map { id, state in
                [
                    "id": id,
                    "connected": state.connected,
                    "name": state.machine?.name as Any,
                    "machineID": state.machine?.id.rawValue as Any,
                    "boards": state.boards.values.sorted { $0.position < $1.position }.map {
                        ["id": $0.id, "name": $0.name, "columns": $0.columns.count]
                    },
                    "taskCount": state.tasks.count,
                    "workItemCount": state.workItems.count,
                    "documents": state.documents.values.sorted { $0.docID < $1.docID }.map {
                        ["id": $0.docID, "task": $0.taskNumber, "name": $0.name, "format": $0.format.rawValue, "rev": $0.latestRev, "openComments": $0.openComments, "draftComments": $0.draftComments]
                    },
                    "asks": state.asks.values.sorted { $0.askID < $1.askID }.map {
                        ["id": $0.askID, "task": $0.taskNumber, "doc": $0.docID, "status": $0.status.rawValue, "questions": $0.questions.count]
                    },
                    "reviewRequests": state.reviewRequests.values.map { ["task": $0.taskNumber, "note": $0.note] },
                    "conversations": state.conversations.values.sorted { $0.createdAt < $1.createdAt }.map {
                        ["id": $0.id, "task": $0.taskNumber as Any, "phase": $0.phase.rawValue, "title": $0.title as Any, "requests": $0.requests.map(\.id)]
                    },
                    "streaming": state.machine.map { fleet.isStreaming($0.id) } ?? false,
                    "lastError": state.lastError as Any,
                ]
            },
        ]
    }
}
