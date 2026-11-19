import AppKit
import Foundation
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// ［ファイルを添付］で選んだファイルの振り分け（`ChatFileIntake.take`）
@Suite struct ChatFileIntakeTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tb-intake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test("同じ Mac の会話はパスだけを持ち、画像は画像の添付に回す")
    func localKeepsPaths() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = try write(Data("見積".utf8), "見積 v2.txt", in: dir)
        let image = try write(Self.png, "画面.png", in: dir)
        let outcome = ChatFileIntake.take([text, image], local: true, room: 20)
        #expect(outcome.files.map(\.name) == ["見積 v2.txt"])
        #expect(outcome.files.first?.content == .path(text.path))
        #expect(outcome.images == [Self.png])
        #expect(outcome.problem == nil)
    }

    @Test("ほかのマシンの会話は中身を持つ。50MB を超えるファイルは読まずに外す")
    func remoteReadsData() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = try write(Data("abc".utf8), "a.csv", in: dir)
        let large = dir.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ChatAttachment.maxFileBytes + 1))
        try handle.close()
        let outcome = ChatFileIntake.take([small, large], local: false, room: 20)
        #expect(outcome.files.map(\.content) == [.data(Data("abc".utf8))])
        #expect(outcome.problem == .tooLarge("large.bin"))
    }

    @Test("足せる数を超えた分と読めないファイルは外し、最初の問題を返す。拡張子が画像でも中身が画像でなければファイルにする")
    func limitsAndUnreadable() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try write(Data("1".utf8), "1.txt", in: dir)
        let second = try write(Data("2".utf8), "2.txt", in: dir)
        let fake = try write(Data("not png".utf8), "fake.png", in: dir)
        let missing = dir.appendingPathComponent("消えた.txt")
        #expect(ChatFileIntake.take([first, second], local: true, room: 1).problem == .tooMany)
        #expect(ChatFileIntake.take([first, second], local: true, room: 1).files.count == 1)
        #expect(ChatFileIntake.take([missing], local: true, room: 5).problem == .unreadable("消えた.txt"))
        #expect(ChatFileIntake.take([missing], local: false, room: 5).problem == .unreadable("消えた.txt"))
        let faked = ChatFileIntake.take([fake], local: true, room: 5)
        #expect(faked.images.isEmpty)
        #expect(faked.files.map(\.name) == ["fake.png"])
    }

    @Test("フォルダは同じ Mac の会話だけ。ほかのマシンの会話では外して、最初の問題にする")
    func folders() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("資料 一式")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = try write(Data("x".utf8), "a.txt", in: dir)
        let local = ChatFileIntake.take([project, file], local: true, room: 20)
        #expect(local.files.map(\.name) == ["資料 一式", "a.txt"])
        #expect(local.files.map(\.isFolder) == [true, false])
        #expect(local.files.first?.content == .path(project.path))
        #expect(local.problem == nil)
        let remote = ChatFileIntake.take([project, file], local: false, room: 20)
        #expect(remote.files.map(\.name) == ["a.txt"])
        #expect(remote.problem == .folderNotLocal("資料 一式"))
        #expect(ChatFileIntake.take([project], local: true, room: 0).problem == .tooMany, "数の上限はフォルダにも掛かる")
    }

    @Test("長い貼り付けは pasted-text.txt の添付にし、行の数と文を持つ")
    func pastedText() {
        let file = ChatDraftFile.pasted("一行目\n二行目\n三行目\n")
        #expect(file.name == ChatAttachment.pastedTextName)
        #expect(file.pastedLines == 3 && file.pastedText == "一行目\n二行目\n三行目\n")
        #expect(ChatDraftFile.pasted("末尾の改行なし\n2 行目").pastedLines == 2)
        #expect(ChatDraftFile(name: "a.txt", content: .data(Data("x".utf8))).pastedText == nil)
    }
}

/// 添付したファイルの札：履歴の人の発言（Claude と codex の一覧を外した札）、送っている発言、入力欄の上の下書き
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatAttachedFilesSnapshotTests {
    nonisolated static let variants: [BoardSnapshotTests.Variant] = BoardSnapshotTests.variants.filter { ["light", "dark"].contains($0.name) }

    @Test(arguments: variants.map(\.name))
    func attached(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let paths = ["/Users/me/資料/見積 v2.pdf", "/tmp/sales.csv"]
        let messages = [
            ChatMessage(id: "u1", role: .user, kind: .text, text: MentionedFiles.compose("この 2 つを突き合わせて", paths: paths, engine: .claude), at: at),
            ChatMessage(id: "a1", role: .assistant, kind: .text, text: "読みます。", at: at),
            ChatMessage(id: "u2", role: .user, kind: .text, text: MentionedFiles.compose("", paths: ["/tmp/log.txt"], engine: .codex), at: at),
        ]
        var timeline = ConversationTimeline()
        timeline.addOutgoing(clientMessageID: "o1", text: "これも", fileNames: ["memo.md"], at: at)
        let fonts = ChatFonts(size: SessionTextSize.chatDefault)
        let view = VStack(spacing: 0) {
            ChatTranscript(messages: messages, outgoing: timeline.outgoing)
            ChatDraftFileStrip(
                files: [
                    ChatDraftFile(name: "設計 2026-10.md", content: .path("/a")), ChatDraftFile(name: "data.json", content: .data(Data())),
                    ChatDraftFile(name: "資料 一式", content: .path("/b"), isFolder: true), .pasted(String(repeating: "貼り付けた行\n", count: 120)),
                ],
                fonts: fonts, remove: { _ in }, restore: { _ in }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.block)
        }
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 520), variant: variant), named: variant.name)
    }
}
