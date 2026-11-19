import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// チャットのファイルの札と、ファイルの欄（diff・読んだ文・画像・新規・取れないとき・上の一覧）を PNG で固定する。fixtures `chat-files` の会話 c-chat-files。
/// ライト / ダークの 2 組。記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatFilesSnapshotTests {
    nonisolated static let variants: [BoardSnapshotTests.Variant] = BoardSnapshotTests.variants.filter { ["light", "dark"].contains($0.name) }

    static let key = ConversationKey(machine: MachineID(rawValue: "fixture-studio"), id: "c-chat-files")

    static func model() async throws -> AppModel {
        AppDefaults.useScratch("snapshot")
        let model = AppModel(options: LaunchOptions(scenario: "chat-files"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fleet.conversation(for: key) == nil || model.fixtureExtras.conversations[key.id] == nil {
            try #require(ContinuousClock.now < deadline, "fixtures chat-files の読み込みを待ち切れなかった")
            try await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    /// 会話の中の、結果 `toolID` のファイル（Bash は `index` で 2 つめ）
    static func ref(_ messages: [ChatMessage], _ toolID: String, index: Int = 0) throws -> ChatFileRef {
        let call = messages.first { $0.kind == .toolUse && $0.toolID == toolID }
        let result = messages.first { $0.kind == .toolResult && $0.toolID == toolID }
        let refs = ChatFileRef.refs(call: call, result: result)
        try #require(refs.count > index, "fixtures に \(toolID) のファイルが無い")
        return refs[index]
    }

    /// 欄だけを、取った後の形を置いて撮る
    /// `testName` は呼び出し元の名前（省くと全部が pane(_:…) の 1 つの画像に重なる）
    private func pane(_ toolID: String, index: Int = 0, variantName: String, size: CGSize = CGSize(width: 460, height: 640), prepare: (ConversationFeed, ChatFileRef) -> Void = { _, _ in }, testName: String = #function) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = try await Self.model()
        let feed = model.conversationFeed(for: Self.key)
        let ref = try Self.ref(feed.messages, toolID, index: index)
        prepare(feed, ref)
        let view = ChatFilePane(feed: feed, selection: .constant(ref)).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: size, variant: variant), named: variant.name, testName: testName)
    }

    /// 会話の札: Read の文（読み取り済み）・画像（大きさ）・Edit（+2 −1）・Write の新規（+6）・Bash の 2 つのファイル・大きい diff（+60 −0）
    @Test(arguments: variants.map(\.name))
    func chips(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = try await Self.model()
        let messages = model.conversationFeed(for: Self.key).messages
        let view = ChatTranscript(messages: messages, openedFile: try Self.ref(messages, "fe1").id, openFile: { _ in })
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 1000), variant: variant), named: variant.name)
    }

    /// Edit の diff。行番号・+ と − の色・hunk の前と間の「変更のない n 行」。上に、この会話で触った 6 つのファイルの一覧
    @Test(arguments: variants.map(\.name))
    func diff(variantName: String) async throws {
        try await pane("fe1", variantName: variantName)
    }

    /// Read の文。読んだ範囲（1〜12行目、全21行）と、行番号付きの等幅の文
    @Test(arguments: variants.map(\.name))
    func text(variantName: String) async throws {
        try await pane("fr1", variantName: variantName) { feed, ref in
            feed.files.preset(ref, .loaded(.text((0..<12).map { "let line\($0) = \"日本語の文 \($0)\"" }.joined(separator: "\n"))))
        }
    }

    /// Read の画像。パスは呼び出しの file_path から、見出しの下に元の大きさ（3600×2300・1MB）
    @Test(arguments: variants.map(\.name))
    func image(variantName: String) async throws {
        try await pane("fr2", variantName: variantName) { feed, ref in
            feed.files.preset(ref, .loaded(.image(Self.png(NSColor.systemTeal, CGSize(width: 360, height: 230)))))
        }
    }

    /// Write の新規は、全部の行を足した diff
    @Test(arguments: variants.map(\.name))
    func created(variantName: String) async throws {
        try await pane("fw1", variantName: variantName) { feed, ref in
            feed.files.preset(ref, .loaded(.text("# 設定の保存\n\n設定の窓を閉じたときに保存する。\n")))
        }
    }

    /// 取れないとき（記録から行が消えた）は、欄の中に帯と［再読み込み］
    @Test(arguments: variants.map(\.name))
    func failure(variantName: String) async throws {
        try await pane("fr3", variantName: variantName) { feed, ref in
            let rejection = DaemonRejection(status: 404, message: "", code: .notFound, params: ["kind": DaemonErrorCode.Kind.file.rawValue])
            feed.files.preset(ref, .failed(UserFacingError("ファイルを表示できませんでした", error: SessionSourceError.rejected(rejection))!))
        }
    }

    /// 広い幅（1100）では、チャットの右に欄を並べる。札の Edit が選ばれた形で、会話・入力欄はそのまま
    @Test(arguments: variants.map(\.name))
    func sideBySide(variantName: String) async throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let model = try await Self.model()
        let feed = model.conversationFeed(for: Self.key)
        let view = ConversationView(key: Self.key, feed: feed, openFile: try Self.ref(feed.messages, "fe1")).environment(model)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 1100, height: 760), variant: variant), named: variant.name)
    }

    static func png(_ color: NSColor, _ size: CGSize) -> Data {
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }
}
