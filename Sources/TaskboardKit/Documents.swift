import Foundation

// MARK: - 文書

public enum DocFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case markdown
    case html

    /// ファイル名から決める。決まらなければ nil（呼び出し側が明示する）。
    public static func infer(fromName name: String) -> DocFormat? {
        let lower = name.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return .markdown }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return .html }
        return nil
    }
}

/// 文書をマシンを跨いで一意に指すキー。
public struct DocKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }

    public var description: String { "\(machine.rawValue)/doc/\(id)" }
}

/// セッションが publish した文書。タスクに属し、`(taskNumber, name)` で一意。本文はリビジョンごとに別に取る。
public struct Document: Codable, Hashable, Identifiable, Sendable {
    public var id: DocKey { DocKey(machine: machine, id: docID) }

    public var machine: MachineID
    public var docID: Int64
    public var taskNumber: Int
    /// セッションが付けた名前（`report.md` など）。同じ名前への publish は新しいリビジョンになる
    public var name: String
    public var format: DocFormat
    public var title: String?
    public var latestRev: Int
    /// publish 元のローカルファイルが分かっている（パス自体は配らない）
    public var hasSourceFile: Bool
    /// 送信済みで未解決のコメント数
    public var openComments: Int
    /// 下書きのコメント数（まだセッションに届いていない）
    public var draftComments: Int
    /// 本文に置いた送る文面（`doc_publish` の `drafts`）。承認を待つものと承認済みのもの
    public var drafts: [DocDraft]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        machine: MachineID, docID: Int64, taskNumber: Int, name: String, format: DocFormat, title: String? = nil, latestRev: Int,
        hasSourceFile: Bool = false, openComments: Int = 0, draftComments: Int = 0, drafts: [DocDraft] = [], createdAt: Date, updatedAt: Date
    ) {
        self.machine = machine
        self.docID = docID
        self.taskNumber = taskNumber
        self.name = name
        self.format = format
        self.title = title
        self.latestRev = latestRev
        self.hasSourceFile = hasSourceFile
        self.openComments = openComments
        self.draftComments = draftComments
        self.drafts = drafts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case machine, docID, taskNumber, name, format, title, latestRev, hasSourceFile, openComments, draftComments, drafts, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineID.self, forKey: .machine)
        docID = try c.decode(Int64.self, forKey: .docID)
        taskNumber = try c.decode(Int.self, forKey: .taskNumber)
        name = try c.decode(String.self, forKey: .name)
        format = try c.decode(DocFormat.self, forKey: .format)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        latestRev = try c.decode(Int.self, forKey: .latestRev)
        hasSourceFile = try c.decode(Bool.self, forKey: .hasSourceFile)
        openComments = try c.decode(Int.self, forKey: .openComments)
        draftComments = try c.decode(Int.self, forKey: .draftComments)
        drafts = try c.decodeIfPresent([DocDraft].self, forKey: .drafts) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    /// `drafts` は 1 件以上のときだけ書く（送る文面の無い文書の state の形を変えない）
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machine, forKey: .machine)
        try c.encode(docID, forKey: .docID)
        try c.encode(taskNumber, forKey: .taskNumber)
        try c.encode(name, forKey: .name)
        try c.encode(format, forKey: .format)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(latestRev, forKey: .latestRev)
        try c.encode(hasSourceFile, forKey: .hasSourceFile)
        try c.encode(openComments, forKey: .openComments)
        try c.encode(draftComments, forKey: .draftComments)
        if !drafts.isEmpty { try c.encode(drafts, forKey: .drafts) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// 承認を待つ送る文面
    public var openDrafts: [DocDraft] { drafts.filter { $0.answer == nil } }

    /// 一覧に出す名前。title があればそれ、無ければファイル名
    public var displayTitle: String { title?.isEmpty == false ? title! : name }
}

public struct DocRevision: Codable, Hashable, Sendable {
    public var rev: Int
    public var createdAt: Date

    public init(rev: Int, createdAt: Date) {
        self.rev = rev
        self.createdAt = createdAt
    }
}

