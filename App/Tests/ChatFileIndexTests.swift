import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor
@Suite("チャットのファイルの一覧と中身の持ち置き")
struct ChatFileIndexTests {
    private func call(_ id: String, _ name: String, _ text: String) -> ChatMessage {
        ChatMessage(id: "c-\(id)", role: .assistant, kind: .toolUse, text: text, toolName: name, toolID: id)
    }

    private func result(_ id: String, _ files: [ChatFile]) -> ChatMessage {
        ChatMessage(id: "r-\(id)", role: .user, kind: .toolResult, text: "", toolID: id, files: files)
    }

    private func edited(_ path: String, _ added: Int, _ removed: Int) -> ChatFile {
        ChatFile(path: path, action: .edited, added: added, removed: removed, offset: 0)
    }

    @Test("最後に触った順に並べ、Write・Edit・Bash の行の数を足し合わせる。押すと開くのは最後に変えた回")
    func entries() {
        let messages = [
            call("t1", "Edit", "/repo/a.swift"), result("t1", [edited("/repo/a.swift", 2, 1)]),
            call("t2", "Bash", "sed -i …"), result("t2", [edited("/repo/b.md", 1, 1), edited("/repo/a.swift", 3, 0)]),
            call("t3", "Read", "/repo/a.swift"), result("t3", [ChatFile(path: "/repo/a.swift", action: .read, offset: 0)]),
            call("t4", "Read", "/repo/c.swift"), result("t4", [ChatFile(path: "/repo/c.swift", action: .read, offset: 0)]),
        ]
        let entries = ChatFileIndex.entries(in: messages)
        #expect(entries.map(\.path) == ["/repo/c.swift", "/repo/a.swift", "/repo/b.md"])
        let a = entries[1]
        #expect(a.added == 5 && a.removed == 1)
        #expect(a.latest.toolID == "t3" && a.shown.toolID == "t2" && a.shown.file.path == "/repo/a.swift")
        #expect(entries[0].change == nil && entries[0].shown.toolID == "t4")
    }

    @Test("画像の Read は結果にパスが無いので呼び出しの file_path を使う。呼び出しが見えなければ一覧に入れない")
    func imagePath() {
        let image = ChatFile(path: nil, action: .image, mediaType: "image/png", bytes: 2048, offset: 0)
        let messages = [call("t1", "Read", "/Users/me/Desktop/画面.png"), result("t1", [image]), result("t9", [image])]
        let refs = ChatFileRef.refs(call: messages[0], result: messages[1])
        #expect(refs.map(\.file.path) == ["/Users/me/Desktop/画面.png"])
        #expect(refs.first?.name == "画面.png" && refs.first?.directory == "~/Desktop")
        #expect(ChatFileRef.refs(call: nil, result: messages[2]).first?.name == "画像")
        #expect(ChatFileIndex.entries(in: messages).map(\.path) == ["/Users/me/Desktop/画面.png"])
    }

    @Test("変える前の全文を取れるのは Edit と Write の上書きだけ（Bash の diff には無い）")
    func hasOriginal() {
        let edit = ChatFileRef(toolID: "t1", toolName: "Edit", file: edited("/repo/a", 1, 0))
        let bash = ChatFileRef(toolID: "t2", toolName: "Bash", file: edited("/repo/a", 1, 0))
        let read = ChatFileRef(toolID: "t3", toolName: "Read", file: ChatFile(path: "/repo/a", action: .read, offset: 0))
        #expect(edit.hasOriginal && !bash.hasOriginal && !read.hasOriginal)
        #expect(edit.id != bash.id)
    }

    @Test("表示用のデータは fixtures から引き、無ければ「表示用のデータです」で失敗する。取れたものは最近の 20 件まで持つ")
    func store() async {
        let store = ChatFileStore()
        let read = ChatFileRef(toolID: "t1", toolName: "Read", file: ChatFile(path: "/repo/a", action: .read, offset: 0))
        let bash = ChatFileRef(toolID: "t2", toolName: "Bash", file: edited("/repo/b", 1, 0))
        let fixtures: [String: ChatFileContent] = ["t1": .text("本文"), "t2|/repo/b": .diff([]), "t1#original": .text("前")]
        await store.load(read, fetch: nil, fixtures: fixtures)
        await store.load(bash, fetch: nil, fixtures: fixtures)
        await store.load(read, part: .original, fetch: nil, fixtures: fixtures)
        #expect(store.state(read) == .loaded(.text("本文")))
        #expect(store.state(bash) == .loaded(.diff([])))
        #expect(store.state(read, .original) == .loaded(.text("前")))

        let missing = ChatFileRef(toolID: "t3", toolName: "Read", file: ChatFile(path: "/repo/c", action: .read, offset: 0))
        await store.load(missing, fetch: nil, fixtures: fixtures)
        guard case .failed(let failure) = store.state(missing) else {
            Issue.record("\(String(describing: store.state(missing)))")
            return
        }
        #expect(failure.text == "ファイルを表示できませんでした。この接続先は表示用のデータです。")

        for i in 0..<ChatFileStore.limit {
            store.preset(ChatFileRef(toolID: "x\(i)", toolName: "Read", file: ChatFile(path: "/x", action: .read, offset: 0)), .loaded(.text("")))
        }
        #expect(store.state(read) == nil, "古いものから落とす")
        #expect(store.entries.count == ChatFileStore.limit)
    }

