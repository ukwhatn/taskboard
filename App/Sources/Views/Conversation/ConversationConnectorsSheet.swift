import SwiftUI
import TaskboardKit

/// コネクタ（MCP の server）の管理。数十個並ぶことがあるので、接続できないものと有効なものだけを開いて並べ、無効と認証待ちは件数の見出しに畳む。
/// 有効と無効、認証の解除は確認なしで替える（もう一度押せば戻る）
struct ConversationConnectorsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let feed: ConversationFeed
    @State private var query = ""
    @State private var working: String?
    @State private var error: String?
    @State private var showsDisabled = false
    @State private var showsWaiting: Bool
    /// 認証のページを開いたコネクタ（名前 → 待ち方）
    @State private var authorizing: [String: ConnectorAuthorization]
    @State private var connectionWatch: Task<Void, Never>?
    /// ［認証］の応答を待っている間の Task。シートを閉じたら止め、閉じた後にブラウザを開かない
    @State private var authenticating: Task<Void, Never>?
    /// ほかの端末で認証の戻り先を受けている間の待ち受け（名前 → 待ち受け）
    @State private var catchers: [String: ConnectorCallbackCatcher] = [:]
    #if os(iOS)
    @State private var browsing: BrowserPage?
    #endif

    /// `showsWaiting`・`authorizing` は開いたときの形（snapshot test が認証の途中を描く）
    init(conversation: Conversation, feed: ConversationFeed, showsWaiting: Bool = false, authorizing: [String: ConnectorAuthorization] = [:]) {
        self.conversation = conversation
        self.feed = feed
        _showsWaiting = State(initialValue: showsWaiting)
        _authorizing = State(initialValue: authorizing)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "コネクタ"), subtitle: conversation.cwd, error: error) {
            ConversationWakeGate(conversation: conversation, feed: feed) { content }
        } actions: {
            Button("再読み込み") { load() }.disabled(working != nil || feed.wake.isWaking)
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        #if os(macOS)
        .frame(minHeight: ConversationMetrics.connectorsSheetHeight)
        #endif
        .onAppear { load() }
        .onDisappear {
            authenticating?.cancel()
            connectionWatch?.cancel()
            catchers.values.forEach { $0.stop() }
        }
        #if os(iOS)
        .sheet(item: $browsing) { page in
            SafariSheet(url: page.url) { browsing = nil }.ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch feed.connectors {
        case .idle, .loading:
            Section { ProgressView("読み込み中…").controlSize(.small) }
        case .failed(let failure):
            Section { Text(failure.text).foregroundStyle(.secondary) }
        case .loaded(let servers) where servers.isEmpty:
            Section { Text("コネクタはありません").foregroundStyle(.secondary) }
        case .loaded(let servers):
            let groups = ConnectorGroups(query.isEmpty ? servers : servers.filter { $0.name.localizedCaseInsensitiveContains(query) })
            Section {
                FormSearchField(query: $query)
            }
            if groups.isEmpty {
                Section { Text("条件に合うコネクタはありません").foregroundStyle(.secondary) }
            }
            if !groups.failed.isEmpty {
                Section("接続できません") { ForEach(groups.failed) { row($0) } }
            }
            if !groups.enabled.isEmpty {
                Section {
                    ForEach(groups.enabled) { row($0) }
                } header: {
                    Text("有効")
                } footer: {
                    // codex はユーザーの設定（config.toml）に書く
                    switch conversation.engine {
                    case .codex: Text("有効と無効は、\(model.machineName(conversation.machine))のすべてのセッションに効きます。")
                    default: Text("有効と無効は、この作業フォルダで動くすべてのセッションに効きます。")
                    }
                }
            }
            // 絞り込んでいる間は、当たったものが畳んだ組に隠れないように開く
            if !groups.disabled.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: query.isEmpty ? $showsDisabled : .constant(true)) {
                        ForEach(groups.disabled) { row($0) }
                    } label: {
                        Text("無効（\(groups.disabled.count)件）")
                    }
                }
            }
            if !groups.waiting.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: query.isEmpty ? $showsWaiting : .constant(true)) {
                        ForEach(groups.waiting) { row($0) }
                    } label: {
                        Text("認証待ち（\(groups.waiting.count)件）")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ server: ConversationMcpServer) -> some View {
        if server.status == "needs-auth", let authorization = authorizing[server.name] {
            VStack(alignment: .leading, spacing: Space.row) {
                line(server)
                ConnectorAuthorizationPanel(
                    authorization: Binding(get: { authorizing[server.name] ?? authorization }, set: { authorizing[server.name] = $0 }),
                    busy: working != nil, connect: { connect(server, authorizing[server.name] ?? authorization) })
            }
        } else {
            line(server)
        }
    }

    private func line(_ server: ConversationMcpServer) -> some View {
        let enabled = server.status != "disabled"
        let reconnectable = enabled && server.status != "needs-auth"
        return HStack(spacing: Space.row) {
            Image(systemName: ConversationChoices.connectorSymbol(server.status))
                .foregroundStyle(ConversationChoices.connectorColor(server.status))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: server.name).lineLimit(1).truncationMode(.middle)
                if let tools = server.toolCount, server.status == "connected" {
                    Text("ツール\(tools)個").font(.caption).foregroundStyle(.secondary)
                } else if server.status == "pending" {
                    Text(ConversationChoices.connectorLabel(server.status)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.row)
            if working == server.name {
                ProgressView().controlSize(.small)
            } else if server.status == "failed" {
                Button("再接続") { change(server, ConversationControlRequest(kind: .mcpReconnect, value: server.name)) }
                    .controlSize(.small)
            } else if server.status == "needs-auth" {
                Button("認証") { authenticate(server) }
                    .controlSize(.small)
                    .disabled(working != nil)
            }
            Toggle("有効", isOn: Binding(get: { enabled }, set: { on in
                change(server, ConversationControlRequest(kind: .mcpToggle, value: server.name, enabled: on))
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(working != nil)
            .accessibilityLabel("\(server.name)を有効にする")
        }
        .contextMenu {
            if reconnectable {
                Button("再接続") { change(server, ConversationControlRequest(kind: .mcpReconnect, value: server.name)) }.disabled(working != nil)
            }
            if server.status == "connected", ["http", "sse"].contains(server.transport ?? "") {
                Button("認証を解除") {
                    authorizing[server.name] = nil
                    change(server, ConversationControlRequest(kind: .mcpClearAuth, value: server.name))
                }
                .disabled(working != nil)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func load() {
        feed.load(waking: conversation) { feed.loadConnectors() }
    }

    private func authenticate(_ server: ConversationMcpServer) {
        working = server.name
        error = nil
        authenticating = Task {
            defer { working = nil }
            do {
                let authentication = try await feed.authenticateConnector(server.name)
                guard !Task.isCancelled else { return }
                guard authentication.requiresUserAction, let link = authentication.authURL else {
                    feed.loadConnectors()
                    return
                }
                guard let page = OAuthLinks.openable(link) else {
                    error = UserFacingError("認証のページを開けませんでした", remedy: String(localized: "ターミナルでClaude Codeを起動し、「/mcp」から認証してください")).text
                    return
                }
                let wait: ConnectorAuthorization.Wait =
                    !authentication.callbackExpected ? .reconnect : model.isThisMac(conversation.machine) ? .callback : .catching
                authorizing[server.name] = ConnectorAuthorization(page: page, wait: wait)
                switch wait {
                case .catching:
                    catchCallback(server, page: page)
                case .callback:
                    open(page, inApp: false)
                    connectionWatch?.cancel()
                    connectionWatch = Task { await feed.waitForConnection(server.name) }
                case .paste, .reconnect:
                    open(page, inApp: false)
                }
            } catch {
                self.error = UserFacingError("認証を始められませんでした", error: error)?.text
            }
        }
    }

    /// 認証のページの戻り先の port をこの端末で受け、受け始めてからページを開く（先に開くと、ログイン済みの認証がすぐ戻ってきて受け損ねる）。
    /// 受けたアドレスを CLI に渡す。受けられなければアドレスを貼る形に替える
    private func catchCallback(_ server: ConversationMcpServer, page: URL) {
        catchers[server.name]?.stop()
        var opened = false
        let fallback = {
            catchers[server.name] = nil
            authorizing[server.name]?.wait = .paste
            if !opened { open(page, inApp: false) }
        }
        guard let redirect = OAuthLinks.redirect(of: page),
            let catcher = ConnectorCallbackCatcher(
                redirect: redirect,
                ready: {
                    opened = true
                    open(page, inApp: true)
                },
                received: { url in
                    catchers[server.name] = nil
                    #if os(iOS)
                    browsing = nil
                    #endif
                    change(server, ConversationControlRequest(kind: .mcpOAuthCallback, value: server.name, callbackURL: url.absoluteString))
                },
                failed: fallback)
        else { return fallback() }
        catchers[server.name] = catcher
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

    private func connect(_ server: ConversationMcpServer, _ authorization: ConnectorAuthorization) {
        switch authorization.wait {
        case .paste:
            guard OAuthLinks.callback(authorization.address) != nil else {
                authorizing[server.name]?.invalid = true
                return
            }
            authorizing[server.name]?.invalid = false
            change(server, ConversationControlRequest(kind: .mcpOAuthCallback, value: server.name, callbackURL: authorization.address))
        case .callback, .catching, .reconnect:
            change(server, ConversationControlRequest(kind: .mcpReconnect, value: server.name))
        }
    }

    private func change(_ server: ConversationMcpServer, _ request: ConversationControlRequest) {
        working = server.name
        error = nil
        Task {
            do {
                try await feed.changeConnector(request)
            } catch {
                let event: LocalizedStringResource =
                    switch request.kind {
                    case .mcpReconnect: "再接続できませんでした"
                    case .mcpOAuthCallback: "接続できませんでした"
                    case .mcpClearAuth: "認証を解除できませんでした"
                    default: "コネクタを変更できませんでした"
                    }
                self.error = UserFacingError(event, error: error)?.text
            }
            working = nil
        }
    }
}

/// アプリの中の Safari で開くページ
struct BrowserPage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// 認証のページを開いたコネクタの待ち方
struct ConnectorAuthorization {
    enum Wait {
        /// この Mac の会話：CLI が戻り先のページを受けて自分で接続する。一覧を取り直して待つ
        case callback
        /// ほかの端末：戻り先はその端末の localhost なので、アプリが同じ port で受けて CLI に渡す
        case catching
        /// ほかの端末で戻り先を受けられないとき（port が使われている）：開いたページのアドレスを貼って CLI に渡す
        case paste
        /// 戻り先の無いコネクタ（claude.ai のコネクタ）：認証の後に接続し直す
        case reconnect
    }

    var page: URL
    var wait: Wait
    var address = ""
    var invalid = false

    /// 開いたページの scheme・host・port
    var origin: String {
        let port = page.port.map { ":\($0)" } ?? ""
        return "\(page.scheme ?? "")://\(page.host() ?? "")\(port)"
    }
}

/// コネクタを状態で分けた組。どれでもない状態（CLI が新しく足したもの）は有効に入れる
struct ConnectorGroups {
    let failed: [ConversationMcpServer]
    let enabled: [ConversationMcpServer]
    let disabled: [ConversationMcpServer]
    let waiting: [ConversationMcpServer]

    init(_ servers: [ConversationMcpServer]) {
        failed = servers.filter { $0.status == "failed" }
        disabled = servers.filter { $0.status == "disabled" }
        waiting = servers.filter { $0.status == "needs-auth" }
        enabled = servers.filter { !["failed", "disabled", "needs-auth"].contains($0.status) }
    }

    var isEmpty: Bool { failed.isEmpty && enabled.isEmpty && disabled.isEmpty && waiting.isEmpty }

    /// 詳細の欄に出す件数（0 件の組は出さない）
    var counts: [String] {
        [
            (enabled.count, String(localized: "有効\(enabled.count)件")), (failed.count, String(localized: "接続できません\(failed.count)件")),
            (disabled.count, String(localized: "無効\(disabled.count)件")), (waiting.count, String(localized: "認証待ち\(waiting.count)件")),
        ].filter { $0.0 > 0 }.map(\.1)
    }
}