/// `GET /v1/docs/{id}/content?rev=`。
public struct DocContent: Codable, Hashable, Sendable {
    public var docID: Int64
    public var rev: Int
    public var format: DocFormat
    public var content: String
    /// 本文が読み込む外部の資源のホスト（`DocExternalHosts`。publish のときに集めた値）
    public var externalHosts: [String]
    /// 本文の印 `<!-- change: id -->` の位置に描く修正前と修正後（その版と一緒に publish した値）
    public var changes: [DocChange]

    public init(docID: Int64, rev: Int, format: DocFormat, content: String, externalHosts: [String] = [], changes: [DocChange] = []) {
        self.docID = docID
        self.rev = rev
        self.format = format
        self.content = content
        self.externalHosts = externalHosts
        self.changes = changes
    }

    private enum CodingKeys: String, CodingKey { case docID, rev, format, content, externalHosts, changes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docID = try c.decode(Int64.self, forKey: .docID)
        rev = try c.decode(Int.self, forKey: .rev)
        format = try c.decode(DocFormat.self, forKey: .format)
        content = try c.decode(String.self, forKey: .content)
        externalHosts = try c.decodeIfPresent([String].self, forKey: .externalHosts) ?? []
        changes = try c.decodeIfPresent([DocChange].self, forKey: .changes) ?? []
    }

    /// `externalHosts` と `changes` は 1 件以上のときだけ書く（無い文書の応答の形を変えない）
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(docID, forKey: .docID)
        try c.encode(rev, forKey: .rev)
        try c.encode(format, forKey: .format)
        try c.encode(content, forKey: .content)
        if !externalHosts.isEmpty { try c.encode(externalHosts, forKey: .externalHosts) }
        if !changes.isEmpty { try c.encode(changes, forKey: .changes) }
    }
}

/// `GET /v1/docs/{id}/source`。publish 元のファイルのパス（daemon の token にだけ返す。パスは文書のマシンの中でだけ意味がある）
public struct DocSourceFile: Codable, Hashable, Sendable {
    public var path: String?

    public init(path: String?) {
        self.path = path
    }
}

// MARK: - 修正の対比

/// `doc_publish` の `changes` の 1 件。本文の印 `<!-- change: id -->` の位置に、修正前と修正後を並べて描く（答えは返さない）
public struct DocChange: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// 項目の題（「3 節の結び」）
    public var title: String?
    /// その箇所が何の話か（節の話題・前後の段落の要約）。読み手が元の文書を開き直さずに判断できるように添える
    public var context: String?
    public var before: String
    public var after: String

    public init(id: String, title: String? = nil, context: String? = nil, before: String, after: String) {
        self.id = id
        self.title = title
        self.context = context
        self.before = before
        self.after = after
    }

    public static let maxCount = 20
    public static let titleChars = 60
    public static let contextChars = 600
    public static let textChars = 4_000

    public static func validate(_ changes: [DocChange]) -> String? {
        if changes.count > maxCount { return Copy.text("agent.doc.changes.count", ["limit": "\(maxCount)"]) }
        var seen = Set<String>()
        for change in changes {
            guard PanelValidation.isValidID(change.id) else { return Copy.text("agent.panel.invalid.id", ["id": change.id, "limit": "\(PanelBudget.idChars)"]) }
            guard seen.insert(change.id).inserted else { return Copy.text("agent.panel.invalid.duplicate", ["id": change.id]) }
            if (change.title?.count ?? 0) > titleChars || (change.context?.count ?? 0) > contextChars
                || change.before.count > textChars || change.after.count > textChars
            {
                return Copy.text(
                    "agent.doc.changes.length", ["id": change.id, "title": "\(titleChars)", "context": "\(contextChars)", "text": "\(textChars)"])
            }
        }
        return nil
    }
}

// MARK: - 送る文面

