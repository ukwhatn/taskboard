import Foundation
import TaskboardKit

/// 読むだけのシート。CLI の TUI の画面の代わりにアプリが描く
enum ConversationReadout: String, Hashable, Sendable, CaseIterable {
    case export
    case permissions
    case hooks
    case memory
    case skills
    case plugins

    var kind: ConversationControlRequest.Kind {
        switch self {
        case .export: .exportConversation
        case .permissions: .permissionRules
        case .hooks: .hooks
        case .memory: .memory
        case .skills: .skills
        case .plugins: .plugins
        }
    }
}

/// 読むだけのシートの中身
enum ConversationReadoutValue: Sendable {
    case export(ConversationExport)
    case permissions(ConversationPermissionRules)
    case hooks(ConversationHooks)
    case memory(ConversationMemory)
    case skills(ConversationSkills)
    case plugins(ConversationPlugins)

    var readout: ConversationReadout {
        switch self {
        case .export: .export
        case .permissions: .permissions
        case .hooks: .hooks
        case .memory: .memory
        case .skills: .skills
        case .plugins: .plugins
        }
    }

    var debugName: String { readout.rawValue }
}

/// 止まった会話を読む画面のために起こす途中の状態
enum ConversationWake {
    case idle
    case waking
    case failed(UserFacingError)

    var isWaking: Bool {
        if case .waking = self { return true }
        return false
    }
}

/// 作業フォルダの操作（`/add-dir`・`/cd`）
enum ConversationFolderAction: String, Hashable, Sendable {
    case add
    case change
}

/// 読む画面とその場の操作（K4）。表示用のデータは `fixtureTools` から読み、作業フォルダの操作は「表示用のデータです」で断る
extension ConversationFeed {
    private func fetch<Value: Decodable>(_ request: ConversationControlRequest, as type: Value.Type) async throws -> Value {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        let response = try await source.controlConversation(key.id, request)
        return try WireJSON.decoder().decode(Value.self, from: Data((response.payloadJSON ?? "").utf8))
    }

    // MARK: 止まった会話を起こす

    /// 人が開いた読む画面の読み込み。止まった会話は起こしてから `load` を呼び、起こせなかったら `wake` に失敗を置いて呼ばない。
    /// 動いている会話と表示用のデータは起こさずに呼ぶ（会話を開いただけでは起こさない）
    func load(waking conversation: Conversation, then load: @escaping @MainActor () -> Void) {
        guard conversation.phase == .stopped, let source else {
            wake = .idle
            load()
            return
        }
        wake = .waking
        Task {
            do {
                _ = try await source.resumeConversation(key.id)
                wake = .idle
                load()
            } catch {
                wake = UserFacingError("会話を起動できませんでした", error: error).map(ConversationWake.failed) ?? .idle
            }
        }
    }

    // MARK: 読むだけのシート

    func loadReadout(_ readout: ConversationReadout) {
        if let fixtureTools {
            fixtureReadout(fixtureTools, readout).map { self.readout = .loaded($0) }
            return
        }
        guard source != nil else { return }
        if self.readout.value?.readout != readout { self.readout = .loading }
        Task {
            do {
                // 入れられる plugin は daemon が `value` の文字で絞る
                let request = ConversationControlRequest(kind: readout.kind, value: readout == .plugins ? pluginQuery : nil)
                let value: ConversationReadoutValue =
                    switch readout {
                    case .export: .export(try await fetch(request, as: ConversationExport.self))
                    case .permissions: .permissions(try await fetch(request, as: ConversationPermissionRules.self))
                    case .hooks: .hooks(try await fetch(request, as: ConversationHooks.self))
                    case .memory: .memory(try await fetch(request, as: ConversationMemory.self))
                    case .skills: .skills(try await fetch(request, as: ConversationSkills.self))
                    case .plugins: .plugins(try await fetch(request, as: ConversationPlugins.self))
                    }
                self.readout = .loaded(value)
            } catch {
                self.readout = UserFacingError(ConversationReadoutText.loadFailure(readout), error: error).map(ConversationLoad.failed) ?? .idle
            }
        }
    }

    private func fixtureReadout(_ tools: FixtureConversation, _ readout: ConversationReadout) -> ConversationReadoutValue? {
        switch readout {
        case .export: tools.export.map(ConversationReadoutValue.export)
        case .permissions: tools.permissionRules.map(ConversationReadoutValue.permissions)
        case .hooks: tools.hooks.map(ConversationReadoutValue.hooks)
        case .memory: tools.memory.map(ConversationReadoutValue.memory)
        case .skills: tools.skills.map(ConversationReadoutValue.skills)
        case .plugins:
            tools.plugins.map { plugins in
                let available = ConversationPlugins.filtered(plugins.available, query: pluginQuery)
                return .plugins(
                    ConversationPlugins(
                        installed: plugins.installed, available: available.plugins, availableTotal: available.total, marketplaces: plugins.marketplaces))
            }
        }
    }

