// ui-copy:ignore-file
// このファイルの文は MCP の応答・CLI の出力・起動した側の agent への通知に出て、画面には出ない（アプリの画面の文は String Catalog）
import Foundation

extension ConversationRequest {
    /// 計画の承認の本文から載せる字数
    public static let planExcerptLimit = 500

    /// 回答待ちの種類の短い名前
    public var kindLabel: String {
        switch kind {
        case .question: "質問"
        case .permission: "権限の確認 " + (waiting.permission?.tool ?? toolName)
        case .plan: "計画の承認"
        case .elicitation: "MCP の確認（\(elicitation?.serverName ?? toolName)）"
        case .unknown: "知らない種類の回答待ち（\(toolName)）"
        }
    }

    /// 何を待っているか。1 行目は「回答待ち <id>: …」、質問は質問ごとに id・文・選択肢の行が続き、計画の承認は本文の頭が続く
    public var lines: [String] {
        switch kind {
        case .question:
            return ["回答待ち \(id): 質問"]
                + (waiting.questions ?? []).map { question in
                    var line = "  - \(question.id)「\(question.question)」"
                    if !question.options.isEmpty { line += " 選択肢: " + question.options.map(\.label).joined(separator: " / ") }
                    if question.multiSelect { line += "（複数選択）" }
                    return line
                }
        case .permission:
            let permission = waiting.permission
            var line = "回答待ち \(id): \(kindLabel)"
            if let summary = permission?.summary, !summary.isEmpty { line += ": \(summary)" }
            if let detail = permission?.detail, !detail.isEmpty { line += "（\(detail)）" }
            return [line] + PermissionSuggestion.shown(suggestions).map { "  - 今後は聞かない候補 \($0.id): \($0.line)" }
        case .plan:
            let plan = self.plan ?? ""
            let head = ["回答待ち \(id): 計画の承認（本文 \(plan.count) 字）"]
            guard !plan.isEmpty else { return head }
            return head + ["  " + plan.prefix(Self.planExcerptLimit) + (plan.count > Self.planExcerptLimit ? "…" : "")]
        case .elicitation:
            return elicitationLines
        case .unknown:
            return ["回答待ち \(id): この版の taskboard が知らない種類の回答待ち（\(toolName)）。taskboard を新しい版にしてから答える"]
        }
    }
}

extension ConversationRequest {
    /// MCP の確認：1 行目に server の名前と文、form は欄ごとの行、url は開く先の scheme・host・port（URL の全文は出さない）
    private var elicitationLines: [String] {
        guard let elicitation else { return ["回答待ち \(id): \(kindLabel)"] }
        let head = "回答待ち \(id): \(kindLabel)「\(elicitation.message)」"
        let actions = "答え: " + elicitation.allowedActions.map(\.rawValue).joined(separator: " / ")
        switch elicitation.mode {
        case .form where elicitation.form?.unsupported == false:
            return [head, actions] + (elicitation.form?.fields ?? []).map(Self.fieldLine)
        case .url where elicitation.link != nil:
            return [head, "  開く先: \(elicitation.link?.origin ?? "")（アプリで開く）", actions]
        default:
            return [head, "  この形の確認には入力できない。decline か cancel で答える", actions]
        }
    }

    private static func fieldLine(_ field: Elicitation.Field) -> String {
        var line = "  - \(field.key)"
        if let title = field.title, title != field.key { line += "「\(title)」" }
        line += " " + field.kind.rawValue + (field.required ? "（必須）" : "")
        if let format = field.format { line += " format=\(format.rawValue)" }
        if field.minLength != nil || field.maxLength != nil { line += " 長さ \(field.minLength.map(String.init) ?? "")〜\(field.maxLength.map(String.init) ?? "")" }
        if field.minimum != nil || field.maximum != nil {
            line += " 範囲 \(field.minimum.map { $0.formatted() } ?? "")〜\(field.maximum.map { $0.formatted() } ?? "")"
        }
        if let options = field.options { line += " 選択肢: " + options.map(\.value).joined(separator: " / ") }
        return line
    }
}

extension ElicitationAnswerError: CustomStringConvertible {
    /// 断った理由。答えの値は出さない（欄の名前だけ）
    public var description: String {
        switch self {
        case .actionNotAllowed: "この問いには断るか取り消すしかできない"
        case .contentNotAllowed: "受ける答え（accept）でない、か form でない問いに content を付けた"
        case .missing(let key): "必須の欄 \(key) が無い"
        case .unknownField(let key): "問いに無い欄 \(key) がある"
        case .wrongType(let key): "欄 \(key) の型が違う"
        case .outOfRange(let key): "欄 \(key) の長さか範囲が外れている"
        case .badFormat(let key): "欄 \(key) の書式が違う"
        case .notAnOption(let key): "欄 \(key) の値が選択肢に無い"
        }
    }
}

extension Conversation {
    /// 会話の 1 行。id で始まる（委譲のスクリプトが CLI の出力の頭の語を会話の id として読む）。`taskTitle` は紐づいたタスクの題
    public func line(taskTitle: String?) -> String {
        var line = "\(id) \(phase.rawValue)"
        if phase == .stopped, let lastExit { line += "（\(lastExit)）" }
        if let model { line += " model=\(model)" }
        if let effort { line += " effort=\(effort)" }
        if let account { line += " account=\(account)" }
        if let contextPercent { line += " コンテキスト \(contextPercent)%" }
        line += " cwd=\(cwd)"
        if let title, !title.isEmpty { line += " 「\(title)」" }
        if let taskNumber { line += " → #\(taskNumber)" + (taskTitle.map { " \($0)" } ?? "") }
        switch purpose {
        case .orchestrator?: line += " オーケストレーター"
        case .schedule?: line += " 定期起動の実行"
        case .briefing?: line += " 説明役（廃止）"
        case nil: break
        }
        if let parent = parentConversationID.map({ String($0.prefix(8)) }) { line += " 起動元 \(parent)" }
        if parentNoticePending { line += " 未通知" }
        if let limitResumeAt {
            line += limitPaused ? " 利用枠が閾値を越えたため \(Self.localTime(limitResumeAt)) まで待つ" : " 利用枠の上限のため \(Self.localTime(limitResumeAt)) に続きを送る"
        }
        if networkResume == true { line += " ネットワークに繋がらず止まった。接続が戻ったら続きを送る" }
        if !requests.isEmpty { line += " 回答待ち \(requests.count)（session_answer）" }
        if let forkSource { line += " フォーク元 \(forkSource.prefix(8))" + (forkPending ? "（まだ送っていない）" : "") }
        if let diff, diff.isRepo, diff.files > 0 { line += " 差分 \(diff.files) ファイル +\(diff.insertions) -\(diff.deletions)" }
        if rewindIncomplete { line += " 巻き戻しでファイルを戻せたか不明" }
        if !backgroundTasksKnown {
            line += " 裏のタスク 不明"
        } else if backgroundTasks > 0 {
            line += " 裏のタスク \(backgroundTasks)"
        }
        return line
    }

    /// マシンのローカル時刻の ISO 8601（ISO8601DateFormatter は Sendable でないので呼ぶたびに作る）
    private static func localTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

extension PermissionSuggestion {
    /// MCP の応答に出す 1 行。何を許可し、どこに残すか
    public var line: String {
        let target: String
        switch kind {
        case .rule, .unknown: target = "規則 \(subject) を許可"
        case .directory: target = "作業フォルダ \(subject) へのアクセスを許可"
        case .mode: target = "権限のモードを \(subject) に変更"
        }
        return target + "（\(scope.phrase)）"
    }
}
