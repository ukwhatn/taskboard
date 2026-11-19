import Foundation

/// 答えを待っている AskUserQuestion か権限の確認。`id` は Claude Code の tool_use_id で、答えるときに同じものかを比べる
public struct RequestWaiting: Codable, Hashable, Sendable {
    public struct Permission: Codable, Hashable, Sendable {
        /// ツールの名前（Bash・Edit・mcp__…）
        public var tool: String
        /// コマンドかファイルのパス。無ければ引数の JSON の頭
        public var summary: String
        /// Claude Code がコマンドに付けた説明
        public var detail: String?

        public init(tool: String, summary: String, detail: String? = nil) {
            self.tool = tool
            self.summary = summary
            self.detail = detail
        }
    }

    public var id: String
    public var since: Date
    public var questions: [AskQuestion]?
    public var permission: Permission?

    public init(id: String, since: Date, questions: [AskQuestion]? = nil, permission: Permission? = nil) {
        self.id = id
        self.since = since
        self.questions = questions
        self.permission = permission
    }

    /// 通知の本文と［許可］［拒否］に載せる確認。`hash` は tool_use_id（答えるときに同じ確認かを比べる）
    public var permissionPrompt: PermissionPrompt? {
        permission.map { PermissionPrompt(tool: $0.tool, summary: String($0.summary.prefix(PermissionPrompt.summaryLimit)), hash: id) }
    }

    /// 文書の質問の欄の答えを、AskUserQuestion の答え（問いの文 → 答え）にする。
    /// 複数選んだ答えは「, 」でつなぎ（Claude Code の端末の答えと同じ）、自由記述は選んだ答えの後ろに足す
    public func answerMap(_ answers: [AskAnswer]) -> [String: String] {
        var map: [String: String] = [:]
        for question in questions ?? [] {
            guard let answer = answers.first(where: { $0.questionID == question.id }), answer.isAnswered else { continue }
            let free = answer.freeText?.trimmingCharacters(in: .whitespacesAndNewlines)
            map[question.question] = (answer.selected + [free].compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: ", ")
        }
        return map
    }
}