    // MARK: 設定の書き込み

    /// 設定を書く（`edit_settings`）。書いたら読む画面を読み直す。CLI は書いたファイルを 3 秒ほどで読み直すので、すぐと 3 秒後の 2 回読む
    func editSettings(_ edit: ConversationSettingsEdit, reload readout: ConversationReadout) async throws -> ConversationSettingsEditResult {
        let result = try await fetch(ConversationControlRequest(kind: .editSettings, edit: edit), as: ConversationSettingsEditResult.self)
        let reload = { [weak self] in
            if case .sandbox = edit { self?.loadSandbox() } else { self?.loadReadout(readout) }
        }
        reload()
        Task {
            try? await Task.sleep(for: .seconds(3))
            reload()
        }
        return result
    }

    func loadSandbox() {
        if let fixtureTools {
            sandbox = fixtureTools.sandbox.map(ConversationLoad.loaded) ?? .idle
            return
        }
        guard source != nil else { return }
        if sandbox.value == nil { sandbox = .loading }
        Task {
            do {
                sandbox = .loaded(try await fetch(ConversationControlRequest(kind: .sandbox), as: ConversationSandbox.self))
            } catch {
                sandbox = UserFacingError("サンドボックスの設定を読み込めませんでした", error: error).map(ConversationLoad.failed) ?? sandbox
            }
        }
    }

    // MARK: バックグラウンドのタスク

    func loadBackgroundTasks() {
        if let fixtureTools {
            backgroundTasks = .loaded(fixtureTools.backgroundTasks ?? ConversationBackgroundTasks(tasks: []))
            return
        }
        guard source != nil else { return }
        if backgroundTasks.value == nil { backgroundTasks = .loading }
        Task {
            do {
                backgroundTasks = .loaded(try await fetch(ConversationControlRequest(kind: .listBackgroundTasks), as: ConversationBackgroundTasks.self))
            } catch {
                backgroundTasks =
                    UserFacingError("バックグラウンドのタスクを読み込めませんでした", error: error).map(ConversationLoad.failed) ?? backgroundTasks
            }
        }
    }

    func loadTaskOutput(_ id: String) {
        if let fixtureTools {
            taskOutputs[id] = fixtureTools.taskOutputs[id].map(ConversationLoad.loaded) ?? .idle
            return
        }
        guard source != nil else { return }
        if taskOutputs[id]?.value == nil { taskOutputs[id] = .loading }
        Task {
            do {
                taskOutputs[id] = .loaded(try await fetch(ConversationControlRequest(kind: .taskOutput, value: id), as: ConversationTaskOutput.self))
            } catch {
                taskOutputs[id] = UserFacingError("出力を読み込めませんでした", error: error).map(ConversationLoad.failed) ?? .idle
            }
        }
    }

    /// タスクを停止して、一覧と出力を取り直す
    func stopTask(_ id: String) async throws {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        _ = try await source.controlConversation(key.id, ConversationControlRequest(kind: .stopTask, value: id))
        loadBackgroundTasks()
        loadTaskOutput(id)
    }

    // MARK: 会話に残さない質問

    func askSide(_ question: String) async throws -> String {
        if let answer = fixtureTools?.sideAnswer { return answer.response }
        return try await fetch(ConversationControlRequest(kind: .sideQuestion, value: question), as: ConversationSideAnswer.self).response
    }

    // MARK: 作業フォルダ

    func addDirectory(_ path: String) async throws -> ConversationDirectoryAdded {
        try await fetch(ConversationControlRequest(kind: .addDirectory, value: path), as: ConversationDirectoryAdded.self)
    }

    func changeDirectory(_ path: String) async throws -> ConversationCwdChange {
        try await fetch(ConversationControlRequest(kind: .setCwd, value: path), as: ConversationCwdChange.self)
    }

    // MARK: ログイン

    /// ログインを始め、ログインのページを受け取る。終わりは会話の `login` で知る
    func startLogin() async throws -> ConversationLogin {
        try await fetch(ConversationControlRequest(kind: .login), as: ConversationLogin.self)
    }

    func sendLoginCode(_ code: String) async throws {
        guard let source else { throw AppModel.ActionError.notWritable(.readOnly) }
        _ = try await source.controlConversation(key.id, ConversationControlRequest(kind: .loginCode, code: code))
    }
}