/// `doc_publish` の `drafts` の 1 件。id は本文の印 `<!-- draft: id -->` が指す。欄は概況の送る文面（`PanelDraft`）と同じ
public struct DocDraftSpec: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var draft: PanelDraft

    public init(id: String, draft: PanelDraft) {
        self.id = id
        self.draft = draft
    }

    private enum CodingKeys: String, CodingKey { case id }

    /// JSON は id と `PanelDraft` の欄を同じ階層に並べる（概況の部品と同じ）
    public init(from decoder: any Decoder) throws {
        id = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .id)
        draft = try PanelDraft(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try draft.encode(to: encoder)
    }

    /// 数・id・欄の予算。守られていなければ会話へ返す理由
    public static func validate(_ drafts: [DocDraftSpec]) -> String? {
        if drafts.count > maxCount { return Copy.text("agent.doc.drafts.count", ["limit": "\(maxCount)"]) }
        var seen = Set<String>()
        for spec in drafts {
            guard PanelValidation.isValidID(spec.id) else { return Copy.text("agent.panel.invalid.id", ["id": spec.id, "limit": "\(PanelBudget.idChars)"]) }
            guard seen.insert(spec.id).inserted else { return Copy.text("agent.panel.invalid.duplicate", ["id": spec.id]) }
            do {
                try PanelValidation.check(spec.draft, id: spec.id)
            } catch let invalid as PanelInvalid {
                return invalid.message
            } catch {
                return "\(error)"
            }
        }
        return nil
    }

    public static let maxCount = 8
}

/// 文書に置いた送る文面と、人の承認。会話が本文を書き換えると承認は外れる
public struct DocDraft: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var draft: PanelDraft
    public var answer: PanelDraftAnswer?
    public var updatedAt: Date

    public init(id: String, draft: PanelDraft, answer: PanelDraftAnswer? = nil, updatedAt: Date) {
        self.id = id
        self.draft = draft
        self.answer = answer
        self.updatedAt = updatedAt
    }
}

// MARK: - 質問

public struct AskOption: Codable, Hashable, Sendable {
    public static let previewLimit = 20_000

    /// 答えとして送る文。推奨の印（「(Recommended)」など）が付いていても、送るときは外さない
    public var label: String
    public var description: String?
    /// 選んでいる間に出す見本。markdown で、先頭が `<` なら HTML（`previewIsHTML`）
    public var preview: String?
    public var recommended: Bool

    private enum CodingKeys: String, CodingKey { case label, description, preview, recommended }

    public init(label: String, description: String? = nil, preview: String? = nil, recommended: Bool = false) {
        self.label = label
        self.description = description
        self.preview = preview.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.recommended = recommended
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try c.decode(String.self, forKey: .label), description: try c.decodeIfPresent(String.self, forKey: .description),
            preview: try c.decodeIfPresent(String.self, forKey: .preview), recommended: try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false)
    }

    /// `preview` と `recommended` は値があるときだけ書く（見本の無い質問の文書・state の形を変えない）
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(preview, forKey: .preview)
        if recommended { try c.encode(recommended, forKey: .recommended) }
    }

    /// Claude の AskUserQuestion は推奨を label の末尾の印で示す
    private static let recommendedMarks = ["(recommended)", "（recommended）", "(推奨)", "（推奨）"]  // ui-copy:ignore（Claude が label に付ける印との照合。画面には出ない）

    /// 末尾の推奨の印を外した label。印が無ければ nil
    private var unmarkedLabel: String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let mark = Self.recommendedMarks.first(where: { trimmed.lowercased().hasSuffix($0) }) else { return nil }
        return String(trimmed.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
    }

    public var isRecommended: Bool { recommended || unmarkedLabel != nil }

    /// 画面に出す名前（推奨の印を外す。印だけの label はそのまま）
    public var displayLabel: String {
        guard let head = unmarkedLabel, !head.isEmpty else { return label }
        return head
    }

    public var previewIsHTML: Bool { preview?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true }
}

