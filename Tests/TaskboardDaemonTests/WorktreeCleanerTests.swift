import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 使い捨ての git repo（bare の remote つき）。本物の worktree・ブランチには触らない
fileprivate final class GitFixture: Sendable {
    let root: URL
    let remote: String
    let repo: String
    private let worktrees: String

    init(branches: [String] = ["main", "develop"]) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString.prefix(8))")
        // git は symlink を解いたパスで答える（/var → /private/var）ので、最初から解いておく
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: WorktreeCleaner.realPath(base.path))
        remote = root.appendingPathComponent("remote.git").path
        repo = root.appendingPathComponent("repo").path
        worktrees = root.appendingPathComponent("worktrees").path
        try FileManager.default.createDirectory(atPath: worktrees, withIntermediateDirectories: true)
        try git(root.path, "init", "-q", "--bare", "-b", branches[0], remote)
        try git(root.path, "init", "-q", "-b", branches[0], repo)
        try git(repo, "remote", "add", "origin", remote)
        try write("a.txt", "one\n", in: repo)
        try git(repo, "add", "a.txt")
        try git(repo, "commit", "-q", "-m", "first")
        for branch in branches.dropFirst() { try git(repo, "branch", branch) }
        for branch in branches { try git(repo, "push", "-q", "origin", branch) }
        try git(repo, "fetch", "-q", "origin")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ directory: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = GitCommand.executable
        process.arguments = ["-C", directory, "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "protocol.file.allow=always"] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(message: "git \(arguments.joined(separator: " ")): " + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct FixtureError: Error { var message: String }

    func write(_ name: String, _ text: String, in directory: String) throws {
        try text.write(toFile: directory + "/" + name, atomically: true, encoding: .utf8)
    }

    /// `start` から切ったブランチの worktree（追跡の設定は git の既定: remote-tracking から切れば upstream が付く）
    @discardableResult
    func addWorktree(_ name: String, from start: String = "origin/develop") throws -> String {
        let path = worktrees + "/" + name
        try git(repo, "worktree", "add", "-q", "-b", name, path, start)
        return realPath(path)
    }

    func commit(in path: String, _ file: String = "b.txt") throws {
        try write(file, UUID().uuidString, in: path)
        try git(path, "add", file)
        try git(path, "commit", "-q", "-m", "change")
    }

    func branchExists(_ name: String) -> Bool {
        (try? git(repo, "show-ref", "--verify", "--quiet", "refs/heads/\(name)")) != nil
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func realPath(_ path: String) -> String { WorktreeCleaner.realPath(path) }

}

/// fixture の git は協調スレッドを塞いで待つので、並べるとほかの suite の時間待ちが切れる。1 件ずつ回す
@Suite("使っていない worktree の一覧と削除", .serialized)
struct WorktreeCleanerTests {
    private func cleaner(
        _ fixture: GitFixture, occupants: [WorktreeCleaner.Occupant] = []
    ) -> WorktreeCleaner {
        let directories = [fixture.repo]
        return WorktreeCleaner(sources: .init(directories: { directories }, occupants: { occupants }), removalTimeout: .seconds(30))
    }

    private func info(_ cleaner: WorktreeCleaner, _ path: String) async throws -> WorktreeInfo {
        try #require(await cleaner.list().first { $0.path == path })
    }

    private func kinds(_ info: WorktreeInfo) -> Set<WorktreeBlocker.Kind> { Set(info.blockers.map(\.kind)) }

    // MARK: 消せる場合

    @Test("切ったままのブランチは消せる。git で worktree を消し、ブランチも消える。比べ先は upstream の origin/develop")
    func removesCleanWorktree() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("clean")
        let cleaner = cleaner(fixture)
        let listed = try await info(cleaner, path)
        #expect(listed.removable)
        #expect(listed.branch == "clean")
        #expect(listed.base == "origin/develop")

        let results = await cleaner.remove(paths: [path])
        #expect(results == [WorktreeRemoveResult(path: path, outcome: .removed, branch: "clean", branchDeleted: true)])
        #expect(!fixture.exists(path))
        #expect(!fixture.branchExists("clean"))
    }

    @Test("push して比べ先に入ったコミットを持つブランチは消せる。worktree の symlink 越しのパスでも消える")
    func removesMergedAndPushedWorktree() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("done")
        try fixture.commit(in: path)
        try fixture.git(path, "push", "-q", "origin", "done:develop")
        try fixture.git(fixture.repo, "fetch", "-q", "origin")
        // symlink 越しの別名
        let alias = fixture.root.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        let cleaner = cleaner(fixture)
        #expect(try await info(cleaner, path).removable)

        let results = await cleaner.remove(paths: [alias])
        #expect(results.first?.outcome == .removed)
        #expect(!fixture.exists(path))
    }

    @Test("worktree を消した後でブランチを git が断ったら、worktree は消えたまま、ブランチを残して git の文を返す")
    func keepsBranchWhenGitRefusesDeletion() async throws {
        let fixture = try GitFixture()
        // 比べ先（origin/develop）には入ったが、本体の HEAD（main）と upstream には入っていないブランチ。git branch -d は断る
        let path = try fixture.addWorktree("odd", from: "develop")
        try fixture.commit(in: path)
        try fixture.git(path, "push", "-q", "origin", "odd")
        try fixture.git(path, "push", "-q", "origin", "odd:develop")
        try fixture.git(fixture.repo, "fetch", "-q", "origin")
        let cleaner = cleaner(fixture)
        #expect(try await info(cleaner, path).removable)

        let result = try #require(await cleaner.remove(paths: [path]).first)
        #expect(result.outcome == .removed)
        #expect(!result.branchDeleted)
        #expect(result.message?.contains("not fully merged") == true)
        #expect(!fixture.exists(path))
        #expect(fixture.branchExists("odd"))
    }

    // MARK: 断られる場合（どれも、ディレクトリとブランチが残る）

    private func expectRefused(
        _ fixture: GitFixture, _ cleaner: WorktreeCleaner, _ path: String, branch: String?, blockers: Set<WorktreeBlocker.Kind>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let listed = try await info(cleaner, path)
        #expect(!listed.removable, sourceLocation: sourceLocation)
        #expect(kinds(listed) == blockers, sourceLocation: sourceLocation)
        let results = await cleaner.remove(paths: [path])
        #expect(results.first?.outcome == .refused, sourceLocation: sourceLocation)
        #expect(Set(results.first?.blockers.map(\.kind) ?? []) == blockers, sourceLocation: sourceLocation)
        #expect(fixture.exists(path), sourceLocation: sourceLocation)
        if let branch { #expect(fixture.branchExists(branch), sourceLocation: sourceLocation) }
    }

    @Test("未コミットの変更がある")
    func refusesUncommitted() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("dirty")
        try fixture.write("a.txt", "edited\n", in: path)
        try await expectRefused(fixture, cleaner(fixture), path, branch: "dirty", blockers: [.uncommitted])
        #expect(try await info(cleaner(fixture), path).blockers == [WorktreeBlocker(.uncommitted, count: 1)])
    }

    @Test("追跡していないファイルがある")
    func refusesUntracked() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("untracked")
        try fixture.write("new.txt", "x", in: path)
        try await expectRefused(fixture, cleaner(fixture), path, branch: "untracked", blockers: [.untracked])
    }

    @Test("どの remote にも無いコミットがある（比べ先にも入っていない）")
    func refusesUnpushed() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("local")
        try fixture.commit(in: path)
        try await expectRefused(fixture, cleaner(fixture), path, branch: "local", blockers: [.unpushed, .unmerged])
    }

    @Test("push 済みでも比べ先（origin/develop）に入っていないコミットがある")
    func refusesUnmerged() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("pushed")
        try fixture.commit(in: path)
        try fixture.git(path, "push", "-q", "origin", "pushed")
        let cleaner = cleaner(fixture)
        try await expectRefused(fixture, cleaner, path, branch: "pushed", blockers: [.unmerged])
        #expect(try await info(cleaner, path).blockers == [WorktreeBlocker(.unmerged, count: 1)])
    }

    @Test("比べ先が決まらない（develop・main・master のどれも無い repo）")
    func refusesWithoutBase() async throws {
        let fixture = try GitFixture(branches: ["trunk"])
        let path = try fixture.addWorktree("orphan", from: "trunk")
        let listed = try await info(cleaner(fixture), path)
        #expect(listed.base == nil)
        try await expectRefused(fixture, cleaner(fixture), path, branch: "orphan", blockers: [.noBase])
    }

    @Test("ブランチが無い（detached HEAD）")
    func refusesDetached() async throws {
        let fixture = try GitFixture()
        let path = fixture.root.appendingPathComponent("worktrees/detached").path
        try fixture.git(fixture.repo, "worktree", "add", "-q", "--detach", path, "origin/develop")
        try await expectRefused(fixture, cleaner(fixture), WorktreeCleaner.realPath(path), branch: nil, blockers: [.noBranch])
    }

    @Test("動いている pane か終了していない会話がその下にある（深い階層の cwd でも）")
    func refusesInUse() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("busy")
        try FileManager.default.createDirectory(atPath: path + "/sub/dir", withIntermediateDirectories: true)
        let occupants = [
            WorktreeCleaner.Occupant(cwds: [path + "/sub/dir"], user: WorktreeUser(kind: .pane, id: "w1:p1", title: "作業")),
            WorktreeCleaner.Occupant(cwds: ["/somewhere/else"], user: WorktreeUser(kind: .pane, id: "w1:p2")),
            WorktreeCleaner.Occupant(cwds: [path], user: WorktreeUser(kind: .conversation, id: "c1")),
        ]
        let cleaner = cleaner(fixture, occupants: occupants)
        let listed = try await info(cleaner, path)
        #expect(listed.users.map(\.id) == ["w1:p1", "c1"])
        #expect(listed.blockers == [WorktreeBlocker(.inUse, count: 2)])
        try await expectRefused(fixture, cleaner, path, branch: "busy", blockers: [.inUse])
    }

    @Test("repo の本体は消せない")
    func refusesMain() async throws {
        let fixture = try GitFixture()
        _ = try fixture.addWorktree("other")
        let cleaner = cleaner(fixture)
        let main = try await info(cleaner, fixture.repo)
        #expect(main.blockers == [WorktreeBlocker(.main)])
        let results = await cleaner.remove(paths: [fixture.repo])
        #expect(results.first?.outcome == .refused)
        #expect(results.first?.blockers == [WorktreeBlocker(.main)])
        #expect(fixture.exists(fixture.repo + "/.git"))
        #expect(fixture.branchExists("main"))
    }

    @Test("lock された worktree は消せない")
    func refusesLocked() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("locked")
        try fixture.git(fixture.repo, "worktree", "lock", path)
        try await expectRefused(fixture, cleaner(fixture), path, branch: "locked", blockers: [.locked])
    }

    @Test("一覧では消せた worktree も、その後に変わっていれば削除の時点で断る（一覧の判定を引き継がない）")
    func rereadsStateAtRemoval() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("changing")
        let cleaner = cleaner(fixture)
        #expect(try await info(cleaner, path).removable)

        try fixture.write("late.txt", "x", in: path)
        let results = await cleaner.remove(paths: [path])
        #expect(results.first?.outcome == .refused)
        #expect(results.first?.blockers.map(\.kind) == [.untracked])
        #expect(fixture.exists(path))
        #expect(fixture.branchExists("changing"))
    }

    @Test("一覧の後でセッションが使い始めたものも、削除の時点で断る")
    func rereadsOccupantsAtRemoval() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("taken")
        let occupants = Locked<[WorktreeCleaner.Occupant]>([])
        let cleaner = WorktreeCleaner(
            sources: .init(directories: { [fixture.repo] }, occupants: { occupants.value }))
        #expect(try await info(cleaner, path).removable)

        occupants.update { $0 = [.init(cwds: [path], user: WorktreeUser(kind: .pane, id: "w1:p9"))] }
        let results = await cleaner.remove(paths: [path])
        #expect(results.first?.outcome == .refused)
        #expect(results.first?.blockers.map(\.kind) == [.inUse])
        #expect(fixture.exists(path))
    }

    // MARK: 失敗と入力

    @Test("git の worktree でないパス・相対パス・無いパスは何も消さずに結果を返す")
    func rejectsUnknownPaths() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("keep")
        let plain = fixture.root.appendingPathComponent("plain").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let cleaner = cleaner(fixture)

        let results = await cleaner.remove(paths: ["relative/path", plain, fixture.root.path + "/nothing", path + "/.."])
        #expect(results.map(\.outcome) == [.failed, .failed, .refused, .failed])
        #expect(results[2].blockers == [WorktreeBlocker(.missing)])
        #expect(fixture.exists(path))
        #expect(fixture.exists(plain))
    }

    @Test("複数のパスは 1 件ずつ判定し、消せるものだけ消す")
    func removesOnlyEligibleOnes() async throws {
        let fixture = try GitFixture()
        let clean = try fixture.addWorktree("one")
        let dirty = try fixture.addWorktree("two")
        try fixture.write("a.txt", "edited\n", in: dirty)

        let results = await cleaner(fixture).remove(paths: [clean, dirty])
        #expect(results.map(\.outcome) == [.removed, .refused])
        #expect(!fixture.exists(clean))
        #expect(fixture.exists(dirty))
        #expect(fixture.branchExists("two"))
        #expect(!fixture.branchExists("one"))
    }

    @Test("repo は起点のパスから探す。同じ repo を指す起点が複数あっても一覧に 1 回ずつ出る")
    func listsEachWorktreeOnce() async throws {
        let fixture = try GitFixture()
        let path = try fixture.addWorktree("dup")
        let cleaner = WorktreeCleaner(
            sources: .init(directories: { [fixture.repo, path, fixture.repo + "/", "/no/such/dir"] }, occupants: { [] }))
        let paths = await cleaner.list().map(\.path)
        #expect(paths.sorted() == [path, fixture.repo].sorted())
    }
}

