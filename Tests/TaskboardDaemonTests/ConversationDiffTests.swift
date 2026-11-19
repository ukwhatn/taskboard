import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("会話の差分：作業フォルダの git", .serialized)
struct ConversationDiffTests {
    /// 一時フォルダに git の repo を作る（ユーザーの設定を読まない）
    private func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "tb-diff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(root, "init", "-q", "-b", "main")
        return root
    }

    @discardableResult
    private func git(_ root: URL, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test("状態と行の数：変更・足した・消した・名前変更・追跡していない・バイナリ・日本語と空白の path。ブランチ。cwd が根の下のフォルダでも path は根から")
    func status() async throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "1\n2\n3\n")
        try write(root, "gone.txt", "x\n")
        try write(root, "old name.txt", "same\nlines\nhere\n")
        try write(root, "sub/keep.txt", "k\n")
        try Data([0, 1, 2]).write(to: root.appending(path: "bin.dat"))
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "init")

        try write(root, "a.txt", "1\nzwei\n3\n4\n")
        try FileManager.default.removeItem(at: root.appending(path: "gone.txt"))
        try git(root, "mv", "old name.txt", "新しい 名前.txt")
        try write(root, "staged.txt", "s\n")
        try git(root, "add", "staged.txt")
        try write(root, "日本語/メモ.md", "一\n二")
        try Data([0, 9, 9, 9]).write(to: root.appending(path: "bin.dat"))

        let result = try #require(try await ConversationDiff.read(cwd: root.appending(path: "sub").path))
        let files = Dictionary(uniqueKeysWithValues: result.status.files.map { ($0.path, $0) })
        #expect(result.status.branch == "main" && !result.status.initial)
        #expect(files["a.txt"]?.change == .modified && files["a.txt"]?.insertions == 2 && files["a.txt"]?.deletions == 1)
        #expect(files["gone.txt"]?.change == .deleted && files["gone.txt"]?.deletions == 1)
        #expect(files["新しい 名前.txt"]?.change == .renamed && files["新しい 名前.txt"]?.oldPath == "old name.txt")
        #expect(files["新しい 名前.txt"]?.insertions == 0 && files["新しい 名前.txt"]?.deletions == 0)
        #expect(files["staged.txt"]?.change == .added && files["staged.txt"]?.insertions == 1)
        #expect(files["日本語/メモ.md"]?.change == .untracked && files["日本語/メモ.md"]?.insertions == 2)
        #expect(files["bin.dat"]?.change == .modified && files["bin.dat"]?.insertions == nil, "バイナリは行の数が無い")
        #expect(files.count == 6)
        let summary = ConversationDiff.response(result).summary
        #expect(summary == ConversationDiffSummary(isRepo: true, branch: "main", files: 6, insertions: 5, deletions: 2))
    }

    @Test("初めのコミットの前は空の tree と比べる。git の外は isRepo が false")
    func initialAndOutside() async throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "first.txt", "a\nb\n")
        try git(root, "add", "first.txt")
        let result = try #require(try await ConversationDiff.read(cwd: root.path))
        #expect(result.status.initial && result.status.branch == "main")
        #expect(result.status.files == [ConversationDiffFile(path: "first.txt", change: .added, insertions: 2, deletions: 0)])
        let diff = try await ConversationDiff.file(cwd: root.path, path: "first.txt")
        #expect(diff.diff.contains("+a\n+b\n") && !diff.truncated)

        let outside = FileManager.default.temporaryDirectory.appending(path: "tb-nogit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(try await ConversationDiff.read(cwd: outside.path) == nil)
        #expect(ConversationDiff.response(nil).summary == ConversationDiffSummary(isRepo: false))
    }

    @Test("1 ファイルの diff：変更・追跡していない・消した・名前変更の元。差分に無い path・.. と絶対 path は断る。1MB で切る")
    func file() async throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt", "1\n")
        try write(root, "gone.txt", "x\n")
        try write(root, "old.txt", "o\n")
        try write(root, "clean.txt", "c\n")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "init")
        try write(root, "a.txt", "1\nadded line\n")
        try write(root, "new file.txt", "新しい行\n")
        try FileManager.default.removeItem(at: root.appending(path: "gone.txt"))
        try git(root, "mv", "old.txt", "moved.txt")
        try write(root, "big.txt", String(repeating: "0123456789abcdef\n", count: 70_000))

        #expect(try await ConversationDiff.file(cwd: root.path, path: "a.txt").diff.contains("+added line"))
        #expect(try await ConversationDiff.file(cwd: root.path, path: "new file.txt").diff.contains("+新しい行"))
        #expect(try await ConversationDiff.file(cwd: root.path, path: "gone.txt").diff.contains("-x"))
        let moved = try await ConversationDiff.file(cwd: root.path, path: "old.txt")
        #expect(moved.path == "moved.txt" && moved.diff.contains("rename from old.txt"))
        let big = try await ConversationDiff.file(cwd: root.path, path: "big.txt")
        #expect(big.truncated && big.diff.utf8.count <= ConversationDiff.fileLimit && big.diff.hasSuffix("\n"))
        for path in ["clean.txt", "../a.txt", "/etc/hosts", ""] {
            await #expect(throws: ConversationDiff.Failure.self) { try await ConversationDiff.file(cwd: root.path, path: path) }
        }
    }

    @Test("ステージ前とステージ済み：同じファイルの index と作業フォルダの変更を分ける。追跡していないファイルはステージ前だけ")
    func stagedAndUnstaged() async throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "both.txt", "1\n2\n")
        try write(root, "only staged.txt", "s\n")
        try write(root, "only tree.txt", "t\n")
        try write(root, "old.txt", "o\np\nq\n")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "init")
        try write(root, "both.txt", "1\n2\nstaged\n")
        try git(root, "add", "both.txt")
        try write(root, "both.txt", "1\n2\nstaged\ntree\n")
        try write(root, "only staged.txt", "s\nmore\n")
        try git(root, "add", "only staged.txt")
        try write(root, "only tree.txt", "t\nmore\n")
        try git(root, "mv", "old.txt", "moved.txt")
        try write(root, "added.txt", "a\n")
        try git(root, "add", "added.txt")
        try write(root, "新規.txt", "一\n")

        let unstaged = try #require(try await ConversationDiff.read(cwd: root.path, scope: .unstaged))
        #expect(
            unstaged.status.files == [
                ConversationDiffFile(path: "both.txt", change: .modified, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "only tree.txt", change: .modified, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "新規.txt", change: .untracked, insertions: 1, deletions: 0),
            ])
        let staged = try #require(try await ConversationDiff.read(cwd: root.path, scope: .staged))
        #expect(
            staged.status.files == [
                ConversationDiffFile(path: "added.txt", change: .added, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "both.txt", change: .modified, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "moved.txt", oldPath: "old.txt", change: .renamed, insertions: 0, deletions: 0),
                ConversationDiffFile(path: "only staged.txt", change: .modified, insertions: 1, deletions: 0),
            ])

        let tree = try await ConversationDiff.file(cwd: root.path, path: "both.txt", scope: .unstaged).diff
        #expect(tree.contains("+tree") && !tree.contains("+staged"))
        let index = try await ConversationDiff.file(cwd: root.path, path: "both.txt", scope: .staged).diff
        #expect(index.contains("+staged") && !index.contains("+tree"))
        #expect(try await ConversationDiff.file(cwd: root.path, path: "old.txt", scope: .staged).diff.contains("rename from old.txt"))
        // その範囲の差分に無い path は断る
        for (path, scope) in [("only staged.txt", ConversationDiffScope.unstaged), ("only tree.txt", .staged), ("新規.txt", .staged)] {
            await #expect(throws: ConversationDiff.Failure.self) { try await ConversationDiff.file(cwd: root.path, path: path, scope: scope) }
        }
    }

    @Test("ブランチ全体：既定のブランチから分かれた所と作業フォルダを比べる。比べるブランチが無ければ空で base も無い")
    func branch() async throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "base.txt", "b\n")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "init")
        try git(root, "checkout", "-q", "-b", "feature")
        try write(root, "committed.txt", "c\n")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "feature")
        // 分かれた後の main の変更は入らない
        try git(root, "checkout", "-q", "main")
        try write(root, "main only.txt", "m\n")
        try git(root, "add", "-A")
        try git(root, "commit", "-q", "-m", "main")
        try git(root, "checkout", "-q", "feature")
        try write(root, "base.txt", "b\nedited\n")
        try write(root, "untracked.txt", "u\n")

        let result = try #require(try await ConversationDiff.read(cwd: root.path, scope: .branch))
        #expect(result.status.base == "main")
        #expect(
            result.status.files == [
                ConversationDiffFile(path: "base.txt", change: .modified, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "committed.txt", change: .added, insertions: 1, deletions: 0),
                ConversationDiffFile(path: "untracked.txt", change: .untracked, insertions: 1, deletions: 0),
            ])
        let response = ConversationDiff.response(result, scope: .branch)
        #expect(response.scope == .branch && response.base == "main" && response.summary.files == 3)
        #expect(try await ConversationDiff.file(cwd: root.path, path: "committed.txt", scope: .branch).diff.contains("+c"))
        await #expect(throws: ConversationDiff.Failure.self) { try await ConversationDiff.file(cwd: root.path, path: "main only.txt", scope: .branch) }

        // 既定のブランチの名前が無い repo
        try git(root, "branch", "-q", "-m", "main", "trunk")
        let none = try #require(try await ConversationDiff.read(cwd: root.path, scope: .branch))
        #expect(none.status.base == nil && none.status.files.isEmpty && none.status.branch == "feature")
        await #expect(throws: ConversationDiff.Failure.self) { try await ConversationDiff.file(cwd: root.path, path: "base.txt", scope: .branch) }
    }

    @Test("範囲を知らない daemon の応答はすべての変更として読む")
    func olderResponse() throws {
        let data = Data(#"{"summary":{"isRepo":true,"files":0,"insertions":0,"deletions":0},"files":[]}"#.utf8)
        let response = try JSONDecoder().decode(ConversationDiffResponse.self, from: data)
        #expect(response.scope == .all && response.base == nil)
    }

    @Test("読み方：copy・unmerged・detached・足してから消したファイル、numstat の rename の欄")
    func parse() {
        let status = Data(
            ("# branch.oid abc\0# branch.head (detached)\0"
                + "2 C. N... 100644 100644 100644 h1 h2 C75 copy.txt\0orig.txt\0"
                + "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt\0"
                + "1 AD N... 000000 100644 000000 h0 h1 ghost.txt\0"
                + "1 .T N... 100644 120000 120000 h1 h2 link\0").utf8)
        let parsed = ConversationDiff.parseStatus(status)
        #expect(parsed.branch == nil && !parsed.initial)
        #expect(
            parsed.files == [
                ConversationDiffFile(path: "copy.txt", oldPath: "orig.txt", change: .copied), ConversationDiffFile(path: "conflict.txt", change: .unmerged),
                ConversationDiffFile(path: "link", change: .typeChanged),
            ])
        let counts = ConversationDiff.parseNumstat(Data("3\t1\ta.txt\0-\t-\tbin\0" .utf8) + Data("0\t0\t\0old\0new\0".utf8))
        #expect(counts["a.txt"]?.insertions == 3 && counts["a.txt"]?.deletions == 1)
        #expect(counts["bin"]?.insertions == nil && counts["new"]?.insertions == 0 && counts["old"] == nil)
        #expect(ConversationDiff.parseStatus(Data()).files.isEmpty)
    }
}
