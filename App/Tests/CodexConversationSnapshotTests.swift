import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// Codex の会話の画面（fixtures `conversations` の c-codex）。巻き戻しは出さず、モデルと effort はマシンのモデルの一覧から出す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct CodexConversationSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func setup(models: Bool) async throws -> (AppModel, ConversationKey, ConversationFeed) {
        let model = try await ConversationSnapshotTests.loadedModel()
        let key = try ConversationSnapshotTests.key(model, "c-codex")
        // fixtures は会話の画面が開くと `fixtureExtras` から一覧を読むので、無い形はそれを空にして描く
        if models { await model.loadCodexModels(key.machine) } else { model.fixtureExtras.codex = nil }
        return (model, key, model.conversationFeed(for: key))
    }

    @Test("Codex の会話の画面（モデルの一覧がある・無い）", arguments: ["models", "nomodels"].flatMap { list in Matrix.cases([560]).map { "\(list)|\($0)" } })
    func conversation(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let (model, key, feed) = try await setup(models: parts[0] == "models")
        let view = ConversationView(key: key, feed: feed, revealedMenu: "u1").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 720), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("Codex の /m の候補（モデルとコネクタは欄で開く）", arguments: Matrix.cases([560]))
    func slash(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup(models: true)
        let view = ConversationView(key: key, feed: feed, draft: "/m").environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 720), variant: appearance), named: name)
    }

    @Test("Codex のコネクタのシート（有効と無効は、そのマシンのすべてのセッションに効く）", arguments: Matrix.cases([520]))
    func connectors(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup(models: true)
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadConnectors()
        let view = ConversationConnectorsSheet(conversation: conversation, feed: feed).background(.background).environment(model)
        // 全体で回すと、まれに検索欄が 1 pt 高く配置される（FieldGrowth）
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 640), variant: appearance), named: name, allowingFieldGrowth: true)
    }

    @Test("待機中のメッセージのカード（生成を停止して止まった待ち行列は［送信を再開］を出す。⌘↩ で送った発言は行の下に「応答が終わってから送信」）", arguments: ["paused", "waiting", "later"].flatMap { kind in Matrix.cases([560]).map { "\(kind)|\($0)" } })
    func queue(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        var timeline = ConversationTimeline()
        for (i, text) in ["テストの失敗の原因も書いてください", "直したら PR の説明も更新して"].enumerated() {
            timeline.addOutgoing(clientMessageID: "q\(i)", text: text, later: parts[0] == "later" && i == 1, at: BoardSnapshotTests.today)
            _ = timeline.apply(ConversationEvent(seq: i + 1, conversationID: "c-codex", at: BoardSnapshotTests.today, kind: .accepted(clientMessageID: "q\(i)", state: "queued")))
        }
        let view = ConversationQueueCard(
            messages: timeline.outgoing, fonts: ChatFonts(size: SessionTextSize.chatDefault),
            sendNow: { _ in ConversationSendNow(outcome: .delivering) }, detachesTools: false, cancel: { _, _ in true },
            paused: parts[0] == "paused", canSend: true, failed: { _ in }
        )
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 220), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    /// daemon が codex の子の thread から写す形（`subAgentActivity` の started の行。toolID と子の親は子の thread、id は子の thread で分ける）。開いた形
    @Test("Codex のサブエージェントの発言は、起こした行の下に Claude と同じ見た目で並ぶ", arguments: Matrix.cases([560]))
    func subagent(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let at = BoardSnapshotTests.today
        let messages = [
            ChatMessage(id: "u1", role: .user, kind: .text, text: "a.txt の中身を調べて", at: at),
            ChatMessage(id: "call-1", role: .assistant, kind: .toolUse, text: "/root/summarize_a", toolName: "Agent", toolID: "th-c", at: at),
            ChatMessage(id: "th-c/cmd-1", role: .assistant, kind: .toolUse, text: "cat a.txt", toolName: "Bash", toolID: "th-c/cmd-1", at: at, parentToolID: "th-c"),
            ChatMessage(id: "th-c/cmd-1-result", role: .user, kind: .toolResult, text: "検索の index を作り直す手順", toolID: "th-c/cmd-1", at: at, parentToolID: "th-c"),
            ChatMessage(id: "th-c/a-1", role: .assistant, kind: .text, text: "index を作り直す手順が書かれています。", at: at, parentToolID: "th-c"),
            ChatMessage(id: "subagent-completed-1", role: .user, kind: .toolResult, text: "completed", toolID: "th-c", at: at),
            ChatMessage(id: "a2", role: .assistant, kind: .text, text: "a.txt は検索の index を作り直す手順でした。", at: at),
        ]
        let view = ChatTranscript(messages: messages, expandedTools: ["th-c"])
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 520), variant: appearance), named: name)
    }

    @Test("Codex のモデルと effort の欄（隠すモデルは出さない）", arguments: ["model", "effort"].flatMap { field in Matrix.cases([360]).map { "\(field)|\($0)" } })
    func field(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let field = try #require(ConversationField(rawValue: parts[0]))
        let (model, key, feed) = try await setup(models: true)
        let conversation = try #require(model.fleet.conversation(for: key))
        let view = ConversationFieldPanel(field: field, conversation: conversation, feed: feed, options: model.modelOptions(for: conversation)) { _ in }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
            .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 320), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("起動のシートで Codex の会話を選んだ形（モデルの一覧がある・無い）", arguments: ["models", "nomodels"].flatMap { list in Matrix.cases([520]).map { "\(list)|\($0)" } })
    func launchSheet(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let (model, key, _) = try await setup(models: parts[0] == "models")
        let task = try #require(model.fleet.task(for: TaskKey(machine: key.machine, number: 118)))
        var draft = model.launchDraft(for: task)
        draft.choice.select(kind: .codex)
        draft.choice.select(codexModel: parts[0] == "models" ? "gpt-5.5-codex" : nil)
        draft.choice.select(codexEffort: parts[0] == "models" ? "high" : nil)
        let view = LaunchSheet(task: task, draft: draft).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 680), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test(
        "承認のカードの Codex の選択肢（要求が出した答えだけ。4 つが入らない幅は縦に並べる）",
        arguments: Matrix.cases([560]).map { "three|\($0)" } + Matrix.cases([360]).map { "four|\($0)" })
    func decisions(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let decisions: [ConversationDecision] = parts[0] == "three" ? [.accept, .acceptForSession, .cancel] : [.accept, .acceptForSession, .decline, .cancel]
        let waiting = RequestWaiting(id: "codex-0", since: Date(timeIntervalSince1970: 0), permission: .init(tool: "Bash", summary: "npm test -- search-index"))
        let request = ConversationRequest(id: "codex-0", kind: .permission, toolName: "Bash", toolUseID: "exec-1", waiting: waiting, decisions: decisions)
        let view = VStack {
            ConversationRequestPanel(
                request: request, machine: MachineID(rawValue: "fixture-studio"), blocked: nil, fetchURL: { _ in URL(fileURLWithPath: "/") },
                answer: { _ in })
            Spacer()
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 320), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test(
        "Codex の読む画面（権限の設定の層・信頼していないフックと無効のフックと、その有効と信頼の切り替え・config.toml のフックだけの編集と削除・skill の有効と無効・読めなかったファイル・プラグインのシート〔データごとのアンインストールは出さない〕）",
        arguments: [ConversationReadout.permissions, .hooks, .skills, .plugins].flatMap { readout in Matrix.cases([520]).map { "\(readout.rawValue)|\($0)" } })
    func readout(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let readout = try #require(ConversationReadout(rawValue: parts[0]))
        let (model, key, feed) = try await setup(models: true)
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadReadout(readout)
        let view = ConversationReadoutSheet(readout: readout, conversation: conversation, feed: feed).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 720), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("Codex の権限の設定の書き込み（ユーザーの設定の値・未設定・権限のモードが勝つ案内）", arguments: Matrix.cases([520]))
    func permissionsEdit(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup(models: true)
        let conversation = try #require(model.fleet.conversation(for: key))
        feed.loadReadout(.permissions)
        let notice = ConversationSettingsText.notice(ConversationSettingsEditResult(overriddenBy: "permission_mode"))
        let view = ConversationReadoutSheet(readout: .permissions, conversation: conversation, feed: feed, notice: notice).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    @Test("Codex のフックの追加のシート（種類と保存先は出さず、出来事は codex の一覧）", arguments: Matrix.cases([520]))
    func hookEditor(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, _, feed) = try await setup(models: true)
        let writer = ConversationSettingsWriter(feed: feed, readout: .hooks, engine: .codex) { _ in }
        var draft = ConversationHookEditor.Draft(engine: .codex)
        draft.event = "PermissionRequest"
        let view = ConversationHookEditor(draft: draft, writer: writer).background(.background).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 420), variant: appearance), named: name)
    }

    @Test("Codex のログインのシート（ページで打ち込むコードを出し、貼る欄は出さない）", arguments: Matrix.cases([520]))
    func login(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let (model, key, feed) = try await setup(models: true)
        let conversation = try #require(model.fleet.conversation(for: key))
        let login = ConversationLogin(manualURL: "https://auth.openai.com/codex/device", automaticURL: "https://auth.openai.com/codex/device", userCode: "ABCD-1234")
        let view = ConversationLoginSheet(conversation: conversation, feed: feed, thisMac: false, machineName: "Studio", login: login)
        assertImageSnapshot(
            of: BoardSnapshotTests.host(view.background(.background).environment(model), size: CGSize(width: width, height: 420), variant: appearance), named: name)
    }
}