@Suite("worktree の git 出力の読み方")
struct WorktreeGitTests {
    private func data(_ fields: [String]) -> Data { Data(fields.joined(separator: "\0").utf8) }

    @Test("worktree list の porcelain -z を、本体・ブランチ・detached・lock・prunable に分ける")
    func parsesWorktreeList() {
        let list = WorktreeGit.parseWorktreeList(
            data([
                "worktree /r", "HEAD aaa", "branch refs/heads/main", "",
                "worktree /w1", "HEAD bbb", "branch refs/heads/feature/x", "locked", "",
                "worktree /w2", "HEAD ccc", "detached", "locked 理由あり", "",
                "worktree /w3", "HEAD ddd", "branch refs/heads/gone", "prunable gitdir file points to non-existent location", "", "",
            ]))
        #expect(list.map(\.path) == ["/r", "/w1", "/w2", "/w3"])
        #expect(list.map(\.branch) == ["main", "feature/x", nil, "gone"])
        #expect(list.map(\.isLocked) == [false, true, true, false])
        #expect(list.map(\.isPrunable) == [false, false, false, true])
        #expect(WorktreeGit.parseWorktreeList(Data()).isEmpty)
    }

    @Test("status の porcelain -z は、変更と追跡していないファイルを数え、rename の元のパスを 1 件に数えない。無視されたものは数えない")
    func parsesStatus() {
        let status = WorktreeGit.parseStatus(data(["M  a.txt", " M b.txt", "R  new.txt", "old.txt", "?? 日本語 のファイル.txt", "?? c", "!! ignored", ""]))
        #expect(status.changed == 3)
        #expect(status.untracked == 2)
        #expect(WorktreeGit.parseStatus(Data()) == (0, 0))
    }

