import Foundation
import Logging
import TaskboardKit

// 動いていない codex の会話にも答える要求（履歴・子の thread・最後の返事・フォーク）と、codex を起こす口
extension ConversationService {
    /// codex の会話の履歴の 1 頁（新しい順に読み、頁の中は古い順に返す）。thread をまだ作っていない会話は空。
    /// `subagents` なら、頁の中の呼び出しが起こした子の thread の発言を後ろに足す（`limit` に数えない）
    func codexHistory(_ record: ConversationRecord, before cursor: String?, limit: Int, subagents: Bool) async throws -> ConversationHistoryResponse {
        guard record.agentSessionId != record.id else { return ConversationHistoryResponse(messages: [], nextCursor: nil, agentSessionID: record.agentSessionId) }
        let page = try await codexRequest(record, "thread/items/list", CodexProtocol.ItemsList(threadId: record.agentSessionId, cursor: cursor, limit: limit))
            .result(CodexProtocol.ItemsPage.self)
        let entries = Array(page.data.reversed())
        var messages = entries.flatMap { CodexItems.messages($0.item, at: $0.completedAt) }
        if subagents {
            var seen: Set<String> = [record.agentSessionId]
            messages += await codexSubagents(record, spawnedIn: entries, thread: nil, depth: 0, seen: &seen)
        }
        return ConversationHistoryResponse(messages: messages, nextCursor: page.nextCursor, agentSessionID: record.agentSessionId)
    }

    /// `entries`（`thread` の item。nil は本筋）の `subAgentActivity` の started が起こした子の thread の新しい `codexSubagentLimit` 件を、起こした行の下に写す。
    /// 読めない子は飛ばし、履歴は失敗にしない
    func codexSubagents(
        _ record: ConversationRecord, spawnedIn entries: [CodexProtocol.ItemsPage.Entry], thread: String?, depth: Int, seen: inout Set<String>
    ) async -> [ChatMessage] {
        guard depth < Self.codexSubagentDepth else { return [] }
        var found: [ChatMessage] = []
        for entry in entries {
            guard case .subagent(_, "started", let child, _) = entry.item, seen.insert(child).inserted else { continue }
            let toolID = CodexItems.subagentParent(child, spawnedIn: thread)
            let page: CodexProtocol.ItemsPage
            do {
                page = try await codexRequest(record, "thread/items/list", CodexProtocol.ItemsList(threadId: child, cursor: nil, limit: Self.codexSubagentLimit))
                    .result(CodexProtocol.ItemsPage.self)
            } catch {
                environment.logger.info(
                    "codex subagent history unavailable", metadata: ["conversation": .string(record.id), "thread": .string(child), "error": "\(error)"])
                continue
            }
            let items = Array(page.data.reversed())
            found += items.flatMap { CodexItems.subagentMessages($0.item, at: $0.completedAt, thread: child, parentToolID: toolID) }
            found += await codexSubagents(record, spawnedIn: items, thread: child, depth: depth + 1, seen: &seen)
        }
        return found
    }

    /// Claude の会話のサブエージェントの上限（`SubagentTranscripts`）に揃える
    static let codexSubagentLimit = 200
    static let codexSubagentDepth = 4

    /// 終わった最後の turn の最後の返事。`timing.noticeReply` で読み切れなければ諦める（知らせを遅らせない）。
    /// 読む口は `thread/items/list` だけで、モデルを呼ぶ要求は送らない
    func codexLatestReply(_ record: ConversationRecord) async -> String? {
        guard record.agentSessionId != record.id else { return nil }
        let wasBusy = await conversations[record.id]?.noticeState.busy ?? false
        do {
            let messages = try await Deadline.run(environment.timing.noticeReply) { [self] in try await codexLastTurnMessages(record, skippingNewest: wasBusy) }
            // 読む間に生成が始まった・終わったときは、どの turn が終わったものか言えない
            let isBusy = await conversations[record.id]?.noticeState.busy ?? false
            guard isBusy == wasBusy else { return nil }
            return OrchestratorReplyReader.latest(in: messages).map { String($0.last.prefix(OrchestratorReplyReader.limit)) }
        } catch {
            environment.logger.warning("codex reply unavailable", metadata: ["conversation": .string(record.id), "error": "\(error)"])
            return nil
        }
    }

