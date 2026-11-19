import Foundation
import TaskboardKit

/// 開いたときに取る中身の様子
enum ConversationLoad<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(UserFacingError)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    func debugDescription(_ describe: (Value) -> Any) -> Any {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded(let value): describe(value)
        case .failed(let failure): ["failure": failure.text]
        }
    }
}

/// 入力欄の下の欄
enum ConversationField: String, CaseIterable, Identifiable {
    case model, effort, permission

    var id: String { rawValue }
}

/// 会話の画面に重ねるもの
enum ConversationSheet: Identifiable, Hashable {
    case diff
    /// 巻き戻しの確認。対象は人が送った発言
    case rewind(ChatMessage)
    /// 会話の作業フォルダのシェル
    case terminal(PaneID)
    case connectors
    /// コンテキストの内訳
    case context
    /// 読むだけのシート（書き出し・権限の規則・フック・メモリ・スキル）
    case readout(ConversationReadout)
    /// バックグラウンドのタスク
    case tasks
    /// 会話に残さない質問（`/btw`）。打った質問があれば、開いてすぐ聞く
    case sideQuestion(String)
    /// 作業フォルダの追加・変更（`/add-dir`・`/cd`）。打ったフォルダを欄に入れて開く
    case folder(ConversationFolderAction, String)
    /// Claude のアカウントのログイン（`/login`）
    case login

    var id: String {
        switch self {
        case .diff: "diff"
        case .connectors: "connectors"
        case .context: "context"
        case .readout(let readout): "readout-\(readout.rawValue)"
        case .tasks: "tasks"
        case .sideQuestion: "side-question"
        case .folder(let action, _): "folder-\(action.rawValue)"
        case .login: "login"
        case .rewind(let message): "rewind-\(message.id)"
        case .terminal(let pane): "terminal-\(pane.rawValue)"
        }
    }

    var debugName: String {
        switch self {
        case .diff: "diff"
        case .connectors: "connectors"
        case .context: "context"
        case .readout(let readout): "readout:\(readout.rawValue)"
        case .tasks: "tasks"
        case .sideQuestion: "sideQuestion"
        case .folder(let action, _): "folder:\(action.rawValue)"
        case .login: "login"
        case .rewind(let message): "rewind:\(message.id)"
        case .terminal(let pane): "shell:\(pane.rawValue)"
        }
    }
}

/// 会話の画面の操作（E3）。表示用のデータは `fixtureTools` から読み、書き込む操作は「表示用のデータです」で断る
extension ConversationFeed {
    private func requireSource() throws -> any ConversationSource {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        return source
    }

    // MARK: コマンド

    func loadCommands() {
        guard let source else { return }
        Task { [key] in
            // 取れなければ前の一覧のまま（taskboard の操作は一覧が無くても出る）
            if let response = try? await source.conversationCommands(key.id) { commands = response.commands }
        }
    }

    // MARK: 入力欄の下の欄

    func control(_ request: ConversationControlRequest) async throws {
        _ = try await requireSource().controlConversation(key.id, request)
    }

    /// `/model` などで欄を開く。コネクタとコンテキストの内訳はシートで開く
    func open(_ field: ConversationControlField) {
        switch field {
        case .model: openField = .model
        case .effort: openField = .effort
        case .context: sheet = .context
        case .mcp: sheet = .connectors
        }
    }

    func loadConnectors() {
        if let fixtureTools {
            connectors = .loaded(fixtureTools.mcpServers ?? [])
            return
        }
        guard source != nil else { return }
        if connectors.value == nil { connectors = .loading }
        Task { await fetchConnectors() }
    }

    private func fetchConnectors() async {
        guard let source else { return }
        do {
            let response = try await source.controlConversation(key.id, ConversationControlRequest(kind: .mcpStatus))
            let status = try response.payloadJSON.map { try WireJSON.decoder().decode(ConversationMcpStatus.self, from: Data($0.utf8)) }
            connectors = .loaded(status?.mcpServers ?? [])
        } catch {
            connectors = UserFacingError("コネクタを読み込めませんでした", error: error).map(ConversationLoad.failed) ?? connectors
        }
    }

