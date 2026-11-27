// ui-copy:ignore-file
// このファイルの文は、起動したエージェント（Claude Code・Codex）が読む指示で、画面には出ない（docs/ui-copy.md の対象外）。
// 起動プロンプトの既定は案件の設定に入り、人が設定の画面で書き換えるが、送る先はエージェント
import Foundation

extension PromptTemplate {
    /// 新しく作る案件の既定（タスクの中身だけ。taskboard の使い方は SessionStart hook が差し込む）
    public static let defaultBoardTemplate = Copy.template("board-start")

    /// レビュー依頼の列の既定
    public static let defaultReviewRequestTemplate = Copy.template("review-request-start")

    /// 列 id → 既定のテンプレート（新しい案件に入れる）
    public static let defaultColumnTemplates: [String: String] = ["review_req": defaultReviewRequestTemplate]
}

extension OrchestratorInfo {
    /// オーケストレーターの起動プロンプト。常駐（`OrchestratorKeeper`）と手動の起動（`POST /v1/orchestrator/start` の prompt が空のとき）が送る。
    /// オーケストレーターはタスクに結ばないので SessionStart の案内が届かず、役割はここでしか伝わらない
    public static let startPrompt = Copy.prompt("orchestrator-start")
}

// MARK: - 列の説明

/// 既定の列の説明（案件ごとに直せる）。人と紐づいたセッションが読む文で、daemon の動きは列の id で決める
public enum ColumnGuide {
    public static let defaultDescriptions: [String: String] = [
        "standing": Copy.text("agent.column.standing"),
        "review_req": Copy.text("agent.column.review_req"),
        "todo": Copy.text("agent.column.todo"),
        "planning": Copy.text("agent.column.planning"),
        "working": Copy.text("agent.column.working"),
        "review": Copy.text("agent.column.review"),
        "deploying": Copy.text("agent.column.deploying"),
        "done": Copy.text("agent.column.done"),
        "wontfix": Copy.text("agent.column.wontfix"),
    ]
}

// MARK: - 起動したセッションへの案内

/// タスクに紐づいたセッションへ SessionStart hook が差し込む文（`additionalContext`）と題（`sessionTitle`）。
/// 読むのはエージェントなので、画面の文言の規則の対象外
public enum SessionGuidance {
    /// 今の列と、案件の全部の列の id・名前・説明つきの案内。`machineName` は daemon が動く Mac の呼び名（hook は同じ Mac で動くので「この Mac」）。
    /// SessionStart hook と MCP の `session_guide` が同じ文を返す
    public static func text(task: BoardTask, board: Board?, machineName: String) -> String {
        var lines = [Copy.text("agent.guidance.linked", ["number": "\(task.number)", "title": task.title]), Copy.text("agent.guidance.machine", ["machine": machineName])]
        if let board { lines.append(Copy.text("agent.guidance.board", ["board": board.name])) }
        if let current = board?.orderedColumns.first(where: { $0.id == task.columnID }) {
            lines.append(Copy.text("agent.guidance.column", ["column": columnName(current)]))
        }
        lines.append(Copy.text("agent.guidance.update"))
        lines.append(Copy.text("agent.guidance.ask"))
        if task.title == untitledTaskTitle {
            lines.append(Copy.text("agent.guidance.untitled"))
        }
        if let board {
            lines.append(Copy.text("agent.guidance.columns"))
            lines += board.orderedColumns.map { "  - " + columnLine($0) }
        }
        return lines.joined(separator: "\n")
    }

    /// `id（名前）`
    public static func columnName(_ column: BoardColumn) -> String { "\(column.id)（\(column.label)）" }

    /// `id（名前）: 説明`。説明が空なら名前まで
    public static func columnLine(_ column: BoardColumn) -> String {
        let summary = column.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? columnName(column) : columnName(column) + ": " + summary
    }

    /// 会話の題。Claude Code の再開の一覧とアプリの両方で、どのタスクの会話かが分かる
    public static func title(task: BoardTask) -> String { "#\(task.number) \(task.title)" }

    /// 題を空のまま起票したタスクに daemon が付ける題。起動したセッションには、題を付けるよう案内する
    public static let untitledTaskTitle = "無題"

    /// 会話の題を付け直すときの新しい題。題が無いか、hook が付けた形（`#番号 `）のままタスクの題と違うときだけ返す。
    /// `#番号 ` で始まらない題は人が /rename で付けたものとして上書きしない
    public static func retitle(current: String?, task: BoardTask) -> String? {
        let wanted = title(task: task)
        let current = current?.trimmingCharacters(in: .whitespaces) ?? ""
        guard current.isEmpty || (current.hasPrefix("#\(task.number) ") && current != wanted) else { return nil }
        return wanted
    }

    /// MCP server の `instructions`（タスクに紐づかないセッションにも届く、taskboard の使い方の全体）
    public static let mcpInstructions = Copy.prompt("mcp-instructions")
}