    @Test("比べ先は、別名の upstream、origin の develop・main・master、ローカルの develop・main・master の順。自分の名前は使わない")
    func choosesBase() {
        let all: Set<String> = [
            "refs/heads/main", "refs/heads/develop", "refs/remotes/origin/main", "refs/remotes/origin/develop", "refs/remotes/origin/feature/x",
            "refs/remotes/upstream/release",
        ]
        #expect(WorktreeGit.base(branch: "feature/x", upstream: "refs/remotes/upstream/release", refs: all) == "refs/remotes/upstream/release")
        // 同じ名前の upstream は比べ先にならない
        #expect(WorktreeGit.base(branch: "feature/x", upstream: "refs/remotes/origin/feature/x", refs: all) == "refs/remotes/origin/develop")
        #expect(WorktreeGit.base(branch: "x", upstream: nil, refs: ["refs/remotes/origin/main", "refs/heads/develop"]) == "refs/remotes/origin/main")
        #expect(WorktreeGit.base(branch: "x", upstream: nil, refs: ["refs/heads/master", "refs/heads/main"]) == "refs/heads/main")
        #expect(WorktreeGit.base(branch: "develop", upstream: nil, refs: ["refs/heads/develop", "refs/heads/main"]) == "refs/heads/main")
        #expect(WorktreeGit.base(branch: "x", upstream: nil, refs: ["refs/heads/x", "refs/heads/trunk"]) == nil)
        // 消えた upstream（refs に無い）は使わない
        #expect(WorktreeGit.base(branch: "x", upstream: "refs/remotes/origin/gone", refs: ["refs/heads/main"]) == "refs/heads/main")
    }

