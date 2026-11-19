import Foundation
import GRDB
import TaskboardKit

extension Store {
    /// 冪等。`(boardId, importedId)` で突き合わせ、無ければ挿入、違っていれば更新。
    /// タスクが 1 件も無い DB への最初の取り込みでは taskherd の id を番号として保つ（`#132` がそのまま通じるように）。
    public func importTaskherd(_ request: TaskherdImportRequest) throws -> (TaskherdImportResult, [BoardTask], Board) {
        let imported = try database.write { db -> (TaskherdImportResult, [BoardTask], Board) in
            let board: BoardRow
            if let existing = try BoardRow.filter(Column("name") == request.boardName).fetchOne(db) {
                board = existing
            } else {
                let position = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) + 1 FROM board") ?? 0
                board = BoardRow(id: UUID().uuidString.lowercased(), name: request.boardName, position: position, createdAt: Date())
                try board.insert(db)
            }
            if let template = request.promptTemplate {
                try db.execute(sql: "UPDATE board SET promptTemplate = ? WHERE id = ?", arguments: [template, board.id])
            }
            // 列: 既存に無いものだけ足す（ラベルは既存を優先）
            let columns = request.columns.isEmpty ? BoardColumn.standard : request.columns
            var knownColumns = Set(try ColumnRow.filter(Column("boardId") == board.id).fetchAll(db).map(\.id))
            for column in columns where !knownColumns.contains(column.id) {
                try ColumnRow(
                    boardId: board.id, id: column.id, label: column.label, kind: column.kind.rawValue, position: knownColumns.count,
                    collapsed: column.collapsed, description: column.description
                ).insert(db)
                knownColumns.insert(column.id)
            }
            if let templates = request.columnTemplates {
                for (columnID, template) in templates where knownColumns.contains(columnID) {
                    try db.execute(
                        sql: "UPDATE boardColumn SET promptTemplate = ? WHERE boardId = ? AND id = ?", arguments: [template, board.id, columnID])
                }
            }
            let preserveNumbers = try TaskRow.fetchCount(db) == 0
            var inserted = 0
            var updated = 0
            var unchanged = 0
            var keptLocal = 0
            var touched: [Int] = []
            for source in request.tasks {
                if !knownColumns.contains(source.status) {
                    try ColumnRow(boardId: board.id, id: source.status, label: source.status, kind: "open", position: knownColumns.count).insert(db)
                    knownColumns.insert(source.status)
                }
                let existing = try TaskRow.filter(Column("boardId") == board.id && Column("importedId") == source.id).fetchOne(db)
                var row: TaskRow
                if let existing {
                    row = existing
                    let changed =
                        row.title != source.title || row.columnId != source.status || row.note != source.note || row.due != source.due
                        || row.updatedAt != source.updatedAt
                    if changed, row.updatedAt > source.updatedAt {
                        // daemon 側（PR の状態による列の前進・アプリの編集）の方が新しい。取り込み元の古い値で戻さない
                        keptLocal += 1
                    } else if changed {
                        row.title = source.title
                        row.columnId = source.status
                        row.note = source.note
                        row.due = source.due
                        row.updatedAt = source.updatedAt
                        try row.update(db)
                        updated += 1
                    } else {
                        unchanged += 1
                    }
                } else {
                    row = TaskRow(
                        number: preserveNumbers ? Int64(source.id) : nil, boardId: board.id, columnId: source.status, title: source.title,
                        note: source.note, due: source.due, importedId: source.id, createdAt: source.createdAt, updatedAt: source.updatedAt)
                    try row.insert(db)
                    inserted += 1
                }
                let number = Int(row.number!)
                touched.append(number)
                // リンクとセッションは url / session_id で足りないものだけ足す
                let knownLinks = Set(try LinkRow.filter(Column("taskNumber") == number).fetchAll(db).map(\.url))
                for link in source.links where !knownLinks.contains(link.url) {
                    try LinkRow(id: nil, taskNumber: number, url: link.url, kind: link.kind, note: link.note, addedAt: link.addedAt).insert(db)
                }
                let knownSessions = Set(try SessionRow.filter(Column("taskNumber") == number).fetchAll(db).map(\.sessionId))
                for session in source.sessions where !knownSessions.contains(session.sessionID) {
                    try SessionRow(
                        id: nil, taskNumber: number, agent: session.agent, sessionId: session.sessionID, cwd: session.cwd, label: session.label,
                        linkedAt: session.linkedAt
                    ).insert(db)
                }
            }
            let result = TaskherdImportResult(boardID: board.id, inserted: inserted, updated: updated, unchanged: unchanged, keptLocal: keptLocal)
            let tasks = try Self.fetchTasks(db, machine: machineID, numbers: touched)
            let boardValue = try Self.fetchBoards(db, machine: machineID, ids: [board.id]).first!
            return (result, tasks, boardValue)
        }
        changed([.board(imported.2.id)] + imported.1.map { .task($0.number) })
        return imported
    }
}