public struct AskQuestion: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var question: String
    public var header: String?
    public var options: [AskOption]
    public var multiSelect: Bool
    /// 答えを伏せて入力する（codex の `isSecret`）。daemon は答えをログ・state・記録に残さない
    public var isSecret: Bool

    private enum CodingKeys: String, CodingKey { case id, question, header, options, multiSelect, isSecret }

    public init(id: String, question: String, header: String? = nil, options: [AskOption], multiSelect: Bool = false, isSecret: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.isSecret = isSecret
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        options = try c.decode([AskOption].self, forKey: .options)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    /// `isSecret` は true のときだけ書く（受信箱の質問の文書・state の形を変えない）
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(question, forKey: .question)
        try c.encodeIfPresent(header, forKey: .header)
        try c.encode(options, forKey: .options)
        try c.encode(multiSelect, forKey: .multiSelect)
        if isSecret { try c.encode(isSecret, forKey: .isSecret) }
    }

    /// 入力の制約（kairan と同じ値）。守られていなければ理由を返す
    public static func validate(_ questions: [AskQuestion]) -> String? {
        if questions.count > 8 { return "質問は 8 問まで" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
        var seen: Set<String> = []
        for q in questions {
            if q.id.isEmpty || q.id.count > 64 { return "質問 id は 1〜64 文字" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            if !seen.insert(q.id).inserted { return "質問 id が重複している: \(q.id)" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            if q.question.isEmpty || q.question.count > 4000 { return "質問文は 1〜4000 文字" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            if let header = q.header, header.count > 32 { return "header は 32 文字まで" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            if q.options.isEmpty || q.options.count > 8 { return "選択肢は 1〜8 個" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            for option in q.options {
                if option.label.isEmpty || option.label.count > 300 { return "選択肢の label は 1〜300 文字" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
                if let d = option.description, d.count > 2000 { return "選択肢の description は 2000 文字まで" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
                if let p = option.preview, p.count > AskOption.previewLimit { return "選択肢の preview は \(AskOption.previewLimit) 文字まで" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
            }
        }
        return nil
    }
}

public struct AskAnswer: Codable, Hashable, Sendable {
    public var questionID: String
    public var selected: [String]
    public var freeText: String?

    public init(questionID: String, selected: [String], freeText: String? = nil) {
        self.questionID = questionID
        self.selected = selected
        self.freeText = freeText
    }

    /// 回答したと言える（選択が 1 つ以上か、自由記述が空でない）
    public var isAnswered: Bool { !selected.isEmpty || !(freeText ?? "").isEmpty }
}

public struct AskKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let machine: MachineID
    public let id: Int64

    public init(machine: MachineID, id: Int64) {
        self.machine = machine
        self.id = id
    }

    public var description: String { "\(machine.rawValue)/ask/\(id)" }
}

/// 文書に付いた質問の束。1 文書に open は 1 つ。回答で answered になり、Stop hook が届けると delivered が付く。
public struct Ask: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case open, answered, cancelled
    }

    public var id: AskKey { AskKey(machine: machine, id: askID) }

    public var machine: MachineID
    public var askID: Int64
    public var taskNumber: Int
    public var docID: Int64
    public var status: Status
    public var questions: [AskQuestion]
    public var answers: [AskAnswer]?
    public var createdAt: Date
    public var answeredAt: Date?
    public var deliveredAt: Date?
    /// `doc_publish` の `questions` で本文と一緒に出した束。本文の印 `<!-- ask: q1 -->` はこの束の質問を指す。
    /// `ask_user` で既存の文書に付けた束は false で、本文の末尾に出る
    public var inBody: Bool

    public init(
        machine: MachineID, askID: Int64, taskNumber: Int, docID: Int64, status: Status, questions: [AskQuestion], answers: [AskAnswer]? = nil,
        createdAt: Date, answeredAt: Date? = nil, deliveredAt: Date? = nil, inBody: Bool = false
    ) {
        self.machine = machine
        self.askID = askID
        self.taskNumber = taskNumber
        self.docID = docID
        self.status = status
        self.questions = questions
        self.answers = answers
        self.createdAt = createdAt
        self.answeredAt = answeredAt
        self.deliveredAt = deliveredAt
        self.inBody = inBody
    }

    private enum CodingKeys: String, CodingKey {
        case machine, askID, taskNumber, docID, status, questions, answers, createdAt, answeredAt, deliveredAt, inBody
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        machine = try c.decode(MachineID.self, forKey: .machine)
        askID = try c.decode(Int64.self, forKey: .askID)
        taskNumber = try c.decode(Int.self, forKey: .taskNumber)
        docID = try c.decode(Int64.self, forKey: .docID)
        status = try c.decode(Status.self, forKey: .status)
        questions = try c.decode([AskQuestion].self, forKey: .questions)
        answers = try c.decodeIfPresent([AskAnswer].self, forKey: .answers)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        answeredAt = try c.decodeIfPresent(Date.self, forKey: .answeredAt)
        deliveredAt = try c.decodeIfPresent(Date.self, forKey: .deliveredAt)
        inBody = try c.decodeIfPresent(Bool.self, forKey: .inBody) ?? false
    }

    /// `inBody` は true のときだけ書く（前の版の state の形を変えない）
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machine, forKey: .machine)
        try c.encode(askID, forKey: .askID)
        try c.encode(taskNumber, forKey: .taskNumber)
        try c.encode(docID, forKey: .docID)
        try c.encode(status, forKey: .status)
        try c.encode(questions, forKey: .questions)
        try c.encodeIfPresent(answers, forKey: .answers)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(answeredAt, forKey: .answeredAt)
        try c.encodeIfPresent(deliveredAt, forKey: .deliveredAt)
        if inBody { try c.encode(inBody, forKey: .inBody) }
    }

    /// 全問に回答があるか。無い質問の id を返す
    public func unanswered(in answers: [AskAnswer]) -> [String] {
        questions.compactMap { q in
            answers.first { $0.questionID == q.id }?.isAnswered == true ? nil : q.id
        }
    }
}

// MARK: - レビューとコメント

/// 選択範囲の引用。無ければ文書全体へのコメント。
public struct CommentAnchor: Codable, Hashable, Sendable {
    public var exact: String
    public var prefix: String
    public var suffix: String

    public init(exact: String, prefix: String = "", suffix: String = "") {
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct CommentReply: Codable, Hashable, Identifiable, Sendable {
    public enum Author: String, Codable, Hashable, Sendable {
        case agent, human
    }

    public enum State: String, Codable, Hashable, Sendable {
        case draft, submitted
    }

    public var id: Int64
    public var commentID: Int64
    public var author: Author
    public var body: String
    public var state: State
    public var createdAt: Date

    public init(id: Int64, commentID: Int64, author: Author, body: String, state: State, createdAt: Date) {
        self.id = id
        self.commentID = commentID
        self.author = author
        self.body = body
        self.state = state
        self.createdAt = createdAt
    }
}

/// 文書へのコメント。人が書く。draft のまま貯め、レビューの送信で open になってセッションへ届く。
public struct DocComment: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case draft, open, resolved
    }

    public var id: Int64
    public var docID: Int64
    public var docName: String
    public var rev: Int
    public var anchor: CommentAnchor?
    public var body: String
    public var state: State
    public var reviewID: Int64?
    public var createdAt: Date
    public var submittedAt: Date?
    public var resolvedAt: Date?
    public var replies: [CommentReply]

    public init(
        id: Int64, docID: Int64, docName: String, rev: Int, anchor: CommentAnchor? = nil, body: String, state: State, reviewID: Int64? = nil,
        createdAt: Date, submittedAt: Date? = nil, resolvedAt: Date? = nil, replies: [CommentReply] = []
    ) {
        self.id = id
        self.docID = docID
        self.docName = docName
        self.rev = rev
        self.anchor = anchor
        self.body = body
        self.state = state
        self.reviewID = reviewID
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.resolvedAt = resolvedAt
        self.replies = replies
    }
}

/// 1 回のレビュー送信。タスクに 1 つの draft があり、送信で submitted になる。
public struct Review: Codable, Hashable, Identifiable, Sendable {
    public enum State: String, Codable, Hashable, Sendable {
        case draft, submitted
    }

    public var id: Int64
    public var taskNumber: Int
    public var summary: String
    public var state: State
    public var createdAt: Date
    public var submittedAt: Date?
    public var deliveredAt: Date?

    public init(id: Int64, taskNumber: Int, summary: String, state: State, createdAt: Date, submittedAt: Date? = nil, deliveredAt: Date? = nil) {
        self.id = id
        self.taskNumber = taskNumber
        self.summary = summary
        self.state = state
        self.createdAt = createdAt
        self.submittedAt = submittedAt
        self.deliveredAt = deliveredAt
    }
}

/// `GET /v1/tasks/{n}/review`: 送る前のレビュー（総括の下書きと、タスクの文書に付いた draft コメント）。
public struct ReviewDraft: Codable, Hashable, Sendable {
    public var review: Review?
    public var comments: [DocComment]

    public init(review: Review?, comments: [DocComment]) {
        self.review = review
        self.comments = comments
    }
}

/// セッションが「読んでほしい」と立てた依頼。レビューの送信で消える。
public struct ReviewRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: TaskKey { TaskKey(machine: machine, number: taskNumber) }

    public var machine: MachineID
    public var taskNumber: Int
    public var note: String
    public var requestedAt: Date

    public init(machine: MachineID, taskNumber: Int, note: String = "", requestedAt: Date) {
        self.machine = machine
        self.taskNumber = taskNumber
        self.note = note
        self.requestedAt = requestedAt
    }
}

// MARK: - フィードバック（セッションへ届けるもの）

/// 送信済みでセッション未受領のレビューと回答。Stop hook（claim / ack）と `feedback_list` が返す。
public struct FeedbackBundle: Codable, Hashable, Sendable {
    public struct ReviewEntry: Codable, Hashable, Sendable {
        public var review: Review
        public var comments: [DocComment]
        public var replies: [ReplyEntry]

        public init(review: Review, comments: [DocComment], replies: [ReplyEntry]) {
            self.review = review
            self.comments = comments
            self.replies = replies
        }
    }

    public struct ReplyEntry: Codable, Hashable, Sendable {
        public var reply: CommentReply
        public var docName: String
        public var commentBody: String

        public init(reply: CommentReply, docName: String, commentBody: String) {
            self.reply = reply
            self.docName = docName
            self.commentBody = commentBody
        }
    }

    /// 利用者が［対応済みにする］を押した手作業（作業項目の手作業待ち）
    public struct FinishedWork: Codable, Hashable, Sendable {
        public var itemID: Int64
        public var taskNumber: Int
        public var title: String
        /// 頼んだ文（済ませる前の待ち理由）
        public var request: String
        public var finishedAt: Date

        public init(itemID: Int64, taskNumber: Int, title: String, request: String, finishedAt: Date) {
            self.itemID = itemID
            self.taskNumber = taskNumber
            self.title = title
            self.request = request
            self.finishedAt = finishedAt
        }
    }

    public var reviews: [ReviewEntry]
    public var answeredAsks: [Ask]
    public var finishedWork: [FinishedWork]
    /// 概況の送る文面の承認（人が編集した本文）
    public var drafts: [PanelDraftFeedback]

    public init(
        reviews: [ReviewEntry] = [], answeredAsks: [Ask] = [], finishedWork: [FinishedWork] = [], drafts: [PanelDraftFeedback] = []
    ) {
        self.reviews = reviews
        self.answeredAsks = answeredAsks
        self.finishedWork = finishedWork
        self.drafts = drafts
    }

    private enum CodingKeys: String, CodingKey { case reviews, answeredAsks, finishedWork, drafts }

    /// 手作業を載せる前の daemon の応答は `finishedWork` を持たない
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reviews = try c.decode([ReviewEntry].self, forKey: .reviews)
        answeredAsks = try c.decode([Ask].self, forKey: .answeredAsks)
        finishedWork = try c.decodeIfPresent([FinishedWork].self, forKey: .finishedWork) ?? []
        drafts = try c.decodeIfPresent([PanelDraftFeedback].self, forKey: .drafts) ?? []
    }

    public var isEmpty: Bool { reviews.isEmpty && answeredAsks.isEmpty && finishedWork.isEmpty && drafts.isEmpty }
    public var count: Int { reviews.count + answeredAsks.count + finishedWork.count + drafts.count }

    /// 上限に収まらないときに落とす順（レビュー・回答・手作業・送る文面の順に、後ろから 1 件ずつ）。落とせなければ nil
    func droppingLast() -> FeedbackBundle? {
        var next = self
        if !next.reviews.isEmpty { next.reviews.removeLast() }
        else if !next.answeredAsks.isEmpty { next.answeredAsks.removeLast() }
        else if !next.finishedWork.isEmpty { next.finishedWork.removeLast() }
        else if !next.drafts.isEmpty { next.drafts.removeLast() }
        else { return nil }
        return next
    }
}

// MARK: - 要求と応答

/// `POST /v1/tasks/{n}/docs`。同じ名前なら新しいリビジョン。`questions` 省略は「今ある質問に触らない」、空配列は取り下げ。
public struct DocPublishRequest: Codable, Hashable, Sendable {
    public var name: String
    public var format: DocFormat
    public var content: String
    public var title: String?
    /// publish 元の絶対パス。省略は「元ファイルなし」として既存の記録を消す
    public var sourcePath: String?
    public var questions: [AskQuestion]?
    /// 質問を出した会話（回答をそこに届ける）。省くと、タスクに結ばれたセッションから届け先を決める
    public var requester: FeedbackRequester?
    /// 質問に結ぶ作業項目（同じタスクのもの）。出すと回答待ちになり、回答か取り下げで作業中に戻る
    public var workItem: Int64?
    /// 本文に置く送る文面。省略は「今ある文面に触らない」、空配列は全部外す
    public var drafts: [DocDraftSpec]?
    /// 本文の印の位置に描く修正前と修正後。版の一部なので、省略はこの版に無いこと
    public var changes: [DocChange]?

    public init(
        name: String, format: DocFormat, content: String, title: String? = nil, sourcePath: String? = nil, questions: [AskQuestion]? = nil,
        requester: FeedbackRequester? = nil, workItem: Int64? = nil, drafts: [DocDraftSpec]? = nil, changes: [DocChange]? = nil
    ) {
        self.name = name
        self.format = format
        self.content = content
        self.title = title
        self.sourcePath = sourcePath
        self.questions = questions
        self.requester = requester
        self.workItem = workItem
        self.drafts = drafts
        self.changes = changes
    }

    /// 名前の制約。パス区切りと `.` `..` を弾く
    public static func validateName(_ name: String) -> String? {
        if name.isEmpty || name.count > 200 { return "文書名は 1〜200 文字" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
        if name.contains("/") || name.contains("\\") || name == "." || name == ".." { return "文書名にパス区切りは使えない" }  // ui-copy:ignore（MCP でエージェントに返す検証の文。画面には出ない）
        return nil
    }
}

/// 既存の文書に質問だけ付ける（`POST /v1/docs/{id}/asks`）。本文は変えない
public struct DocAskRequest: Codable, Hashable, Sendable {
    public var questions: [AskQuestion]
    public var requester: FeedbackRequester?
    /// `DocPublishRequest.workItem` と同じ
    public var workItem: Int64?

    public init(questions: [AskQuestion], requester: FeedbackRequester? = nil, workItem: Int64? = nil) {
        self.questions = questions
        self.requester = requester
        self.workItem = workItem
    }
}

/// 質問・レビューを頼んだ会話。MCP の process が知っている手がかりをそのまま送り、daemon が Claude の会話 ID に決める
/// （host の会話は会話の id、pane は pane の今のセッション、どちらでもなければ環境のセッション ID）
public struct FeedbackRequester: Codable, Hashable, Sendable {
    public var conversationID: String?
    public var pane: PaneID?
    public var agentSessionID: String?

    public init(conversationID: String? = nil, pane: PaneID? = nil, agentSessionID: String? = nil) {
        self.conversationID = conversationID
        self.pane = pane
        self.agentSessionID = agentSessionID
    }

    public var isEmpty: Bool { conversationID == nil && pane == nil && agentSessionID == nil }
}

public struct DocPublishResponse: Codable, Hashable, Sendable {
    public var document: Document
    public var revision: Int
    public var isNew: Bool
    /// 文書に付いている未回答の質問。無ければ nil
    public var askID: Int64?
    /// 送信済みでセッション未受領のフィードバック件数（feedback_list で回収を促す）
    public var pendingFeedback: Int

    public init(document: Document, revision: Int, isNew: Bool, askID: Int64?, pendingFeedback: Int) {
        self.document = document
        self.revision = revision
        self.isNew = isNew
        self.askID = askID
        self.pendingFeedback = pendingFeedback
    }
}

/// `POST /v1/asks/{id}/answer`。全問に回答が要る。
public struct AskAnswerRequest: Codable, Hashable, Sendable {
    public var answers: [AskAnswer]

    public init(answers: [AskAnswer]) {
        self.answers = answers
    }
}

/// `POST /v1/docs/{id}/submit`。文書の欄を 1 回で送る：質問の回答（`askID` と `answers`。無ければ nil と空）と、送る文面の承認。
/// 1 つの書き込みで記録するので、会話には 1 通で届く
public struct DocSubmitRequest: Codable, Hashable, Sendable {
    public struct Approval: Codable, Hashable, Sendable {
        public var draftID: String
        /// 人が編集した後の本文
        public var body: String

        public init(draftID: String, body: String) {
            self.draftID = draftID
            self.body = body
        }
    }

    public var askID: Int64?
    public var answers: [AskAnswer]
    public var approvals: [Approval]

    public init(askID: Int64? = nil, answers: [AskAnswer] = [], approvals: [Approval] = []) {
        self.askID = askID
        self.answers = answers
        self.approvals = approvals
    }
}

/// `POST /v1/docs/{id}/comments`。draft として作る。
public struct CommentCreateRequest: Codable, Hashable, Sendable {
    public var rev: Int
    public var anchor: CommentAnchor?
    public var body: String

    public init(rev: Int, anchor: CommentAnchor? = nil, body: String) {
        self.rev = rev
        self.anchor = anchor
        self.body = body
    }
}

/// `PATCH /v1/comments/{id}`（draft の本文だけ変えられる）。
public struct CommentUpdateRequest: Codable, Hashable, Sendable {
    public var body: String

    public init(body: String) {
        self.body = body
    }
}

/// `POST /v1/comments/{id}/reply`。agent の返信は即 submitted、人の返信はレビューの送信まで draft。
public struct CommentReplyRequest: Codable, Hashable, Sendable {
    public var author: CommentReply.Author
    public var body: String
    public var resolve: Bool

    public init(author: CommentReply.Author, body: String, resolve: Bool = false) {
        self.author = author
        self.body = body
        self.resolve = resolve
    }
}

/// `PATCH /v1/tasks/{n}/review`。総括の下書き。
public struct ReviewSummaryRequest: Codable, Hashable, Sendable {
    public var summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

/// `POST /v1/tasks/{n}/review-request`。
public struct ReviewRequestCreate: Codable, Hashable, Sendable {
    public var note: String
    /// レビューを頼んだ会話（送られたレビューをそこに届ける）
    public var requester: FeedbackRequester?

    public init(note: String = "", requester: FeedbackRequester? = nil) {
        self.note = note
        self.requester = requester
    }
}

public struct ReviewRequestResult: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case requested
        /// 先に送られたレビューが未受領で残っている。依頼は立てない
        case feedbackPending
    }

    public var status: Status
    public var pendingFeedback: Int

    public init(status: Status, pendingFeedback: Int) {
        self.status = status
        self.pendingFeedback = pendingFeedback
    }
}

/// `POST /v1/feedback/claim`: Stop hook が、セッションに紐づくタスクの未受領フィードバックを取りに来る。
/// 無ければ `timeoutMs` まで届くのを待つ。
public struct FeedbackClaimRequest: Codable, Hashable, Sendable {
    public var agentSessionID: String
    /// 届くまで待つ時間。0 なら待たない（ターンの途中の hook）。省くと 1 時間
    public var timeoutMs: Int?

    public init(agentSessionID: String, timeoutMs: Int? = nil) {
        self.agentSessionID = agentSessionID
        self.timeoutMs = timeoutMs
    }
}

public struct FeedbackClaimResponse: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case feedback
        case pending
        /// セッションに紐づくタスクが無い
        case noSession
    }

    public var status: Status
    public var claimID: String?
    public var bundle: FeedbackBundle?

    public init(status: Status, claimID: String? = nil, bundle: FeedbackBundle? = nil) {
        self.status = status
        self.claimID = claimID
        self.bundle = bundle
    }
}

/// `POST /v1/feedback/ack`: 届けきれたので受領済みにする。
public struct FeedbackAckRequest: Codable, Hashable, Sendable {
    public var claimID: String

    public init(claimID: String) {
        self.claimID = claimID
    }
}

/// `POST /v1/tasks/{n}/feedback/take`: 未受領を返して受領済みにする（`feedback_list`）。
public struct FeedbackTakeResponse: Codable, Hashable, Sendable {
    public var bundle: FeedbackBundle

    public init(bundle: FeedbackBundle) {
        self.bundle = bundle
    }
}