    @Test("ref の一覧の行を、全名と upstream に分ける")
    func parsesRefs() {
        let refs = WorktreeGit.parseRefs(Data("refs/heads/a\trefs/remotes/origin/develop\nrefs/heads/b\t\nrefs/remotes/origin/develop\t\n".utf8))
        #expect(refs["refs/heads/a"] == .some("refs/remotes/origin/develop"))
        #expect(refs["refs/heads/b"] == .some(nil))
        #expect(refs.count == 3)
        #expect(WorktreeGit.shortName("refs/remotes/origin/develop") == "origin/develop")
        #expect(WorktreeGit.shortName("refs/heads/develop") == "develop")
    }
}

@Suite("worktree の口")
struct WorktreeRoutesTests {
    private func app(_ cleaner: WorktreeCleaner?) -> APIServer.App {
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m-wt"), name: "test-mac", daemonVersion: "test"))
        var dependencies = APIServer.Dependencies()
        dependencies.worktrees = cleaner
        return APIServer.application(state: state, token: "t", port: 0, dependencies: dependencies)
    }

    private let auth: HTTPFields = [.authorization: "Bearer t", .contentType: "application/json"]

    @Test("GET で一覧、POST で削除の結果が 1 件ずつ返る。断られた 1 件は消えず、消せた 1 件は消える")
    func listsAndRemoves() async throws {
        let fixture = try GitFixture()
        let clean = try fixture.addWorktree("route-clean")
        let dirty = try fixture.addWorktree("route-dirty")
        try fixture.write("a.txt", "edited\n", in: dirty)
        let cleaner = WorktreeCleaner(sources: .init(directories: { [fixture.repo] }, occupants: { [] }))
        try await app(cleaner).test(.router) { client in
            let listed = try await client.execute(uri: "/v1/worktrees", method: .get, headers: auth)
            #expect(listed.status == .ok)
            let worktrees = try WireJSON.decoder().decode(WorktreeListResponse.self, from: listed.body).worktrees
            #expect(worktrees.first { $0.path == clean }?.removable == true)
            #expect(worktrees.first { $0.path == dirty }?.blockers == [WorktreeBlocker(.uncommitted, count: 1)])

            let body = ByteBuffer(bytes: try WireJSON.encoder().encode(WorktreeRemoveRequest(paths: [clean, dirty])))
            let removed = try await client.execute(uri: "/v1/worktrees/remove", method: .post, headers: auth, body: body)
            #expect(removed.status == .ok)
            let results = try WireJSON.decoder().decode(WorktreeRemoveResponse.self, from: removed.body).results
            #expect(results.map(\.outcome) == [.removed, .refused])
        }
        #expect(!fixture.exists(clean))
        #expect(fixture.exists(dirty))
        #expect(fixture.branchExists("route-dirty"))
    }

