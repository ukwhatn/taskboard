import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// 作業フォルダの追加・変更（`/add-dir`・`/cd`）。断られたら理由を出す（フォルダの信頼をアプリで与えない）
struct ConversationFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let action: ConversationFolderAction
    let conversation: Conversation
    let feed: ConversationFeed
    @State private var path: String
    @State private var running = false
    /// 断られた理由
    @State private var refusal: String?

    init(action: ConversationFolderAction, conversation: Conversation, feed: ConversationFeed, path: String, refusal: String? = nil) {
        self.action = action
        self.conversation = conversation
        self.feed = feed
        _path = State(initialValue: path)
        _refusal = State(initialValue: refusal)
    }

    var body: some View {
        SheetScaffold(title: ConversationReadoutText.folderTitle(action), subtitle: conversation.displayTitle, error: refusal) {
            Section {
                LabeledContent("今の作業フォルダ") { Text(verbatim: conversation.cwd).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
                LabeledTextField(label: String(localized: "フォルダ"), text: $path, monospaced: true)
                    .onSubmit { run() }
            } footer: {
                Text(action == .add ? "今の作業フォルダの下にあるフォルダのパスを入力してください。" : "移動先のフォルダのパスを入力してください。")
            }
        } actions: {
            Button("キャンセル") { dismiss() }
            Button(action == .add ? "追加" : "移動") { run() }
                .keyboardShortcut(.defaultAction)
                .disabled(running || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.phase == .stopped)
        }
    }

    private func run() {
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !running else { return }
        refusal = nil
        running = true
        Task {
            defer { running = false }
            switch action {
            case .add:
                do {
                    _ = try await feed.addDirectory(target)
                    dismiss()
                } catch {
                    refusal = ConversationReadoutText.addRefusal(error)
                }
            case .change:
                do {
                    let change = try await feed.changeDirectory(target)
                    if let refused = ConversationReadoutText.changeRefusal(change) { refusal = refused } else { dismiss() }
                } catch {
                    refusal = UserFacingError("作業フォルダを移動できませんでした", error: error)?.text
                }
            }
        }
    }
}

/// engine のアカウントのログイン（`/login`）。Claude は、会話の Mac ならブラウザで開くだけで終わり、ほかの端末はページに出たコードを貼る。
/// codex は、どの端末でも同じページを開き、シートに出したコード（`ConversationLogin.userCode`）をページで打ち込む
struct ConversationLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let feed: ConversationFeed
    let thisMac: Bool
    /// 会話のマシンの名前（同じ Mac は「このMac」）。ログインはそのマシンの Claude Code 全部に効く
    let machineName: String
    @State private var login: ConversationLogin?
    @State private var code = ""
    @State private var sending = false
    /// この画面で始めた流れの結果（会話の段階が待ちから変わったときだけ書く。前の流れの結果を拾わない）
    @State private var outcome: Conversation.LoginStage?
    @State private var failure: String?
    /// この画面で流れを始めた（始める要求の応答より先に終わりが届くことがあるので、ページを受け取る前から段階の変化を見る）
    @State private var started = false

    init(
        conversation: Conversation, feed: ConversationFeed, thisMac: Bool, machineName: String, login: ConversationLogin? = nil, code: String = "",
        outcome: Conversation.LoginStage? = nil, failure: String? = nil
    ) {
        self.conversation = conversation
        self.feed = feed
        self.thisMac = thisMac
        self.machineName = machineName
        _login = State(initialValue: login)
        _code = State(initialValue: code)
        _outcome = State(initialValue: outcome)
        _failure = State(initialValue: failure)
    }

    var body: some View {
        SheetScaffold(title: ConversationReadoutText.loginTitle(conversation.engine), subtitle: conversation.displayTitle, error: failure) {
            if outcome == .succeeded {
                Section {
                    Text("ログインしました。")
                } footer: {
                    Text("\(machineName)のすべてのセッションに効きます。")
                }
            } else if let login, outcome == nil {
                Section {
                    if let userCode = login.userCode {
                        Text("ログインのページを開き、次のコードを入力してください。終わると、ここに結果が表示されます。")
                        HStack(spacing: Space.row) {
                            Text(verbatim: userCode).font(.title2.monospaced()).textSelection(.enabled)
                            Spacer(minLength: Space.row)
                            Button("コピー") { Pasteboard.copy(userCode) }
                        }
                        Button("ログインのページを開く") { open(login.manualURL) }
                    } else if thisMac {
                        Text("ブラウザでログインしてください。終わると、ここに結果が表示されます。")
                        Button("ブラウザで開く") { open(login.automaticURL) }
                    } else {
                        Text("ログインのページでログインし、表示されたコードを貼り付けてください。")
                        Button("ログインのページを開く") { open(login.manualURL) }
                        LabeledTextField(label: String(localized: "コード"), text: $code, monospaced: true)
                            .onSubmit { send() }
                    }
                } footer: {
                    Text("\(machineName)のすべてのセッションに効きます。")
                }
            } else if failure == nil {
                Section { ProgressView("読み込み中…") }
            }
        } actions: {
            if outcome == .succeeded {
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("キャンセル") { dismiss() }
                if outcome == .failed || (login == nil && failure != nil) {
                    Button("やり直す") { start() }
                        .keyboardShortcut(.defaultAction)
                } else if !thisMac, login?.userCode == nil {
                    Button("ログイン") { send() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sending || login == nil || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task {
            if login == nil, failure == nil, outcome == nil { start() }
        }
        .onChange(of: conversation.login) { old, new in
            guard started, outcome == nil, old == .waiting, new != .waiting else { return }
            switch new {
            case .succeeded?:
                outcome = .succeeded
                failure = nil
            case nil:
                outcome = .failed
                failure = UserFacingError("ログインできませんでした", cause: String(localized: "会話が停止しました")).text
            default:
                outcome = .failed
                failure = UserFacingError("ログインできませんでした", remedy: String(localized: "もう一度やり直してください")).text
            }
        }
    }

    private func start() {
        login = nil
        outcome = nil
        failure = nil
        code = ""
        started = true
        Task {
            do {
                let pages = try await feed.startLogin()
                login = pages
                if thisMac, outcome == nil { open(pages.automaticURL) }
            } catch {
                failure = UserFacingError("ログインを始められませんでした", error: error)?.text
            }
        }
    }

    private func send() {
        let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, login != nil else { return }
        // ページのコードは「<code>#<state>」。欠けていれば送らない
        let parts = text.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            failure = UserFacingError("ログインできませんでした", cause: String(localized: "コードの一部が欠けています"), remedy: String(localized: "ページに表示されたコードをすべて貼り付けてください")).text
            return
        }
        failure = nil
        sending = true
        Task {
            defer { sending = false }
            do {
                try await feed.sendLoginCode(text)
            } catch {
                failure = UserFacingError("ログインできませんでした", error: error)?.text
            }
        }
    }

    private func open(_ link: String) {
        guard let page = OAuthLinks.openable(link) else { return }
        ExternalLinks.openInBrowser(page)
    }
}
