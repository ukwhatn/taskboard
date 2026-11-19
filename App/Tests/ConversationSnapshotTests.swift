import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// host の会話の画面（fixtures `conversations`）。生成中・待機中・送れなかった発言、質問・権限・計画の問い、止まっている会話を、外観を変えて描く
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ConversationSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    static func loadedModel() async throws -> AppModel {
        AppDefaults.useScratch("snapshot-conversation")
        let model = AppModel(options: LaunchOptions(scenario: "conversations"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.allBoards.isEmpty || model.fleet.allMachines.values.allSatisfy({ $0.conversations.isEmpty }) {
            try #require(ContinuousClock.now < deadline, "fixtures conversations を読み込めない: \(model.connectionNote ?? "-")")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    static func key(_ model: AppModel, _ id: String) throws -> ConversationKey {
        let machine = try #require(model.fleet.allBoards.first?.machine)
        let key = ConversationKey(machine: machine, id: id)
        try #require(model.fleet.conversation(for: key) != nil, "fixtures に会話 \(id) が無い")
        return key
    }

    @Test(
        "会話の画面（生成中と待機中・送れなかった発言、質問、権限、計画、止まった会話と起こせなかった会話、圧縮中、応答が止まった、送り直している（残りの秒の出る間と過ぎた後）、API の誤りで終わった、ネットワークが戻ったら続ける）",
        arguments: ["c-gen", "c-ask", "c-perm", "c-plan", "c-stop", "c-failed", "c-compact", "c-stall", "c-retry", "c-retry-late", "c-apierror", "c-offline"].flatMap { id in Matrix.cases([560]).map { "\(id)|\($0)" } })
    func conversation(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let model = try await Self.loadedModel()
        let key = try Self.key(model, parts[0])
        let feed = model.conversationFeed(for: key)
        try #require(!feed.isEmpty, "fixtures の会話 \(parts[0]) に発言が無い")
        let view = ConversationView(key: key, feed: feed).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 820), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    /// 末尾の様子の行。iPhone・iPad の SwiftUI の行（1 枚に並べる）と、Mac の一覧の行
    static let activityNow = BoardSnapshotTests.today
    static let activities: [ConversationActivity] = [
        .apiRetry(ConversationAPIRetry(attempt: 3, maxRetries: 10, retryAt: activityNow.addingTimeInterval(12), kind: "unknown")),
        .apiRetry(ConversationAPIRetry(attempt: 4, maxRetries: 10, retryAt: activityNow.addingTimeInterval(-3), status: 529, kind: "overloaded")),
        .apiRetry(ConversationAPIRetry(attempt: 2, maxRetries: 10, retryAt: activityNow.addingTimeInterval(65), status: 429, kind: "rate_limit")),
        .apiRetry(ConversationAPIRetry(attempt: 1, retryAt: activityNow.addingTimeInterval(5), status: nil, kind: "cloud_credential_error")),
    ]

    @Test("ToDo のカード（畳むと見出しに進行中の項目、開くと項目ごとの状態。済んだ項目は打ち消し線）", arguments: ["closed", "open"].flatMap { kind in Matrix.cases([560]).map { "\(kind)|\($0)" } })
    func plan(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let items = [
            ConversationPlanItem(id: "1", title: "失敗しているテストの原因を調べる", status: .completed),
            ConversationPlanItem(id: "2", title: "ConversationService の再接続を直す", activeTitle: "再接続を直しています", status: .inProgress),
            ConversationPlanItem(id: "3", title: "swift test と snapshot を通す", status: .pending),
        ]
        let view = ConversationPlanCard(items: items, fonts: ChatFonts(size: SessionTextSize.chatDefault), open: parts[0] == "open")
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 200), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("末尾の様子の行（iPhone・iPad の SwiftUI の行）：応答を待っている、生成している、送り直し（つながらない・混み合い・利用枠・認証情報、残りの秒の出る間と過ぎた後）", arguments: Matrix.cases([390, 560]))
    func activityRowsSwiftUI(name: String) throws {
        let (width, appearance) = try Matrix.parse(name)
        let fonts = ChatFonts(size: SessionTextSize.chatDefault)
        let view = VStack(alignment: .leading, spacing: Space.block) {
            ForEach(Array(Self.activities.enumerated()), id: \.offset) { _, activity in
                ConversationActivityRow(activity: activity, fonts: fonts)
            }
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 360), variant: appearance), named: name)
    }

    @Test("末尾の様子の行（Mac の一覧）：応答を待っている", arguments: Matrix.cases([560]))
    func activityRowMac(name: String) throws {
        let (width, appearance) = try Matrix.parse(name)
        AppDefaults.useScratch("snapshot-conversation")
        let messages = [
            ChatMessage(id: "u1", role: .user, kind: .text, text: "ビルドして結果を教えて"),
            ChatMessage(id: "a1", role: .assistant, kind: .text, text: "ビルドします。"),
        ]
        let view = ChatTranscript(messages: messages, activity: Self.activities[0]).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 300), variant: appearance), named: name)
    }

    @Test("会話のメニューと上の帯の項目は［終了］だけで、［停止］は無い（動いている・止まった・タスクに結ばれていない会話）", arguments: Matrix.cases([360]))
    func menuItems(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let conversations = try ["c-gen", "c-stop", "c-limit"].map { try #require(model.fleet.conversation(for: try Self.key(model, $0))) }
        let view = VStack(alignment: .leading, spacing: Space.row) {
            ForEach(conversations) { conversation in
                Text(conversation.displayTitle).textRole(.caption)
                ConversationMenuItems(conversation: conversation)
            }
        }
        .padding(Space.section)
        .environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 360), variant: appearance), named: name)
    }

    @Test("札のある会話（読んだ画像・読んだ文・Edit・Write の新規、人が添えた画像の縮小版とファイルの札）と、広い幅で札の画像を右の欄に開いた形", arguments: Matrix.cases([560, 1100]))
    func files(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let key = try Self.key(model, "c-files")
        let feed = model.conversationFeed(for: key)
        try Self.presetSentImages(feed, model)
        let image = try ChatFilesSnapshotTests.ref(feed.messages, "cr1")
        var open: ChatFileRef?
        if width > 1000 {
            feed.files.preset(image, .loaded(.image(ChatFilesSnapshotTests.png(NSColor.systemTeal, CGSize(width: 360, height: 230)))))
            open = image
        }
        let view = ConversationView(key: key, feed: feed, openFile: open).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 820), variant: appearance), named: name)
    }

    @Test("人の発言の画像を押して大きく開いたシート（元の画素数と大きさ）", arguments: Matrix.cases([560]))
    func sentImageViewer(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let feed = model.conversationFeed(for: try Self.key(model, "c-files"))
        let refs = try Self.presetSentImages(feed, model)
        let access = ChatSentImageAccess(feed: feed, fixtures: [:]) { _ in }
        let view = ChatSentImageViewer(ref: refs[0], access: access) {}.environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 520), variant: appearance), named: name)
    }

    /// c-files の最初の人の発言の画像を、取った後の形にしておく（縮小版は取った後に作る）
    @discardableResult
    static func presetSentImages(_ feed: ConversationFeed, _ model: AppModel) throws -> [ChatSentImageRef] {
        let message = try #require(feed.messages.first { $0.images?.isEmpty == false }, "c-files に画像を添えた発言が無い")
        let refs = (message.images ?? []).map { ChatSentImageRef(lineID: message.lineID, image: $0) }
        for ref in refs {
            feed.files.preset(ref, .loaded(try #require(model.fixtureExtras.chatFiles[ref.id], "fixtures に \(ref.id) が無い")))
        }
        return refs
    }

    @Test("この版が知らない種類の問いのカード（アプリを更新する案内）", arguments: Matrix.cases([560]))
    func unsupportedRequest(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let view = VStack {
            UnsupportedRequestPanel()
            Spacer()
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 360), variant: appearance), named: name)
    }

    @Test("会話では使えないコマンドの案内", arguments: Matrix.cases([560, 320]))
    func unsupportedCommand(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let view = VStack {
            ConversationUnsupportedBanner(command: ConversationUnsupportedCommand(name: "theme"), close: {})
            Spacer()
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 200), variant: appearance), named: name)
    }

    @Test("コネクタの問いのカード（form の欄、url の開く先、開けない url、入力欄にできない形）", arguments: Matrix.cases([560]))
    func elicitationRequests(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let schema = #"{"type":"object","properties":{"name":{"type":"string","title":"名前","minLength":1,"maxLength":40},"email":{"type":"string","title":"メールアドレス","format":"email"},"age":{"type":"integer","title":"年齢","minimum":0,"maximum":150,"default":30},"plan":{"type":"string","title":"プラン","oneOf":[{"const":"free","title":"無料"},{"const":"team","title":"チーム"}]},"agree":{"type":"boolean","title":"規約に同意する","description":"同意しないと登録できません"}},"required":["name","email"]}"#
        let form = Elicitation(
            serverName: "github", message: "リポジトリに招待する人を入力してください。", mode: .form, form: Elicitation.Form(schema: Data(schema.utf8)))
        let url = Elicitation(
            serverName: "linear", message: "Linearにサインインしてください。", mode: .url, link: .init(scheme: "https", host: "linear.app"), elicitationID: "e1")
        let unopenable = Elicitation(serverName: "linear", message: "ページを開いてください。", mode: .url)
        let unsupported = Elicitation(
            serverName: "slack", message: "通知するチャンネルを選んでください。", mode: .form,
            form: Elicitation.Form(schema: Data(#"{"type":"object","properties":{"channels":{"type":"array","items":{"type":"string"}}}}"#.utf8)))
        let view = VStack(spacing: Space.block) {
            ForEach(Array([form, url, unopenable, unsupported].enumerated()), id: \.offset) { _, elicitation in
                ElicitationPanel(elicitation: elicitation, blocked: nil, answer: { _, _ in }, fetchURL: { URL(string: "https://linear.app")! })
            }
            Spacer()
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 1100), variant: appearance), named: name)
    }

    @Test("起動のシート", arguments: Matrix.cases([520]))
    func launchSheetConversation(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let task = try #require(model.fleet.task(for: TaskKey(machine: Self.key(model, "c-gen").machine, number: 137)))
        let view = LaunchSheet(task: task, draft: model.launchDraft(for: task)).environment(model).pageInsets()
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 680), variant: appearance), named: name)
    }

    @Test("タスクのパネルの会話の札と会話の画面", arguments: Matrix.cases([760]))
    func taskPanel(name: String) async throws {
        let (width, appearance) = try Matrix.parse(name)
        let model = try await Self.loadedModel()
        let key = try Self.key(model, "c-gen")
        let task = TaskKey(machine: key.machine, number: 137)
        model.navigate(to: .conversation(key), from: .debug)
        let view = TaskPanel(key: task).environment(model).pageInsets()
        let host = BoardSnapshotTests.host(view, size: CGSize(width: width, height: 900), variant: appearance)
        // 札は最初に別の会話で描かれ、会話の一覧が届いてから c-gen に移る（`TaskPanel.takeFocus`）。枠は変わらないので、移った後の描画まで回し直す
        #expect(model.sessionFocus == nil)
        Matrix.settle(host)
        assertImageSnapshot(of: host, named: name)
    }
}
