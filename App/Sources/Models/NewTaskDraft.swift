import SwiftUI
import TaskboardKit

/// 起票の下書き。案件と列、題、リンク、期日、起動先と起動プロンプト。
struct NewTaskDraft: Identifiable, Hashable {
    var id = UUID()
    var board: Board
    var columnID: String
    var title = ""
    var note = ""
    /// 1 件 1 行。末尾はいつも空の行（次のリンクを書く欄）
    var links: [String] = [""]
    var due: Date? = nil
    var launch: LaunchDraft
    /// 追加した後に紐づける会話（タスクなしの画面の［タスクを追加…］）。あれば起動せず、案件はそのマシンのものに限る
    var attach: ConversationKey?

    init(board: Board) {
        self.board = board
        columnID = board.defaultColumn?.id ?? board.orderedColumns.first?.id ?? ""
        launch = LaunchDraft.initial(machine: board.machine, board: board, boardID: board.id, columnID: columnID)
    }

    /// daemon へ送る形。題の前後の空白は落とし、空のリンクは送らない。題が空なら仮の題を付ける（起動したセッションが付け直す）
    var request: TaskCreateRequest {
        let title = title.trimmingCharacters(in: .whitespaces)
        return TaskCreateRequest(
            boardID: board.id, columnID: columnID, title: title.isEmpty ? SessionGuidance.untitledTaskTitle : title, note: note,
            due: due.map { BoardTask.dateFormatter.string(from: $0) },
            links: links.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// リンクの欄を直す。1 行に複数の URL を貼ったら（改行か空白で区切られていれば）行ごとに分け、末尾に空の行を 1 つ残す
    static func normalizedLinks(_ links: [String]) -> [String] {
        var rows: [String] = []
        for row in links {
            let parts = row.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            if parts.count > 1 {
                rows += parts
            } else if parts.count == 1 {
                // 1 件だけなら書いている途中の文字をそのまま残す（前後の空白は送るときに落とす）
                rows.append(row.contains(where: \.isNewline) ? parts[0] : row)
            } else {
                rows.append(row)
            }
        }
        // 途中の空の行は残す（書き直している途中）。末尾の空の行は 1 つにする
        while rows.count > 1, rows.last?.isEmpty == true, rows[rows.count - 2].isEmpty { rows.removeLast() }
        if rows.last?.isEmpty != true { rows.append("") }
        return rows
    }
}
