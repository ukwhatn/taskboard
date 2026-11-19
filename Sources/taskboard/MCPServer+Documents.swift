import Foundation
import MCP
import TaskboardKit

/// 文書・質問・レビューの tool
extension TaskboardTools {
    /// `ask_user` / `doc_publish` の questions。id は並び順で振る（q1, q2, …）ので渡さない
    static let questionsSchema: Value = .object([
        "type": .string("array"), "maxItems": .int(8),
        "items": schema([
            "question": property("string", Copy.text("agent.tool.questionsSchema.question")),
            "header": property("string", Copy.text("agent.tool.questionsSchema.header")),
            "options": .object([
                "type": .string("array"), "minItems": .int(1), "maxItems": .int(8),
                "description": .string(Copy.text("agent.mcp.documents.questionsSchema")),
                "items": schema([
                    "label": property("string"),
                    "description": property("string", Copy.text("agent.tool.questionsSchema.description")),
                    "preview": property(
                        "string",
                        Copy.text("agent.mcp.documents.questionsSchema.2")),
                    "recommended": property("boolean", Copy.text("agent.tool.questionsSchema.recommended")),
                ], required: ["label"]),
            ]),
            "multi_select": property("boolean"),
        ], required: ["question", "options"]),
    ])

    /// `doc_publish` の drafts。欄は概況の送る文面と同じ
    static let draftsSchema: Value = .object([
        "type": .string("array"), "maxItems": .int(DocDraftSpec.maxCount),
        "description": .string(Copy.text("agent.tool.doc_publish.drafts")),
        "items": schema([
            "id": property("string", Copy.text("agent.tool.doc_publish.drafts.id")),
            "title": property("string", Copy.text("agent.tool.doc_publish.drafts.title")),
            "to": property("string", Copy.text("agent.tool.doc_publish.drafts.to")),
            "body": property("string", Copy.text("agent.tool.doc_publish.drafts.body")),
            "checks": .object([
                "type": .string("array"), "maxItems": .int(PanelBudget.checks),
                "description": .string(Copy.text("agent.tool.doc_publish.drafts.checks")),
                "items": schema(["label": property("string"), "ok": property("boolean"), "note": property("string")], required: ["label", "ok"]),
            ]),
        ], required: ["id", "to", "body"]),
    ])

    static let workItemForAskProperty = property(
        "integer",
        Copy.text("agent.mcp.documents.workItemForAskProperty"))