    /// コネクタの認証を始め、開く認証のページを受け取る
    func authenticateConnector(_ name: String) async throws -> ConversationMcpAuthentication {
        let response = try await requireSource().controlConversation(key.id, ConversationControlRequest(kind: .mcpAuthenticate, value: name))
        return try WireJSON.decoder().decode(ConversationMcpAuthentication.self, from: Data((response.payloadJSON ?? "").utf8))
    }

    /// コネクタの問い（url）の開く先の全文。daemon はこの端末への応答にだけ載せる。開く前に `OAuthLinks.openable` で確かめる
    func elicitationURL(_ requestID: String) async throws -> URL {
        let response = try await requireSource().controlConversation(key.id, ConversationControlRequest(kind: .elicitationURL, value: requestID))
        let url = try WireJSON.decoder().decode(ElicitationURLResponse.self, from: Data((response.payloadJSON ?? "").utf8)).url
        guard let checked = OAuthLinks.openable(url) else { throw ElicitationLinkError.notOpenable }
        return checked
    }

    /// 認証のページを開いた後、接続するまで一覧を取り直す（3 秒ごとに 5 分まで。画面を閉じたら止める）
    func waitForConnection(_ name: String) async {
        for _ in 0..<100 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await fetchConnectors()
            if connectors.value?.first(where: { $0.name == name })?.status == "connected" { return }
        }
    }

    func loadContextBreakdown() {
        if let fixtureTools {
            contextBreakdown = fixtureTools.contextBreakdown.map(ConversationLoad.loaded) ?? .idle
            return
        }
        guard let source else { return }
        contextBreakdown = .loading
        Task { [key] in
            do {
                let response = try await source.controlConversation(key.id, ConversationControlRequest(kind: .contextBreakdown))
                contextBreakdown = .loaded(try WireJSON.decoder().decode(ConversationContextBreakdown.self, from: Data((response.payloadJSON ?? "").utf8)))
            } catch {
                contextBreakdown = UserFacingError("コンテキストの内訳を読み込めませんでした", error: error).map(ConversationLoad.failed) ?? .idle
            }
        }
    }

    /// 繋ぎ直す・有効と無効を替える。終わったら一覧を取り直す
    func changeConnector(_ request: ConversationControlRequest) async throws {
        try await control(request)
        loadConnectors()
    }

    // MARK: 差分

    func loadDiff() {
        if let fixtureTools {
            diff = fixtureTools.diff.map { .loaded(Self.fixtureDiff($0, scope: diffScope)) } ?? .idle
            return
        }
        guard let source else { return }
        if diff.value == nil { diff = .loading }
        // 開き直したら、ファイルの diff も取り直す
        fileDiffs = [:]
        Task { [key, diffScope] in
            do {
                let response = try await source.conversationDiff(key.id, scope: diffScope)
                // 待つ間に範囲を替えていたら、替えた後の読み込みに任せる
                guard diffScope == self.diffScope else { return }
                diff = .loaded(response)
            } catch {
                guard diffScope == self.diffScope else { return }
                diff = UserFacingError("差分を読み込めませんでした", error: error).map(ConversationLoad.failed) ?? diff
            }
        }
    }

    /// 比べる相手を替えて読み直す。前の範囲の一覧は残さない
    func setDiffScope(_ scope: ConversationDiffScope) {
        guard scope != diffScope else { return }
        diffScope = scope
        diff = .idle
        loadDiff()
    }

    /// fixtures の差分は 1 通り。ブランチ全体は fixtures の会話の既定のブランチと比べたことにする
    private static func fixtureDiff(_ response: ConversationDiffResponse, scope: ConversationDiffScope) -> ConversationDiffResponse {
        var response = response
        response.scope = scope
        if scope == .branch, response.base == nil { response.base = "main" }
        return response
    }

    func loadFileDiff(_ path: String) {
        if let fixtureTools {
            fileDiffs[path] = fixtureTools.fileDiffs[path].map { .loaded(ConversationFileDiffResponse(path: path, diff: $0, truncated: false)) } ?? .idle
            return
        }
        guard let source, fileDiffs[path]?.value == nil, fileDiffs[path]?.isLoading != true else { return }
        fileDiffs[path] = .loading
        Task { [key, diffScope] in
            do {
                let response = try await source.conversationFileDiff(key.id, path: path, scope: diffScope)
                guard diffScope == self.diffScope else { return }
                fileDiffs[path] = .loaded(response)
            } catch {
                guard diffScope == self.diffScope else { return }
                fileDiffs[path] = UserFacingError("差分を読み込めませんでした", error: error).map(ConversationLoad.failed) ?? .idle
            }
        }
    }

    // MARK: フォーク・巻き戻し

    /// `messageID` の発言までを写した新しい会話を起こす（省くと末尾まで）
    func fork(from messageID: String?) async throws -> Conversation {
        try await requireSource().forkConversation(key.id, ConversationForkRequest(messageID: messageID))
    }

    /// 巻き戻すと何が変わるか（会話は変えない）。表示用のデータは fixtures の結果
    func previewRewind(_ messageID: String, agentSessionID: String) async throws -> ConversationRewindResponse {
        if let preview = fixtureTools?.rewind { return preview }
        return try await requireSource().rewindConversation(
            key.id, ConversationRewindRequest(messageID: messageID, expectedAgentSessionID: agentSessionID, files: true, dryRun: true))
    }

    /// 巻き戻して、戻した発言の本文を入力欄に戻す。手元の発言は購読の `reset` で取り直す
    func rewind(_ messageID: String, agentSessionID: String, files: Bool) async throws {
        let response = try await requireSource().rewindConversation(
            key.id, ConversationRewindRequest(messageID: messageID, expectedAgentSessionID: agentSessionID, files: files, dryRun: false))
        if let draft = response.draft, !draft.isEmpty { restoredDrafts.append(RestoredDraft(text: draft)) }
        skippedLinks = response.skippedLinks
    }

    func undoRewind(agentSessionID: String) async throws {
        _ = try await requireSource().undoRewindConversation(key.id, ConversationSessionGuard(expectedAgentSessionID: agentSessionID))
        skippedLinks = nil
    }

    func redoRewind(agentSessionID: String) async throws {
        _ = try await requireSource().redoRewindConversation(key.id, ConversationSessionGuard(expectedAgentSessionID: agentSessionID))
    }

    // MARK: 端末

    /// 会話の作業フォルダのシェル（生きていれば前と同じ pane）
    func shell() async throws -> PaneID {
        try await requireSource().conversationShell(key.id).pane
    }

    /// 会話のシェルの tab を閉じる（無ければ何もしない）
    func stopShell() async throws {
        try await requireSource().stopConversationShell(key.id)
    }

    // MARK: Run

    func startRun(code: String, language: String, messageID: String) async throws {
        let run = try await requireSource().startConversationRun(key.id, ConversationRunRequest(code: code, language: language, messageID: messageID))
        runs.started(run)
    }

    func cancelRun(_ id: String) async throws {
        try await requireSource().cancelConversationRun(key.id, run: id)
    }

    /// Run のシェルを全部閉じる（変数と作業フォルダの移動を捨てる）
    func resetRuns() async throws {
        try await requireSource().resetConversationRuns(key.id)
    }

    /// 動いている Run の出力を全部取り直す（購読し直したとき。切れていた間の続きは流れてこない）
    func refreshRunningRuns() {
        guard let source else { return }
        for entry in runs.entries where entry.status == .running {
            Task { [key] in
                if let run = try? await source.conversationRun(key.id, run: entry.id) { runs.replace(run) }
            }
        }
    }
}

/// daemon が返した開く先が、開いてよい URL（https と、127.0.0.1・localhost の http）でなかった
enum ElicitationLinkError: Error {
    case notOpenable
}
