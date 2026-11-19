import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の画面の E3・E4 の欄（fixtures `conversations` の `c-tools`・`c-rewind`・`c-limit`）。上の帯・入力欄の下の欄・Run の出力・巻き戻しの帯、
/// `/` の候補、発言のメニュー、巻き戻しの確認、圧縮した所の区切り、欄の中身、差分の画面、コンテキストの内訳、ファイルを戻せたか分からない帯、利用枠の上限の帯、タスクのパネルの詳細の欄の「会話」
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ConversationToolsSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func setup(_ id: String) async throws -> (AppModel, ConversationKey, ConversationFeed) {
        let model = try await ConversationSnapshotTests.loadedModel()
        let key = try ConversationSnapshotTests.key(model, id)
        return (model, key, model.conversationFeed(for: key))
    }

    @Test("上の帯・入力欄の下の欄・Run の出力・巻き戻しの帯", arguments: Matrix.cases([420, 760]))
    func tools(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let view = ConversationView(key: key, feed: feed).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("/ の候補（CLI のコマンド・alias で引いたもの・taskboard の操作）", arguments: Matrix.cases([560]))
    func slash(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let view = ConversationView(key: key, feed: feed, draft: "/re").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("文の途中の / の候補（CLI に送る skill と command だけ。組み込みと taskboard の操作は出さない）", arguments: Matrix.cases([560]))
    func slashMidText(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let view = ConversationView(key: key, feed: feed, draft: "この差分を /re").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test("発言のメニューのボタン（ホバーした指示）", arguments: Matrix.cases([560]))
    func messageMenu(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let view = ConversationView(key: key, feed: feed, revealedMenu: "u12").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    @Test(
        "巻き戻しの確認（ファイルも戻せる・戻せない・確かめられない）",
        arguments: ["files", "nofiles", "failed"].flatMap { kind in Matrix.cases([520]).map { "\(kind)|\($0)" } })
    func rewind(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        let message = try #require(feed.messages.last { $0.isRewindTarget })
        let fixture = try #require(model.fixtureExtras.conversations["c-tools"]?.rewind)
        let preview: ConversationLoad<ConversationRewindResponse> =
            switch parts[0] {
            case "files": .loaded(fixture)
            case "nofiles": .loaded(ConversationRewindResponse(canRewind: false, error: "No file checkpoint found for this message."))
            default: .failed(UserFacingError("ファイルの変更を確認できませんでした", cause: "接続先のMacとの接続が切れています"))
            }
        let view = ConversationRewindSheet(message: message, conversation: conversation, feed: feed, preview: preview).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 560), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test(
        "入力欄の下の欄の中身（モデル・effort・権限）",
        arguments: ConversationField.allCases.flatMap { field in Matrix.cases([360]).map { "\(field.rawValue)|\($0)" } })
    func field(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let field = try #require(ConversationField(rawValue: parts[0]))
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        let view = ConversationFieldPanel(field: field, conversation: conversation, feed: feed, options: model.modelOptions(for: conversation)) { _ in }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
            .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 420), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("コネクタのシート（接続できない・有効・畳んだ無効と認証待ち）", arguments: Matrix.cases([520]))
    func connectors(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadConnectors()
        let view = ConversationConnectorsSheet(conversation: conversation, feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }

    @Test("コネクタの認証の途中（アドレスを貼る欄と入力の誤り、claude.ai のコネクタの［接続］）", arguments: Matrix.cases([520]))
    func connectorsAuthorizing(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadConnectors()
        let page = try #require(URL(string: "https://auth.example.com/authorize?state=s"))
        let view = ConversationConnectorsSheet(
            conversation: conversation, feed: feed, showsWaiting: true,
            authorizing: [
                "atlassian-http": ConnectorAuthorization(page: page, wait: .paste, address: "http://localhost:53123/callback?code=a", invalid: true),
                "claude.ai Asana": ConnectorAuthorization(page: try #require(URL(string: "https://claude.ai/settings/connectors")), wait: .reconnect),
            ]
        ).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    @Test("コンテキストの内訳のシート（合計・使用中・使うときに読み込むもの・空き）", arguments: Matrix.cases([520]))
    func contextBreakdown(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadContextBreakdown()
        let view = ConversationContextSheet(conversation: conversation, feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }

    @Test("差分の画面（並べた形と、狭い幅で一覧から移った形）", arguments: Matrix.cases([390, 900]))
    func diff(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, _, feed) = try await setup("c-tools")
        feed.loadDiff()
        let view = ConversationDiffScreen(feed: feed, selection: "App/Sources/Views/Conversation/ConversationView.swift")
            .background(.background)
            .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 600), variant: appearance), named: name)
    }

    @Test("差分の画面の一覧（狭い幅で選ぶ前）", arguments: Matrix.cases([390]))
    func diffList(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, _, feed) = try await setup("c-tools")
        feed.loadDiff()
        let view = ConversationDiffScreen(feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 600), variant: appearance), named: name)
    }

    @Test("差分の画面のブランチ全体（比べたブランチを見出しに出す）", arguments: Matrix.cases([900]))
    func diffBranch(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, _, feed) = try await setup("c-tools")
        feed.setDiffScope(.branch)
        let view = ConversationDiffScreen(feed: feed, selection: "App/Sources/Views/Conversation/ConversationView.swift")
            .background(.background)
            .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 600), variant: appearance), named: name)
    }

    @Test("差分の行のコメント（付けた行の印）", arguments: Matrix.cases([560]))
    func diffComment(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, _, feed) = try await setup("c-tools")
        let path = "App/Sources/Views/Conversation/ConversationView.swift"
        feed.loadFileDiff(path)
        let file = try #require(feed.fileDiffs[path]?.value)
        let changes = ChatDiffRow.rows(ChatDiffHunk.parse(unified: file.diff)).map { row -> ChatDiffRow.Change? in
            if case .line(_, let change, _, _, _) = row { return change }
            return nil
        }
        let removed = try #require(changes.firstIndex(of: .removed))
        let added = try #require(changes.firstIndex(of: .added))
        let view = ConversationFileDiffView(
            file: file, fonts: ChatFonts(size: SessionTextSize.chatDefault), commented: [removed, added]
        ) { _ in }
        .background(.background)
        .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 420), variant: appearance), named: name)
    }

    @Test("巻き戻しでファイルを戻せたか分からない会話の帯", arguments: Matrix.cases([560]))
    func rewindIncomplete(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-rewind")
        let view = ConversationView(key: key, feed: feed).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 700), variant: appearance), named: name)
    }

    /// c-rewind に、圧縮より前の発言と圧縮の印を古いページとして足す（transcript の写し元から読んだ形）
    private func compacted() async throws -> (AppModel, ConversationKey, ConversationFeed) {
        let (model, key, feed) = try await setup("c-rewind")
        let conversation = try #require(model.fleet.conversation(for: key))
        let at = try #require(feed.messages.first?.at).addingTimeInterval(-600)
        // 古いページの会話 ID が手元と違うと、手元を捨てる（fixtures の手元は会話の記録と別の ID を持つことがある）
        let session = feed.debugTimeline.agentSessionID ?? conversation.agentSessionID
        feed.mergeOlderPage(ConversationHistoryResponse(
            messages: [
                ChatMessage(id: "u20", role: .user, kind: .text, text: "テストを足して", at: at),
                ChatMessage(id: "a20#0", role: .assistant, kind: .text, text: "テストを 4 件足しました。", at: at.addingTimeInterval(60)),
                ChatMessage(id: "c20", role: .user, kind: .notice, text: "会話を圧縮しました", at: at.addingTimeInterval(120), compactSummary: true),
            ],
            nextCursor: nil, agentSessionID: session))
        #expect(feed.messages.map(\.id) == ["u20", "a20#0", "c20", "u30", "a30#0"])
        return (model, key, feed)
    }

    @Test("圧縮した所の区切りと、圧縮より前の発言の操作（巻き戻しを出さず、コピーとフォークだけ）", arguments: Matrix.cases([560]))
    func compactedHistory(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await compacted()
        let view = ConversationView(key: key, feed: feed, revealedMenu: "u20").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 700), variant: appearance), named: name)
    }

    @Test("圧縮した会話の巻き戻しの確認（戻せる範囲の文）", arguments: Matrix.cases([520]))
    func rewindCompacted(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await compacted()
        let conversation = try #require(model.fleet.conversation(for: key))
        let message = try #require(ChatRewindRange.last(in: feed.messages))
        let first = try #require(feed.messages.first)
        #expect(message.id == "u30" && first.id == "u20" && !ChatRewindRange(feed.messages).allows(first))
        let preview: ConversationLoad<ConversationRewindResponse> = .loaded(ConversationRewindResponse(canRewind: true, filesChanged: []))
        let view = ConversationRewindSheet(message: message, conversation: conversation, feed: feed, preview: preview).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 560), variant: appearance), named: name)
    }

    @Test("利用枠の上限で、戻ったら続きを送る会話の帯", arguments: Matrix.cases([560]))
    func usageLimitWait(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-limit")
        let view = ConversationView(key: key, feed: feed).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 700), variant: appearance), named: name)
    }

    @Test("タスクのパネルの詳細の欄の「会話」", arguments: Matrix.cases([1180]))
    func inspector(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, _) = try await setup("c-tools")
        AppDefaults.store.set(SidePanelSet(open: [.status]).json, forKey: AppPreferences.taskSidePanelsKey)
        model.navigate(to: .conversation(key), from: .debug)
        let view = TaskPanel(key: TaskKey(machine: key.machine, number: 137)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    /// 上は委譲先（c-helper）とフォーク（c-term）を持つ会話、下はそのフォーク
    @Test("会話の［状態］の委譲先・フォーク元・フォーク", arguments: Matrix.cases([360]))
    func inspectorForks(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let fork = try ConversationSnapshotTests.key(model, "c-term")
        let source = try #require(model.fleet.conversation(for: key))
        let forked = try #require(model.fleet.conversation(for: fork))
        let view = VStack(alignment: .leading, spacing: Space.section) {
            ConversationInspector(conversation: source, feed: feed)
            Divider()
            ConversationInspector(conversation: forked, feed: model.conversationFeed(for: fork))
        }
        .environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    /// 5 つの欄を全部開き、右側を 680 に広げる（2 列。左に状態・文書・作業項目、右に差分・端末）。端末の欄はシェルを起こせなかったところ（fixtures は書き込めない）
    @Test("タスクのパネルの右側の欄の格子", arguments: Matrix.cases([1180, 1440, 1728]))
    func sidePanels(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, _) = try await setup("c-tools")
        AppDefaults.store.set(SidePanelSet(open: [.status, .docs, .work, .changes]).json, forKey: AppPreferences.taskSidePanelsKey)
        model.terminalDocks[key] = .failed(UserFacingError("シェルを起動できませんでした", remedy: UserFacingError.retry))
        AppDefaults.store.set(680.0, forKey: AppPreferences.taskSideWidthKey)
        model.navigate(to: .conversation(key), from: .debug)
        let view = TaskPanel(key: TaskKey(machine: key.machine, number: 137)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: name)
    }

    /// 札で c-tools を選んでから、c-gen を ⌘ を押しながら押したのと同じく右に並べる（左は右の欄があるので端末と［状態］をそちらに出し、右は自分の上の帯に出す）
    @Test("タスクのパネルに会話を 2 つ並べる", arguments: Matrix.cases([1440]))
    func splitConversations(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, _) = try await setup("c-tools")
        model.navigate(to: .conversation(key), from: .debug)
        let task = TaskKey(machine: key.machine, number: 137)
        let host = BoardSnapshotTests.host(TaskPanel(key: task).environment(model).pageInsets(), size: CGSize(width: width, height: 900), variant: appearance)
        model.sessionFocus = SessionFocus(scope: .task(task), item: try ConversationSnapshotTests.key(model, "c-gen"), beside: true)
        LayoutMatrixSnapshotTests.settle(host)
        #expect(model.sessionFocus == nil)
        assertImageSnapshot(of: host, named: name)
    }

    @Test("読むだけのシート（書き出し・権限の規則・フック・メモリ・スキル・プラグイン）", arguments: ConversationReadout.allCases.flatMap { readout in Matrix.cases([520]).map { "\(readout.rawValue)|\($0)" } })
    func readout(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let readout = try #require(ConversationReadout(rawValue: parts[0]))
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadReadout(readout)
        let view = ConversationReadoutSheet(readout: readout, conversation: conversation, feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test(
        "プラグインのシートの確かめ（コマンドでのインストール・保存した設定が消えるアンインストール・plugin も外れるマーケットプレイスの削除）",
        arguments: ["command", "options", "marketplace"].flatMap { review in Matrix.cases([520]).map { "\(review)|\($0)" } })
    func pluginReview(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadReadout(.plugins)
        let review: ConversationPluginReview? =
            switch parts[0] {
            case "command":
                ConversationPluginReview(
                    edit: .plugin(op: .install, id: "pr-helper@team-tools", scope: .user),
                    result: ConversationSettingsEditResult(shownCommand: .init(command: "npx -y @team/pr-helper@2.0.1 install", sha256: "fe01")),
                    event: "プラグインをインストールできませんでした")
            case "options":
                ConversationPluginReview(
                    edit: .plugin(op: .uninstall, id: "lint-hooks@team-tools", scope: .project),
                    result: ConversationSettingsEditResult(
                        confirmation: .init(loss: .options, plugins: [.init(id: "lint-hooks@team-tools", scope: "project")], options: ["apiKey", "endpoint"], digest: "d1")),
                    event: "プラグインをアンインストールできませんでした")
            default:
                ConversationPluginReview(
                    edit: .marketplace(op: .remove, name: "team-tools"),
                    result: ConversationSettingsEditResult(
                        confirmation: .init(loss: .options, plugins: [.init(id: "lint-hooks@team-tools", scope: "project")], options: ["apiKey"], digest: "d2")),
                    event: "マーケットプレイスを削除できませんでした")
            }
        let view = ConversationReadoutSheet(readout: .plugins, conversation: conversation, feed: feed, pluginReview: review).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("バックグラウンドのタスクのシート（一覧と、選んだタスクの出力と［停止］）", arguments: Matrix.cases([520]))
    func backgroundTasks(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadBackgroundTasks()
        feed.loadTaskOutput("bj8iibuj6")
        let view = ConversationTasksSheet(conversation: conversation, feed: feed, selected: "bj8iibuj6").background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name)
    }

    @Test("会話に残さない質問のシート（回答あり）", arguments: Matrix.cases([520]))
    func sideQuestion(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        let answer = try #require(model.fixtureExtras.conversations["c-tools"]?.sideAnswer?.response)
        let view = ConversationSideQuestionSheet(conversation: conversation, feed: feed, question: "今どこまで進んだ？", answer: answer)
            .background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 480), variant: appearance), named: name)
    }

    @Test(
        "作業フォルダのシート（追加を断られた・信頼されていないフォルダへの移動）",
        arguments: ["add", "change"].flatMap { action in Matrix.cases([520]).map { "\(action)|\($0)" } })
    func folder(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let action = try #require(ConversationFolderAction(rawValue: parts[0]))
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        let refusal =
            action == .add
            ? ConversationReadoutText.addRefusal(SessionSourceError.httpStatus(500))
            : ConversationReadoutText.changeRefusal(ConversationCwdChange(outcome: .needsTrust, directory: "/Users/me/dev/other"))
        let view = ConversationFolderSheet(
            action: action, conversation: conversation, feed: feed, path: action == .add ? "/etc" : "~/dev/other", refusal: refusal
        ).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 480), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test(
        "ログインのシート（このMacで待っている・ほかの端末でコードを貼る・ログインした・ログインできなかった）",
        arguments: ["mac", "remote", "succeeded", "failed"].flatMap { state in Matrix.cases([520]).map { "\(state)|\($0)" } })
    func login(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        let login = ConversationLogin(manualURL: "https://claude.com/cai/oauth/authorize?state=s1", automaticURL: "https://claude.com/cai/oauth/authorize?state=s1")
        let view: ConversationLoginSheet =
            switch parts[0] {
            case "mac": ConversationLoginSheet(conversation: conversation, feed: feed, thisMac: true, machineName: "このMac", login: login)
            case "remote":
                ConversationLoginSheet(conversation: conversation, feed: feed, thisMac: false, machineName: "Studio", login: login, code: "a1b2c3d4e5#s1")
            case "succeeded": ConversationLoginSheet(conversation: conversation, feed: feed, thisMac: false, machineName: "Studio", login: login, outcome: .succeeded)
            default:
                ConversationLoginSheet(
                    conversation: conversation, feed: feed, thisMac: false, machineName: "Studio", login: login, outcome: .failed,
                    failure: UserFacingError("ログインできませんでした", remedy: String(localized: "もう一度やり直してください")).text)
            }
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view.background(.background).environment(model), size: CGSize(width: width, height: 420), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("フックの編集のシート（読む画面の行から開く）", arguments: Matrix.cases([520]))
    func hookEditor(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let hook = try #require(model.fixtureExtras.conversations["c-tools"]?.hooks?.hooks.first)
        let writer = ConversationSettingsWriter(feed: feed, readout: .hooks, engine: .claude) { _ in }
        let view = ConversationHookEditor(draft: ConversationHookEditor.Draft(hook, engine: .claude), writer: writer).background(.background).environment(model)
        _ = key
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 520), variant: appearance), named: name)
    }

    @Test("権限の規則のシートの書き込み（外せる規則の［削除］・規則の追加・sandbox）", arguments: Matrix.cases([520]))
    func permissionsEdit(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup("c-tools")
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadReadout(.permissions)
        feed.loadSandbox()
        let view = ConversationReadoutSheet(readout: .permissions, conversation: conversation, feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1300), variant: appearance), named: name)
    }
}