    @Test("取り先の口があれば fixtures より口を使い、ツールの id・ファイル・部分を渡す")
    func fetch() async {
        let store = ChatFileStore()
        let edit = ChatFileRef(toolID: "t1", toolName: "Edit", file: edited("/repo/a", 1, 0))
        await store.load(edit, part: .original, fetch: { toolID, file, part in .text("\(toolID) \(file.path ?? "") \(part.rawValue)") }, fixtures: ["t1#original": .text("fixtures")])
        #expect(store.state(edit, .original) == .loaded(.text("t1 /repo/a original")))
    }

    @Test("人の発言の画像は行の uuid と画像を口に渡して取り、縮小版を作る。表示用のデータは `image|{行}#{順番}` で引く。追い出すと縮小版も消える")
    func sentImages() async throws {
        // Claude Code 2.1.304 の replay の行の画像（40×24 の PNG）
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACgAAAAYCAIAAAAH5iiXAAAAKElEQVR4nGOQq7gzIIhh1OJRi0ctHrV41OJRi0ctHrV41OJRi4ePxQDJ3GvM8DyE+gAAAABJRU5ErkJggg=="))
        let store = ChatFileStore()
        let ref = ChatSentImageRef(lineID: "b4ca57af-c0f5-4e77-a412-a973f398d722", image: ChatImage(index: 1, offset: 0))
        // 口に渡した行と順番が違えば取れない
        await store.load(ref, fetch: { lineID, image in
            guard lineID == "b4ca57af-c0f5-4e77-a412-a973f398d722", image.index == 1 else { throw URLError(.badURL) }
            return png
        })
        #expect(store.state(ref) == .loaded(.image(png)))
        let thumbnail = try #require(store.thumbnails[ref.id])
        #expect(thumbnail.width == 40 && thumbnail.height == 24, "縮小版の上限より小さい画像は大きくしない")
        #expect(ChatSentImageRef.pixelSize(png).map { [$0.width, $0.height] } == [40, 24])

        let fixture = ChatSentImageRef(lineID: "cu1", image: ChatImage(index: 0, offset: 0))
        #expect(fixture.id == "image|cu1#0" && fixture.name == "画像1")
        await store.load(fixture, fetch: nil, fixtures: ["image|cu1#0": .image(png)])
        #expect(store.state(fixture) == .loaded(.image(png)) && store.thumbnails[fixture.id] != nil)
        let missing = ChatSentImageRef(lineID: "cu1", image: ChatImage(index: 1, offset: 0))
        await store.load(missing, fetch: nil, fixtures: [:])
        guard case .failed(let failure) = store.state(missing) else {
            Issue.record("\(String(describing: store.state(missing)))")
            return
        }
        #expect(failure.text == "画像を表示できませんでした。この接続先は表示用のデータです。")

        for i in 0..<ChatFileStore.limit {
            store.preset(ChatFileRef(toolID: "x\(i)", toolName: "Read", file: ChatFile(path: "/x", action: .read, offset: 0)), .loaded(.text("")))
        }
        #expect(store.state(ref) == nil && store.thumbnails.isEmpty, "中身と一緒に縮小版も落とす")
    }

    @Test("読んだ文の行の分け方と、行番号の桁揃え")
    func lines() {
        #expect(ChatTextLines.lines("a\nb\n") == ["a", "b"])
        #expect(ChatTextLines.lines("a\n\nb") == ["a", "", "b"])
        #expect(ChatTextLines.lines("") == [""])
        #expect(ChatTextLines.pad(7, 3) == "  7" && ChatTextLines.pad(nil, 2) == "  " && ChatTextLines.pad(1234, 2) == "1234")
        #expect(ChatDiffHunk.added("一\n二\n") == ChatDiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, lines: ["+一", "+二"]))
    }

    @Test("ファイルの欄の本文は、行をまたいで選んでコピーでき、畳んだ行の帯はコピーに入らない")
    func copiedSkipsGaps() {
        let document = ChatFileDocument(
            paragraphs: [
                .gap(id: 0, label: "変更のない6行を表示", expandable: true),
                .line(change: .context, old: 7, new: 7, text: "let a = 1"),
                .line(change: .removed, old: 8, new: nil, text: "日本語の行"),
                .gap(id: 3, label: "変更のない5行", expandable: false),
                .line(change: .added, old: nil, new: 8, text: ""),
            ],
            diff: true, digits: 1, fontSize: 14)
        let text = document.attributed(gutter: ChatFileGutter(document))
        #expect(document.copied(text, range: NSRange(location: 0, length: text.length)) == "let a = 1\n日本語の行\n\n")
        // 帯の途中から次の行の途中まで
        let start = (text.string as NSString).range(of: "6行").location
        let end = (text.string as NSString).range(of: "= 1").location
        #expect(document.copied(text, range: NSRange(location: start, length: end - start)) == "let a ")
    }
}