    static let documentTools: [ToolEntry] = [
        ToolEntry(
            name: "doc_publish",
            description: Copy.text("agent.tool.doc_publish"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "path": property("string", Copy.text("agent.tool.doc_publish.path")),
                "content": property("string", Copy.text("agent.tool.doc_publish.content")),
                "name": property("string", Copy.text("agent.tool.doc_publish.name")),
                "format": property("string", Copy.text("agent.tool.doc_publish.format"), enum: ["markdown", "html"]),
                "title": property("string", Copy.text("agent.tool.doc_publish.title")),
                "questions": questionsSchema,
                "drafts": draftsSchema,
                "work_item": workItemForAskProperty,
            ])) { tools, args in try await tools.docPublish(args) },
        ToolEntry(
            name: "doc_list", description: Copy.text("agent.tool.doc_list"),
            inputSchema: currentTaskOnlySchema) { tools, args in try await tools.docList(args) },
        ToolEntry(
            name: "ask_user",
            description: Copy.text("agent.tool.ask_user"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "questions": questionsSchema,
                "context": property("string", Copy.text("agent.tool.ask_user.context")),
                "title": property("string", Copy.text("agent.tool.ask_user.title")),
                "name": property("string", Copy.text("agent.tool.ask_user.name")),
                "work_item": workItemForAskProperty,
            ], required: ["questions"])) { tools, args in try await tools.askUser(args) },
        ToolEntry(
            name: "review_request",
            description: Copy.text("agent.tool.review_request"),
            inputSchema: schema([
                "task_id": currentTaskIDProperty,
                "note": property("string", Copy.text("agent.tool.review_request.note")),
                "wait_seconds": property("integer", Copy.text("agent.tool.review_request.wait_seconds")),
            ])) { tools, args in try await tools.reviewRequest(args) },
        ToolEntry(
            name: "feedback_list", description: Copy.text("agent.tool.feedback_list"),
            inputSchema: currentTaskOnlySchema) { tools, args in try await tools.feedbackList(args) },
        ToolEntry(
            name: "comment_reply", description: Copy.text("agent.tool.comment_reply"),
            inputSchema: schema([
                "comment_id": property("integer", Copy.text("agent.tool.comment_reply.comment_id")),
                "body": property("string"),
                "resolve": property("boolean", Copy.text("agent.tool.comment_reply.resolve")),
            ], required: ["comment_id", "body"])) { tools, args in try await tools.commentReply(args) },
    ]

    /// 質問の入力を `AskQuestion` に。id は並び順（同じ入力が同じ JSON になり、daemon が「同じ質問での再 publish」と判定できる）
    static func questions(from value: Value?) throws -> [AskQuestion]? {
        guard let array = value?.arrayValue else { return nil }
        return try array.enumerated().map { index, item in
            guard let object = item.objectValue, let question = object["question"]?.stringValue, !question.isEmpty else {
                throw ToolError.invalid(Copy.text("agent.mcp.documents.questions", ["index": "\(index)"]))
            }
            let options = try (object["options"]?.arrayValue ?? []).map { option -> AskOption in
                guard let o = option.objectValue, let label = o["label"]?.stringValue, !label.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.documents.options")) }
                return AskOption(
                    label: label, description: o["description"]?.stringValue, preview: o["preview"]?.stringValue, recommended: o["recommended"]?.boolValue ?? false)
            }
            return AskQuestion(
                id: "q\(index + 1)", question: question, header: object["header"]?.stringValue, options: options,
                multiSelect: object["multi_select"]?.boolValue ?? object["multiSelect"]?.boolValue ?? false)
        }
    }

    /// 送る文面の入力を `DocDraftSpec` に（JSON は概況の部品と同じ欄なので、そのまま decode する）
    static func drafts(from value: Value?) throws -> [DocDraftSpec]? {
        guard let value, value.arrayValue != nil else { return nil }
        do {
            return try JSONDecoder().decode([DocDraftSpec].self, from: JSONEncoder().encode(value))
        } catch {
            throw ToolError.invalid(Copy.text("agent.mcp.documents.drafts"))
        }
    }

    private func docPublish(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let path = args.string("path")
        let content = args.string("content")
        if path != nil, content != nil { throw ToolError.invalid(Copy.text("agent.mcp.documents.content")) }
        let body: String
        let name: String
        var sourcePath: String?
        if let path {
            let absolute = path.hasPrefix("/") ? path : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: path).standardizedFileURL.path
            guard let data = FileManager.default.contents(atPath: absolute), let text = String(data: data, encoding: .utf8) else {
                throw ToolError.invalid(Copy.text("agent.mcp.devin.absolute", ["absolute": "\(absolute)"]))
            }
            body = text
            name = args.string("name") ?? URL(fileURLWithPath: absolute).lastPathComponent
            sourcePath = absolute
        } else if let content {
            guard let given = args.string("name"), !given.isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.documents.absolute")) }
            body = content
            name = given
        } else {
            throw ToolError.invalid(Copy.text("agent.mcp.documents.absolute.2"))
        }
        guard let format = args.string("format").flatMap(DocFormat.init(rawValue:)) ?? DocFormat.infer(fromName: name) else {
            throw ToolError.invalid(Copy.text("agent.mcp.documents.absolute.3", ["name": "\(name)"]))
        }
        let questions = try Self.questions(from: args["questions"])
        if let questions, let problem = AskQuestion.validate(questions) { throw ToolError.invalid(problem) }
        let drafts = try Self.drafts(from: args["drafts"])
        if let drafts, let problem = DocDraftSpec.validate(drafts) { throw ToolError.invalid(problem) }
        let request = DocPublishRequest(
            name: name, format: format, content: body, title: args.string("title"), sourcePath: sourcePath, questions: questions, requester: requester,
            workItem: args.int64("work_item"), drafts: drafts)
        let result = try await client.publishDocument(task: number, request)
        return Self.describe(publish: result, task: number)
    }

    private static func describe(publish result: DocPublishResponse, task number: Int) -> String {
        var lines = [Copy.text("agent.mcp.documents.lines")]
        lines.append(Copy.text(result.isNew ? "agent.mcp.documents.published.new" : "agent.mcp.documents.published.updated", ["docID": "\(result.document.docID)", "name": result.document.name, "revision": "\(result.revision)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.2", ["number": "\(number)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.3", ["appURL": "\(appURL(result.document.machine, task: number, doc: result.document.docID))"]))
        if let askID = result.askID {
            lines.append("- ask_id: \(askID)")
            lines.append(Copy.text("agent.mcp.documents.lines.4"))
        }
        let drafts = result.document.drafts
        if !drafts.isEmpty {
            lines.append(Copy.text("agent.mcp.documents.lines.drafts", ["count": "\(drafts.count)", "open": "\(result.document.openDrafts.count)"]))
        }
        if result.pendingFeedback > 0 { lines.append(Copy.text("agent.mcp.documents.lines.5", ["pendingFeedback": "\(result.pendingFeedback)"])) }
        return lines.joined(separator: "\n")
    }

    private func docList(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let docs = try await client.documents(task: number)
        guard !docs.isEmpty else { return Copy.text("agent.mcp.documents.docs", ["number": "\(number)"]) }
        let asks = try await client.asks(task: number)
        var lines = [Copy.text("agent.mcp.documents.lines.6", ["number": "\(number)", "docs": "\(docs.count)"])]
        for doc in docs {
            var line = "- [\(doc.docID)] \(doc.name)"
            if let title = doc.title, !title.isEmpty { line += "「\(title)」" }
            lines.append(line + " ・ \(doc.format.rawValue) ・ rev \(doc.latestRev)")
            var status: [String] = []
            if let open = asks.first(where: { $0.docID == doc.docID && $0.status == .open }) { status.append(Copy.text("agent.mcp.documents.status", ["questions": "\(open.questions.count)", "askID": "\(open.askID)"])) }
            if doc.openComments > 0 { status.append(Copy.text("agent.mcp.documents.status.2", ["openComments": "\(doc.openComments)"])) }
            if doc.draftComments > 0 { status.append(Copy.text("agent.mcp.documents.status.3", ["draftComments": "\(doc.draftComments)"])) }
            if !status.isEmpty { lines.append("  - " + status.joined(separator: " ・ ")) }
        }
        return lines.joined(separator: "\n")
    }

    private func askUser(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        guard let questions = try Self.questions(from: args["questions"]), !questions.isEmpty else { throw ToolError.missing("questions") }
        if let problem = AskQuestion.validate(questions) { throw ToolError.invalid(problem) }
        let name = args.string("name") ?? "questions.md"
        let title = args.string("title") ?? Copy.text("agent.mcp.documents.title")
        var body = args.string("context") ?? ""
        // 既存の文書には質問だけ付ける。publish し直すと、計画書の本文が context（質問の文）で置き換わっていた
        if name != "questions.md", let existing = try await client.documents(task: number).first(where: { $0.name == name }) {
            guard body.isEmpty else {
                throw ToolError.invalid(Copy.text("agent.mcp.documents.body", ["name": "\(name)"]))
            }
            let result = try await client.attachQuestions(doc: existing.docID, DocAskRequest(questions: questions, requester: requester, workItem: args.int64("work_item")))
            return Self.describe(
                asked: questions.count, askID: result.askID, document: Copy.text("agent.mcp.documents.result", ["docID": "\(existing.docID)", "name": "\(name)", "revision": "\(result.revision)"]),
                app: Self.appURL(existing.machine, task: number, doc: existing.docID), task: number, pendingFeedback: result.pendingFeedback)
        }
        // 前提の無い質問を作らせない（答える人が前提を別の所で読み直すことになる）
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalid(Copy.text("agent.mcp.documents.context")) }
        let format = DocFormat.infer(fromName: name) ?? .markdown
        let result = try await client.publishDocument(
            task: number, DocPublishRequest(
                name: name, format: format, content: body, title: title, questions: questions, requester: requester, workItem: args.int64("work_item")))
        return Self.describe(
            asked: questions.count, askID: result.askID, document: "[\(result.document.docID)] \(result.document.name) ・ rev \(result.revision)",
            app: Self.appURL(result.document.machine, task: number, doc: result.document.docID), task: number, pendingFeedback: result.pendingFeedback)
    }

    /// 会話の画面はこの行から文書を開く入口を作る（`DocumentToolRef`）
    private static func appURL(_ machine: MachineID, task number: Int, doc: Int64) -> String {
        "taskboard://task/\(machine.rawValue)/\(number)/doc/\(doc)"
    }

    private static func describe(asked count: Int, askID: Int64?, document: String, app: String, task number: Int, pendingFeedback: Int) -> String {
        var lines = [Copy.text("agent.mcp.documents.lines.7")]
        if let askID { lines.append("- ask_id: \(askID)") }
        lines.append(Copy.text("agent.mcp.documents.lines.8", ["value": "\(count)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.9", ["document": "\(document)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.2", ["number": "\(number)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.10", ["app": "\(app)"]))
        lines.append(Copy.text("agent.mcp.documents.lines.11"))
        if pendingFeedback > 0 { lines.append(Copy.text("agent.mcp.documents.lines.12", ["pendingFeedback": "\(pendingFeedback)"])) }
        return lines.joined(separator: "\n")
    }

    private func reviewRequest(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let result = try await client.requestReview(task: number, ReviewRequestCreate(note: args.string("note") ?? "", requester: requester))
        if result.status == .feedbackPending {
            return Copy.text("agent.mcp.documents.result.3", ["pendingFeedback": "\(result.pendingFeedback)"])
        }
        guard let seconds = args.int("wait_seconds") else {
            return Copy.text("agent.mcp.documents.result.4", ["number": "\(number)"])
        }
        let deadline = Date().addingTimeInterval(TimeInterval(min(max(seconds, 5), 1800)))
        while Date() < deadline {
            let taken = try await client.takeFeedback(task: number).bundle
            if !taken.isEmpty { return FeedbackText.render(taken) }
            try await Task.sleep(for: .seconds(3))
        }
        return Copy.text("agent.mcp.documents.taken")
    }

    private func feedbackList(_ args: [String: Value]) async throws -> String {
        let number = try await resolveTaskNumber(args)
        let bundle = try await client.takeFeedback(task: number).bundle
        return bundle.isEmpty ? Copy.text("agent.mcp.documents.bundle") : FeedbackText.render(bundle)
    }

    private func commentReply(_ args: [String: Value]) async throws -> String {
        guard let id = args.int64("comment_id") else { throw ToolError.missing("comment_id") }
        guard let body = args.string("body"), !body.isEmpty else { throw ToolError.missing("body") }
        let resolve = args.bool("resolve") ?? false
        let reply = try await client.replyComment(id: id, CommentReplyRequest(author: .agent, body: body, resolve: resolve))
        return Copy.text("agent.mcp.documents.reply", ["commentID": "\(reply.commentID)"]) + (resolve ? Copy.text("agent.mcp.documents.reply.2") : "")
    }
}
