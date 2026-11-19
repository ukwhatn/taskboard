import Foundation
import GRDB
import TaskboardKit

/// 案件の設定（名前・アーカイブ・起動の既定・列の置き換え）と削除。
extension Store {
    static func registerBoardSettingsMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v7 board settings") { db in
            try db.alter(table: "board") { t in
                t.add(column: "archivedAt", .datetime)
                t.add(column: "launchDefaults", .text)
            }
            try db.alter(table: "boardColumn") { t in
                t.add(column: "collapsed", .boolean).notNull().defaults(to: false)
            }
            // それまでのボードは終端の列を畳んで出していた
            try db.execute(sql: "UPDATE boardColumn SET collapsed = 1 WHERE kind = 'terminal'")
        }
    }

    static func registerBoardMergeTargetMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12 board merge target") { db in
            try db.alter(table: "board") { t in
                t.add(column: "mergeTarget", .text).notNull().defaults(to: MergeTarget.deploying.rawValue)
            }
        }
    }

    static func registerColumnGuideMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v14 column description and standing") { db in
            try db.alter(table: "boardColumn") { t in
                t.add(column: "description", .text).notNull().defaults(to: "")
            }
            try addStandingColumns(db)
        }
    }

    /// 今ある案件の先頭に「常設」を足し（ほかの列は 1 つずつ後ろへ）、説明が空の既定の列に既定の説明を入れる。
    /// 常設が既にある案件には足さない（2 回呼んでも重ならない）
    static func addStandingColumns(_ db: Database) throws {
        let standing = BoardColumn.standard.first { $0.id == BoardColumn.standingID }!
        let boards = try String.fetchAll(
            db, sql: "SELECT id FROM board WHERE id NOT IN (SELECT boardId FROM boardColumn WHERE id = ?)", arguments: [standing.id])
        for board in boards {
            try db.execute(sql: "UPDATE boardColumn SET position = position + 1 WHERE boardId = ?", arguments: [board])
            try ColumnRow(
                boardId: board, id: standing.id, label: standing.label, kind: standing.kind.rawValue, position: 0, collapsed: standing.collapsed,
                description: standing.description
            ).insert(db)
        }
        for column in BoardColumn.standard {
            try db.execute(
                sql: "UPDATE boardColumn SET description = ? WHERE id = ? AND description = ''", arguments: [column.description, column.id])
        }
    }

    /// 案件の変更の結果。列を消してタスクを移したら `movedTasks` に入る
    public struct BoardEdit: Sendable {
        public var board: Board
        public var movedTasks: [BoardTask]
    }

    /// hook・`POST /v1/tasks` の既定の起票先（`Sequence<Board>.defaultBoard`）
    public func defaultBoard() throws -> Board? {
        try boards().defaultBoard
    }

    public func editBoard(id: String, _ request: BoardUpdateRequest) throws -> BoardEdit {
        let edit = try database.write { db in
            guard var row = try BoardRow.fetchOne(db, key: id) else { throw StoreError.boardNotFound(id) }
            if let name = request.name { row.name = try Self.validBoardName(db, name, excluding: id) }
            if let template = request.promptTemplate { row.promptTemplate = template }
            if let target = request.mergeTarget { row.mergeTarget = target.rawValue }
            if let delegation = request.delegation { row.delegation = try Self.encodeDelegation(delegation) }
            if let archived = request.archived {
                if archived, row.archivedAt == nil {
                    guard try Self.activeBoardCount(db, excluding: id) > 0 else {
                        throw StoreError.refused(.boardLast, [:], "最後の案件はアーカイブできない: 先にほかの案件を作る")
                    }
                    row.archivedAt = Date()
                } else if !archived {
                    row.archivedAt = nil
                }
            }
            if request.clearLaunchDefaults == true {
                guard request.launchDefaults == nil else { throw StoreError.invalid("launchDefaults と clearLaunchDefaults は同時に送らない") }
                row.launchDefaults = nil
            } else if let defaults = request.launchDefaults {
                row.launchDefaults = String(decoding: try JSONEncoder().encode(defaults), as: UTF8.self)
            }
            try row.update(db)
            var moved: [Int] = []
            if let columns = request.columns {
                moved = try Self.replaceColumns(db, board: id, columns, reassign: request.reassign ?? [:])
            }
            if let templates = request.columnTemplates {
                for (columnID, template) in templates {
                    try db.execute(
                        sql: "UPDATE boardColumn SET promptTemplate = ? WHERE boardId = ? AND id = ?",
                        arguments: [template.isEmpty ? nil : template, id, columnID])
                }
            }
            return BoardEdit(
                board: try Self.fetchBoards(db, machine: machineID, ids: [id]).first!,
                movedTasks: moved.isEmpty ? [] : try Self.fetchTasks(db, machine: machineID, numbers: moved))
        }
        // 消えた列を指すタスクを state に残さないよう、移したタスクも流す
        changed([.board(id)] + edit.movedTasks.map { .task($0.number) })
        return edit
    }

    /// タスクが 0 件で、ほかにアーカイブしていない案件が残るときだけ消せる
    public func deleteBoard(id: String) throws {
        try database.write { db in
            guard let row = try BoardRow.fetchOne(db, key: id) else { throw StoreError.boardNotFound(id) }
            let tasks = try TaskRow.filter(Column("boardId") == id).fetchCount(db)
            guard tasks == 0 else { throw StoreError.refused(.boardHasTasks, ["name": row.name, "count": String(tasks)], "案件「\(row.name)」にタスクが \(tasks) 件ある: ほかの案件へ移してから削除する") }
            guard try Self.activeBoardCount(db, excluding: id) > 0 else {
                throw StoreError.refused(.boardLast, [:], "最後の案件は削除できない: 先にほかの案件を作る")
            }
            try row.delete(db)
        }
        changed(.board(id))
    }

    static func validBoardName(_ db: Database, _ name: String, excluding id: String?) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.refused(.boardNameEmpty, [:], "案件の名前が空") }
        var others = BoardRow.filter(Column("name") == trimmed)
        if let id { others = others.filter(Column("id") != id) }
        guard try others.fetchCount(db) == 0 else { throw StoreError.refused(.boardNameTaken, ["name": trimmed], "案件「\(trimmed)」は既にある") }
        return trimmed
    }

    private static func activeBoardCount(_ db: Database, excluding id: String) throws -> Int {
        try BoardRow.filter(Column("id") != id && Column("archivedAt") == nil).fetchCount(db)
    }

    /// 列の全体を `edits` の順に置き換え、消える列のタスクを `reassign` の先へ移す。移したタスクの番号を返す
    private static func replaceColumns(_ db: Database, board id: String, _ edits: [BoardColumnEdit], reassign: [String: String]) throws -> [Int] {
        let current = try ColumnRow.filter(Column("boardId") == id).fetchAll(db)
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })

        var rows: [ColumnRow] = []
        var labels = Set<String>()
        for (index, edit) in edits.enumerated() {
            let label = edit.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw StoreError.refused(.columnLabelEmpty, [:], "列の名前が空") }
            guard labels.insert(label).inserted else { throw StoreError.refused(.columnLabelDuplicate, ["label": label], "列「\(label)」が重複している") }
            var row: ColumnRow
            if let columnID = edit.id {
                guard !rows.contains(where: { $0.id == columnID }) else { throw StoreError.invalid("列 \(columnID) が重複している") }
                if let existing = currentByID[columnID] {
                    if BoardColumn.standardIDs.contains(columnID), existing.kind != edit.kind.rawValue {
                        throw StoreError.refused(
                            .defaultColumnLocked, ["label": existing.label, "change": "kind"], "既定の列「\(existing.label)」の完了扱いは変えられない")
                    }
                    row = existing
                } else if let standard = BoardColumn.standard.first(where: { $0.id == columnID }) {
                    // 消した既定の列を戻す。daemon の動きも id ごと戻る
                    guard standard.kind.rawValue == edit.kind.rawValue else {
                        throw StoreError.refused(
                            .defaultColumnLocked, ["label": standard.label, "change": "kind"], "既定の列「\(standard.label)」の完了扱いは変えられない")
                    }
                    row = ColumnRow(
                        boardId: id, id: columnID, label: label, kind: standard.kind.rawValue, position: index,
                        promptTemplate: PromptTemplate.defaultColumnTemplates[columnID], description: standard.description)
                } else {
                    throw StoreError.invalid("列 \(columnID) はこの案件に無い")
                }
            } else {
                row = ColumnRow(boardId: id, id: "c-" + UUID().uuidString.lowercased().prefix(8), label: label, kind: edit.kind.rawValue, position: index)
            }
            row.label = label
            row.kind = edit.kind.rawValue
            row.position = index
            row.collapsed = edit.collapsed
            if let template = edit.promptTemplate { row.promptTemplate = template.isEmpty ? nil : template }
            if let description = edit.description { row.description = description.trimmingCharacters(in: .whitespacesAndNewlines) }
            rows.append(row)
        }
        let kept = Set(rows.map(\.id))
        if let missing = current.first(where: { $0.id == BoardColumn.doneID && !kept.contains($0.id) }) {
            throw StoreError.refused(
                .defaultColumnLocked, ["label": missing.label, "change": "remove"], "列「\(missing.label)」は消せない: マージとレビュー依頼の終わりで進める先")
        }
        guard rows.contains(where: { $0.kind == BoardColumn.Kind.open.rawValue }) else {
            throw StoreError.refused(.noOpenColumn, [:], "進行中の列が 1 つも無い: タスクを作る先が無くなる")
        }

        var moves: [(from: String, to: String)] = []
        for removed in current where !kept.contains(removed.id) {
            let count = try TaskRow.filter(Column("boardId") == id && Column("columnId") == removed.id).fetchCount(db)
            guard count > 0 else { continue }
            guard let target = reassign[removed.id] else {
                throw StoreError.refused(.columnHasTasks, ["label": removed.label, "count": String(count)], "列「\(removed.label)」にタスクが \(count) 件ある: 移す先の列を選ぶ")
            }
            guard kept.contains(target) else { throw StoreError.invalid("移す先の列 \(target) が新しい列に無い") }
            moves.append((removed.id, target))
        }

        var moved: [Int] = []
        for move in moves {
            moved += try Int.fetchAll(
                db, sql: "SELECT number FROM task WHERE boardId = ? AND columnId = ?", arguments: [id, move.from])
            try db.execute(
                sql: "UPDATE task SET columnId = ?, updatedAt = ? WHERE boardId = ? AND columnId = ?", arguments: [move.to, Date(), id, move.from])
        }
        try ColumnRow.filter(Column("boardId") == id).deleteAll(db)
        for row in rows { try row.insert(db) }
        return moved
    }
}