    @Test("管理が無ければ 503")
    func unavailable() async throws {
        try await app(nil).test(.router) { client in
            let response = try await client.execute(uri: "/v1/worktrees", method: .get, headers: auth)
            #expect(response.status == .serviceUnavailable)
        }
    }
}

@Suite("会話の worktree を git で切る")
struct GitWorktreesTests {
    @Test("無い branch は base から作って ~/.taskboard/worktrees/<repo>/<branch の / を -> に切る。同じ branch は前の worktree を返す。ある branch はそのまま checkout する。本体の branch と無い base は断る")
    func create() async throws {
        let fixture = try GitFixture()
        let home = fixture.root.appendingPathComponent("home").path
        let made = try await GitWorktrees.create(fixture.repo, .init(branch: "feature/e4", base: "origin/develop"), home: home)
        #expect(made == home + "/.taskboard/worktrees/repo/feature-e4")
        #expect(try fixture.git(made, "branch", "--show-current") == "feature/e4")
        #expect(try fixture.git(made, "rev-parse", "HEAD") == fixture.git(fixture.repo, "rev-parse", "origin/develop"))
        #expect(try await GitWorktrees.create(made, .init(branch: "feature/e4"), home: home) == made, "worktree の中から頼んでも同じ repo の名前で探す")

        let existing = try await GitWorktrees.create(fixture.repo, .init(branch: "develop"), home: home)
        #expect(try fixture.git(existing, "branch", "--show-current") == "develop")
        let custom = fixture.root.appendingPathComponent("elsewhere/x").path
        #expect(try await GitWorktrees.create(fixture.repo, .init(branch: "x", path: custom), home: home) == custom)

        await #expect(throws: ConversationError.self) { try await GitWorktrees.create(fixture.repo, .init(branch: "main"), home: home) }
        await #expect(throws: ConversationError.self) { try await GitWorktrees.create(fixture.repo, .init(branch: "y", base: "no-such"), home: home) }
        await #expect(throws: ConversationError.self) { try await GitWorktrees.create(home, .init(branch: "z"), home: home) }
    }

    @Test("repo の名前は --git-common-dir の親（bare なら .git を外した名前）")
    func repoName() {
        #expect(GitWorktrees.repoName(commonDirectory: "/Users/u/dev/taskboard/.git") == "taskboard")
        #expect(GitWorktrees.repoName(commonDirectory: "/srv/git/日本語.git") == "日本語")
    }
}
