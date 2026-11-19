import SwiftUI
import TaskboardKit

/// 接続先のマシンの Codex の区画。アカウントとコネクタ（利用枠はマシンの見出しのバー）
struct CodexSection: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let title: String
    @State private var error: UserFacingError?
    /// codex の口が無い daemon
    @State private var unsupported = false
    /// 認証のページを開いたコネクタ（名前 → 待ち方）と、その認証の id
    @State private var authorizing: [String: ConnectorAuthorization]
    @State private var loginIDs: [String: String] = [:]
    /// ［認証］の応答・戻り先の送信を待っているコネクタ
    @State private var working: String?
    @State private var watches: [String: Task<Void, Never>] = [:]
    /// ［認証］の応答を待っている間の Task。画面を離れたら止め、離れた後にブラウザを開かない
    @State private var authenticating: Task<Void, Never>?
    /// ほかの端末で戻り先を受けている間の待ち受け
    @State private var catchers: [String: ConnectorCallbackCatcher] = [:]
    #if os(iOS)
    @State private var browsing: BrowserPage?
    #endif

    /// `authorizing` は開いたときの形（snapshot test が認証の途中を描く）
    init(fleetID: String, title: String, authorizing: [String: ConnectorAuthorization] = [:]) {
        self.fleetID = fleetID
        self.title = title
        _authorizing = State(initialValue: authorizing)
    }

    var body: some View {
        let state = model.fleet.allMachines[fleetID]
        let info = state?.codex
        Section {
            if let error {
                Banner(kind: .error, message: error.text) { self.error = nil }
            }
            if unsupported {
                Text("接続先のMacのTaskboardが古いため、Codexを表示できません。Taskboardを更新してください。").foregroundStyle(.secondary)
            } else if let info {
                if info.connected {
                    LabeledContent("アカウント", value: CodexLabels.account(info.account))
                    if info.account == nil || info.connectors == nil {
                        Text("\(model.machineName(fleetID: fleetID, state: state))のCodexが古いため、一部の項目を表示できません。Codexを更新してください。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Codexに接続できません。Codexをインストールしてから、この画面を開き直してください。").foregroundStyle(.secondary)
                }
            } else if error == nil {
                ProgressView("読み込み中…").controlSize(.small)
            }
        } header: {
            Text(verbatim: title)
        }
        .task {
            do {
                try await model.loadCodex(fleetID: fleetID)
            } catch let failure as SessionSourceError where failure.status == 404 {
                unsupported = true
            } catch {
                self.error = UserFacingError("Codexの情報を読み込めませんでした", error: error)
            }
        }
        if let connectors = info?.connectors, info?.connected == true, !unsupported {
            Section("コネクタ") {
                if connectors.isEmpty {
                    Text("コネクタはありません").foregroundStyle(.secondary)
                }
                ForEach(connectors) { row($0) }
            }
            .onDisappear(perform: stopWaiting)
            #if os(iOS)
            .sheet(item: $browsing) { page in
                SafariSheet(url: page.url) { browsing = nil }.ignoresSafeArea()
            }
            #endif
        }
    }

    @ViewBuilder
    private func row(_ connector: CodexMachineInfo.Connector) -> some View {
        if let authorization = authorizing[connector.name] {
            VStack(alignment: .leading, spacing: Space.row) {
                line(connector)
                ConnectorAuthorizationPanel(
                    authorization: Binding(get: { authorizing[connector.name] ?? authorization }, set: { authorizing[connector.name] = $0 }),
                    busy: working != nil, connect: { paste(connector.name) })
            }
        } else {
            line(connector)
        }
    }

    private func line(_ connector: CodexMachineInfo.Connector) -> some View {
        let status = CodexLabels.status(connector)
        return HStack(spacing: Space.row) {
            Image(systemName: ConversationChoices.connectorSymbol(status))
                .foregroundStyle(ConversationChoices.connectorColor(status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: connector.name).lineLimit(1).truncationMode(.middle)
                Text(CodexLabels.detail(connector, status: status)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.row)
            if working == connector.name {
                ProgressView().controlSize(.small)
            } else if CodexLabels.needsLogin(connector) {
                Button("認証") { authenticate(connector.name) }
                    .controlSize(.small)
                    .disabled(working != nil)
            } else if CodexLabels.canLogout(connector) {
                // 確かめは挟まない（認証し直せる。Claude の会話のコネクタの［認証を解除］と同じ）
                Button("認証を解除") { logout(connector.name) }
                    .controlSize(.small)
                    .disabled(working != nil)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func logout(_ name: String) {
        working = name
        error = nil
        Task {
            defer { working = nil }
            do {
                try await model.logoutCodexConnector(fleetID: fleetID, name: name)
            } catch {
                self.error = UserFacingError("認証を解除できませんでした", error: error)
            }
        }
    }

    // MARK: 認証（流れは Claude の会話のコネクタの認証と同じ。ConversationConnectorsSheet）

    private func authenticate(_ name: String) {
        working = name
        error = nil
        authenticating = Task {
            defer { working = nil }
            do {
                // 開始の要求は画面の取り消しで切らない（切ると daemon に待ちができたまま loginId を受け取れない）。離れていたら別の Task で取り消す
                let login = try await Task { [model, fleetID] in try await model.startCodexLogin(fleetID: fleetID, name: name) }.value
                guard !Task.isCancelled else {
                    Task { [model, fleetID] in await model.cancelCodexLogin(fleetID: fleetID, loginId: login.loginId) }
                    return
                }
                guard let page = OAuthLinks.openable(login.authorizationURL) else {
                    error = UserFacingError(
                        "認証のページを開けませんでした", remedy: String(localized: "ターミナルで「codex mcp login \(name)」を実行してください"))
                    return
                }
                stop(name)
                loginIDs[name] = login.loginId
                let redirect = OAuthLinks.redirect(of: page)
                let wait: ConnectorAuthorization.Wait = AppModel.isThisMac(fleetID: fleetID) || redirect == nil ? .callback : .catching
                authorizing[name] = ConnectorAuthorization(page: page, wait: wait)
                if let redirect, wait == .catching {
                    catchCallback(name, page: page, redirect: redirect)
                } else {
                    open(page, inApp: false)
                }
                watch(name, loginId: login.loginId)
            } catch {
                self.error = UserFacingError("認証を始められませんでした", error: error)
            }
        }
    }

    /// 戻り先の port をこの端末で受け、受け始めてからページを開く。受けたアドレスは daemon がそのマシンの上で開く。受けられなければ貼る形に替える
    private func catchCallback(_ name: String, page: URL, redirect: OAuthRedirect) {
        var opened = false
        let fallback = {
            catchers[name] = nil
            authorizing[name]?.wait = .paste
            if !opened { open(page, inApp: false) }
        }
        guard
            let catcher = ConnectorCallbackCatcher(
                redirect: redirect,
                ready: {
                    opened = true
                    open(page, inApp: true)
                },
                received: { url in
                    catchers[name] = nil
                    #if os(iOS)
                    browsing = nil
                    #endif
                    send(name, url.absoluteString)
                },
                failed: fallback)
        else { return fallback() }
        catchers[name] = catcher
    }

    private func paste(_ name: String) {
        guard let address = authorizing[name]?.address, OAuthLinks.callback(address) != nil else {
            authorizing[name]?.invalid = true
            return
        }
        authorizing[name]?.invalid = false
        send(name, address)
    }

    private func send(_ name: String, _ address: String) {
        guard let loginId = loginIDs[name] else { return }
        working = name
        error = nil
        Task {
            defer { working = nil }
            do {
                try await model.sendCodexCallback(fleetID: fleetID, loginId: loginId, url: address)
            } catch {
                self.error = UserFacingError("接続できませんでした", error: error)
            }
        }
    }

    /// 認証が終わるまで待ち、終わったら案内を閉じる。失敗は区画の上に出す
    private func watch(_ name: String, loginId: String) {
        watches[name] = Task {
            let state = await model.waitForCodexLogin(fleetID: fleetID, loginId: loginId)
            guard !Task.isCancelled else { return }
            stop(name)
            authorizing[name] = nil
            loginIDs[name] = nil
            if state != .succeeded {
                error = UserFacingError("「\(name)」を認証できませんでした", remedy: String(localized: "もう一度［認証］を押してください"))
            }
        }
    }

    private func stop(_ name: String) {
        catchers[name]?.stop()
        catchers[name] = nil
        watches[name]?.cancel()
        watches[name] = nil
    }

    /// 画面を離れたら待ち受けをやめ、daemon の待ちも消す（それより後の戻り先は開かない）
    private func stopWaiting() {
        authenticating?.cancel()
        authenticating = nil
        for name in Set(catchers.keys).union(watches.keys) { stop(name) }
        for loginId in loginIDs.values { Task { [model, fleetID] in await model.cancelCodexLogin(fleetID: fleetID, loginId: loginId) } }
        loginIDs = [:]
        authorizing = [:]
    }

    /// iPhone・iPad で戻り先を受けるときは、アプリの中の Safari で開く（Safari のアプリに移るとアプリが止まり、戻り先を受けられない）
    private func open(_ page: URL, inApp: Bool) {
        #if os(iOS)
        if inApp {
            browsing = BrowserPage(url: page)
            return
        }
        #endif
        ExternalLinks.openInBrowser(page)
    }
}

/// codex の値の画面の文。コネクタの状態は Claude のコネクタと同じ語と印（`ConversationChoices`）にそろえる
enum CodexLabels {
    static func account(_ account: CodexMachineInfo.Account?) -> String {
        guard let account else { return "" }
        switch account.kind {
        case nil: return String(localized: "ログインしていません")
        case "apiKey": return String(localized: "APIキー")
        case "amazonBedrock": return "Amazon Bedrock"
        case "chatgpt": return ["ChatGPT", plan(account.planType)].compactMap { $0 }.joined(separator: " ")
        case let other?: return other
        }
    }

    /// プランの値（`enterprise_cbp_usage_based` など）は codex の識別子なので、契約の名前に丸める。当たらなければ出さない
    static func plan(_ value: String?) -> String? {
        guard let value else { return nil }
        let names: [(prefix: String, name: String)] = [
            ("enterprise", "Enterprise"), ("ent", "Enterprise"), ("edu", "Edu"), ("self_serve_business", "Business"), ("business", "Business"),
            ("team", "Team"), ("pro", "Pro"), ("plus", "Plus"), ("go", "Go"), ("free", "Free"),
        ]
        return names.first { value.hasPrefix($0.prefix) }?.name
    }

    /// `ConversationChoices` の状態の語（connected・failed・needs-auth・pending・disabled）に読み替える。
    /// thread の無い接続では `runtimeStatus` が無いので、ツールを読めたかで決める
    static func status(_ connector: CodexMachineInfo.Connector) -> String {
        if connector.toolsError { return "failed" }
        switch connector.runtimeStatus {
        case "authenticationRequired": return "needs-auth"
        case "failed", "cancelled": return "failed"
        case "disabled": return "disabled"
        case "starting", "notStarted": return "pending"
        default: return "connected"
        }
    }

    /// ［認証］を出すコネクタ。OAuth で認証できて、まだしていないもの
    static func needsLogin(_ connector: CodexMachineInfo.Connector) -> Bool {
        connector.authStatus == "notLoggedIn" || connector.runtimeStatus == "authenticationRequired"
    }

    /// ［認証を解除］を出すコネクタ。OAuth で認証済みのもの（`codex mcp logout` は OAuth のコネクタだけ受ける）
    static func canLogout(_ connector: CodexMachineInfo.Connector) -> Bool {
        connector.authStatus == "oAuth" && !needsLogin(connector)
    }

    static func detail(_ connector: CodexMachineInfo.Connector, status: String) -> String {
        guard status == "connected" else { return ConversationChoices.connectorLabel(status) }
        let tools = String(localized: "ツール\(connector.toolCount)個")
        return connector.authStatus == "notLoggedIn" ? tools + "・" + String(localized: "未ログイン") : tools
    }
}