    /// 新しい側から読んで、終わった最後の turn の発言（古い順）。`skippingNewest` は、生成中の turn が先頭にあるとき
    func codexLastTurnMessages(_ record: ConversationRecord, skippingNewest: Bool) async throws -> [ChatMessage] {
        var cursor: String?
        var skipping = skippingNewest
        var skipped: String?
        var target: String?
        var found: [ChatMessage] = []
        for _ in 0..<Self.codexReplyPages {
            let page = try await codexRequest(
                record, "thread/items/list", CodexProtocol.ItemsList(threadId: record.agentSessionId, cursor: cursor, limit: Self.codexReplyLimit)
            ).result(CodexProtocol.ItemsPage.self)
            for entry in page.data {
                let turn = entry.turnId ?? ""
                if skipping {
                    skipped = skipped ?? turn
                    if turn == skipped { continue }
                    skipping = false
                }
                target = target ?? turn
                guard turn == target else { return found.reversed() }
                found += CodexItems.messages(entry.item, at: nil).reversed()
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return found.reversed()
    }

    static let codexReplyPages = 5
    static let codexReplyLimit = 100

    /// codex の会話の要求を、動いていればその会話の app-server に、動いていなければ 1 本だけ起こした app-server に送る
    func codexRequest(_ record: ConversationRecord, _ method: String, _ params: some Encodable & Sendable) async throws -> CodexRPCLine {
        if let live = conversations[record.id] as? CodexConversation, let line = try await live.request(method, params) { return line }
        return try await codexOneShot(method, params)
    }

    func codexOneShot(_ method: String, _ params: any Encodable & Sendable) async throws -> CodexRPCLine {
        if let call = environment.codexOneShot { return try await call(method, params) }
        return try await CodexOneShot.call(try await codexLaunch(), method, params, timeout: environment.timing.control)
    }

    /// codex の会話のフォーク：`thread/fork` で写した thread を、同じタスク・フォルダ・設定の新しい会話で戻す。
    /// 写すのは `messageID` の発言の turn まで（省けば今の末尾まで。生成中なら断る）
    func forkCodex(_ source: ConversationRecord, _ request: ConversationForkRequest) async throws -> Conversation {
        if let made = try environment.store.conversation(forkRequestID: request.requestID) { return try await get(made.id) }
        guard source.agentSessionId != source.id else { throw ConversationError.notSent(source.id) }
        if request.messageID == nil, let running = conversations[source.id], await running.isLive, await !running.isIdle {
            throw ConversationError.busy(source.id, "生成中")
        }
        var lastTurn: String?
        if let messageID = request.messageID { lastTurn = try await codexTurn(of: messageID, in: source) }
        let permissions = CodexPermissions(mode: source.permissionMode)
        let forked = try await codexOneShot(
            "thread/fork",
            CodexProtocol.ThreadFork(
                threadId: source.agentSessionId, lastTurnId: lastTurn, cwd: source.cwd, approvalPolicy: permissions.approvalPolicy, sandbox: permissions.sandbox)
        ).result(CodexProtocol.ThreadOpened.self).thread.id
        var made = ConversationRecord(
            taskNumber: source.taskNumber, engine: .codex, agentSessionId: forked, cwd: source.cwd, model: source.model, effort: source.effort,
            permissionMode: source.permissionMode, title: source.title, customTitle: source.customTitle, runner: .none)
        made.forkSourceId = source.id
        made.forkRequestId = request.requestID
        made.forkAt = request.messageID.map(ConversationFork.lineUUID)
        let record: ConversationRecord
        do {
            record = try environment.store.createConversation(made)
        } catch {
            // 同じ requestID の 2 回目が、thread を写している間に先に記録を作った
            if let existing = try environment.store.conversation(forkRequestID: request.requestID) { return try await get(existing.id) }
            throw error
        }
        environment.logger.info("conversation forked", metadata: ["conversation": .string(record.id), "source": .string(source.id)])
        let conversation = try make(record)
        do {
            try await conversation.start(resume: true)
        } catch {
            try? await delete(record.id)
            throw error
        }
        if let prompt = request.prompt, !prompt.isEmpty {
            _ = try await conversation.send(ConversationSendRequest(text: prompt, clientMessageID: UUID().uuidString.lowercased()))
        }
        return await conversation.snapshot()
    }

    /// 発言（履歴の `ChatMessage` の id）の turn。新しい順に頁をたどって探す
    func codexTurn(of messageID: String, in record: ConversationRecord) async throws -> String {
        let wanted = CodexItems.itemID(ofMessage: messageID)
        var cursor: String?
        for _ in 0..<Self.codexForkSearchPages {
            let page = try await codexRequest(
                record, "thread/items/list", CodexProtocol.ItemsList(threadId: record.agentSessionId, cursor: cursor, limit: Self.codexForkSearchLimit)
            ).result(CodexProtocol.ItemsPage.self)
            if let entry = page.data.first(where: { CodexItems.matches($0.item, itemID: wanted) }), let turn = entry.turnId { return turn }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        throw ConversationError.messageNotFound(messageID)
    }

    static let codexForkSearchPages = 20
    static let codexForkSearchLimit = 200

    /// 確かめた版の codex とログインシェルの環境。確かめた版が無ければ起こさない（app-server の口は版で変わる）
    func codexLaunch() async throws -> EngineLaunch {
        guard let entry = VerifiedCLI.load(.codex, supportDirectory: environment.supportDirectory)?.newest(requiring: []) else {
            throw ConversationError(status: 409, code: .codexUnverified, description: "確かめた版の codex が無い（taskboard conversation check --engine codex）")
        }
        return EngineLaunch(executable: entry.path, environment: await launchEnvironment())
    }
}
