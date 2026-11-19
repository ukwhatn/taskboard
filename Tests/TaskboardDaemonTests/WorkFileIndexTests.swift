import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("入力欄の @ の候補：作業ディレクトリのファイルの一覧とあいまい一致", .serialized)
struct WorkFileIndexTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-workfiles-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private func write(_ root: URL, _ path: String, _ text: String = "x") throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func git(_ root: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func paths(_ files: [WorkFile]) -> [String] { files.map(\.path) }

    // MARK: あいまい一致

    private func rank(_ query: String, _ paths: [String], limit: Int = 8) -> [String] {
        let entries = WorkFileIndex.entries(of: paths)
        return WorkFileMatcher.rank(query, in: entries, limit: limit).map(\.path)
    }

    @Test("打った文字が順に出てくるものだけ。大文字と小文字は区別しない")
    func subsequence() {
        let all = ["src/ChatComposer.swift", "src/Chat.swift", "README.md"]
        #expect(rank("cc", all).first == "src/ChatComposer.swift")
        #expect(rank("CHATC", all) == ["src/ChatComposer.swift"])
        #expect(rank("zzz", all).isEmpty)
        #expect(rank("tahc", all).isEmpty, "順が違えば合わない")
    }

    @Test("ファイル名に合うものを、途中のフォルダにだけ合うものより先に。区切りと頭文字に合うものを先に")
    func prefersNameAndBoundaries() {
        #expect(rank("main", ["docs/maintenance/notes.md", "Sources/App/main.swift"]).first == "Sources/App/main.swift")
        #expect(rank("cs", ["a/classes.txt", "a/chat_settings.txt"]).first == "a/chat_settings.txt", "_ の後ろの頭文字が続く")
        #expect(rank("cs", ["a/classes.txt", "a/ChatSettings.txt"]).first == "a/ChatSettings.txt", "大文字の頭文字")
        #expect(rank("ab", ["x/a.b", "x/axxb", "x/ab"]).first == "x/ab", "続けて合うものが先")
    }

    @Test("点が同じなら短いものを先に。上限で切る")
    func shorterFirstAndLimit() {
        #expect(rank("a", ["abc/def", "a"], limit: 5).first == "a")
        #expect(rank("a", (0..<30).map { "a\($0)" }, limit: 8).count == 8)
    }

    @Test("日本語の名前も 1 字ずつ合う。字の途中のバイトには合わない")
    func japanese() {
        #expect(rank("メモ", ["日本語/メモ.md", "docs/readme.md"]) == ["日本語/メモ.md"])
        #expect(rank("日語", ["日本語/メモ.md"]).contains("日本語/メモ.md"))
        // 「あ」(E3 81 82) の 3 バイトが別々の字の中に散らばっていても合わない
        #expect(rank("あ", ["\u{3042}x", "\u{3044}\u{3092}"]) == ["\u{3042}x"])
    }

    @Test("打った文字が空なら浅いものから。フォルダも並ぶ")
    func emptyQuery() {
        let result = rank("", ["a/b/c.txt", "z.txt", "a/y.txt"], limit: 3)
        #expect(result == ["z.txt", "a/", "a/y.txt"])
    }

    // MARK: git の repo

    @Test("git の repo：追跡中と追跡していないものを出し、無視したものは出さない。フォルダも出る")
    func gitRepo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q", "-b", "main")
        try write(root, ".gitignore", "ignored.txt\nbuild/\n")
        try write(root, "src/App.swift")
        try write(root, "src/views/Row.swift")
        try write(root, "ignored.txt")
        try write(root, "build/out.o")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "init")
        try write(root, "src/New File.swift")

        let index = WorkFileIndex()
        let all = paths(await index.files(cwd: root.path, query: "", limit: 20))
        #expect(all.contains("src/App.swift") && all.contains("src/views/Row.swift"))
        #expect(all.contains("src/New File.swift"), "追跡していないファイル")
        #expect(all.contains("src/") && all.contains("src/views/"), "フォルダ")
        #expect(!all.contains("ignored.txt") && !all.contains("build/out.o") && !all.contains("build/"), "無視したものは出さない")
        #expect(paths(await index.files(cwd: root.path, query: "row", limit: 3)).first == "src/views/Row.swift")
        let folders = await index.files(cwd: root.path, query: "views", limit: 3).filter(\.isDirectory)
        #expect(folders.map(\.path) == ["src/views/"])
    }

    @Test("repo の下のフォルダが作業ディレクトリなら、その下のパスだけを、そこからの相対で出す")
    func gitSubfolder() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q", "-b", "main")
        try write(root, "top.txt")
        try write(root, "pkg/inner.txt")
        try git(root, "add", "-A")
        let all = paths(await WorkFileIndex().files(cwd: root.appending(path: "pkg").path, query: "", limit: 20))
        #expect(all == ["inner.txt"])
    }

    @Test("消したファイル（追跡中のまま）は返さない。一覧は控えるので、消えた分は返す前に外す")
    func deletedFilesAreDropped() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, "init", "-q", "-b", "main")
        try write(root, "keep.txt")
        try write(root, "gone.txt")
        try git(root, "add", "-A")
        try FileManager.default.removeItem(at: root.appending(path: "gone.txt"))
        #expect(paths(await WorkFileIndex().files(cwd: root.path, query: "", limit: 20)) == ["keep.txt"])
    }

    // MARK: repo でないフォルダ

    @Test("repo でないフォルダは歩く：除外した名前の下には入らず、深さと数の上限で止まり、シンボリックリンクの先をたどらない")
    func walk() async throws {
        let root = try folder()
        let outside = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write(root, "a.txt")
        try write(root, "node_modules/dep/index.js")
        try write(root, ".git/config")
        try write(root, "d1/d2/d3/deep.txt")
        try write(outside, "secret.txt")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside)

        let all = paths(await WorkFileIndex().files(cwd: root.path, query: "", limit: 20))
        #expect(all.contains("a.txt") && all.contains("d1/d2/d3/deep.txt"))
        #expect(!all.contains { $0.hasPrefix("node_modules") || $0.hasPrefix(".git") }, "除外した名前")
        #expect(!all.contains { $0.contains("secret") }, "シンボリックリンクの先")

        var shallow = WorkFileIndex.Limits()
        shallow.walkDepth = 2
        #expect(!paths(await WorkFileIndex(limits: shallow).files(cwd: root.path, query: "deep", limit: 5)).contains("d1/d2/d3/deep.txt"))
        var few = WorkFileIndex.Limits()
        few.walkFiles = 1
        let counted = await WorkFileIndex.list(cwd: root.path, limits: few)
        #expect(counted.entries.filter { !$0.file.isDirectory }.count == 1)
        #expect(counted.truncated, "数の上限で切れたことを知らせる")
    }

    @Test("作業ディレクトリが無い・フォルダでなければ空")
    func missingFolder() async throws {
        let index = WorkFileIndex()
        #expect(await index.files(cwd: "/nonexistent-\(UUID().uuidString)", query: "", limit: 5).isEmpty)
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "file.txt")
        #expect(await index.files(cwd: root.appending(path: "file.txt").path, query: "", limit: 5).isEmpty)
    }

    @Test("上限に達したら、そこまでの分を返し、打ち切ったことを知らせる。達しなければ知らせない")
    func truncation() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<10 { try write(root, "f\(number).txt") }
        var few = WorkFileIndex.Limits()
        few.walkFiles = 4
        let cut = await WorkFileIndex(limits: few).search(cwd: root.path, query: "", limit: 20)
        #expect(cut.truncated && cut.files.count == 4)
        let whole = await WorkFileIndex().search(cwd: root.path, query: "", limit: 20)
        #expect(!whole.truncated && whole.files.count == 10)

        // git の repo：一覧の件数の上限
        try git(root, "init", "-q", "-b", "main")
        try git(root, "add", "-A")
        var gitFew = WorkFileIndex.Limits()
        gitFew.files = 3
        let gitCut = await WorkFileIndex(limits: gitFew).search(cwd: root.path, query: "", limit: 20)
        #expect(gitCut.truncated && gitCut.files.filter { !$0.isDirectory }.count == 3)
        #expect(await WorkFileIndex().search(cwd: root.path, query: "", limit: 20).truncated == false)
    }

    @Test("同じ作業ディレクトリへ続けて来た要求は、走っている 1 本の一覧づくりにまとめる")
    func concurrentRequestsShareOneListing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<50 { try write(root, "d\(number % 5)/f\(number).txt") }
        let index = WorkFileIndex()
        let results = await withTaskGroup(of: Int.self) { group in
            for number in 0..<20 { group.addTask { await index.files(cwd: root.path, query: "f\(number)", limit: 5).count } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 20 && results.allSatisfy { $0 >= 1 })
    }

    // MARK: 控え

    @Test("一覧は決めた時間のあいだ控える：その間に増えたファイルは出ず、過ぎたら引き直す")
    func caching() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "first.txt")
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let index = WorkFileIndex(limits: WorkFileIndex.Limits(), now: { clock.now })
        #expect(paths(await index.files(cwd: root.path, query: "", limit: 20)) == ["first.txt"])
        try write(root, "second.txt")
        clock.now = Date(timeIntervalSince1970: 1_005)
        #expect(paths(await index.files(cwd: root.path, query: "", limit: 20)) == ["first.txt"], "控えの間")
        clock.now = Date(timeIntervalSince1970: 1_011)
        #expect(Set(paths(await index.files(cwd: root.path, query: "", limit: 20))) == ["first.txt", "second.txt"], "過ぎたら引き直す")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }
}

private extension WorkFileIndex {
    func files(cwd: String, query: String, limit: Int) async -> [WorkFile] {
        await search(cwd: cwd, query: query, limit: limit).files
    }
}
