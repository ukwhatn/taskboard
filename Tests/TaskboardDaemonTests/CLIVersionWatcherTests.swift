import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

@Suite("CLI の新しい版の確かめ")
struct CLIVersionWatcherTests {
    /// support と versions の一時フォルダ。Claude Code の versions には実行できる 2.1.302・2.1.303 と、実行できない 2.1.400、版でない名前を置く。
    /// codex の releases には同じ版を `<版>-aarch64-apple-darwin/bin/codex` で置く
    private struct World {
        let engine: AgentKind
        let support: URL
        let versions: URL
        let slots = ConversationSlots(soft: 2, hard: 4)
        let state = DaemonState(machine: MachineInfo(id: MachineID(rawValue: "m-cli"), name: "t", daemonVersion: "t"))
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        /// 確かめた実行ファイルのパス
        let calls = Locked<[String]>([])
        /// 通らない段の名前（nil なら全部通る）
        let failing = Locked<String?>(nil)

        init(_ engine: AgentKind = .claude) throws {
            self.engine = engine
            let root = FileManager.default.temporaryDirectory.appending(path: "tb-cli-\(UUID().uuidString)", directoryHint: .isDirectory)
            support = root.appending(path: "support", directoryHint: .isDirectory)
            versions = root.appending(path: "versions", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
            for (name, mode) in [("2.1.302", 0o755), ("2.1.303", 0o755), ("2.1.400", 0o644), ("latest", 0o755)] {
                var url = versions.appending(path: name)
                if engine == .codex {
                    url = versions.appending(path: name == "latest" ? "current" : "\(name)-aarch64-apple-darwin").appending(path: "bin/codex")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                try Data("#!/bin/sh\n".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
        }

        /// その版の実行ファイル
        func executable(_ version: String) -> String {
            switch engine {
            case .claude: versions.appending(path: version).path
            case .codex: versions.appending(path: "\(version)-aarch64-apple-darwin/bin/codex").path
            }
        }

        var watcher: CLIVersionWatcher {
            let (calls, failing, engine) = (calls, failing, engine)
            return CLIVersionWatcher(
                engine: engine, supportDirectory: support, versionsDirectory: versions, slots: slots, state: state,
                check: { path in
                    calls.update { $0.append(path) }
                    let failed = failing.value
                    let url = URL(fileURLWithPath: path)
                    let version = engine == .claude ? url.lastPathComponent : String(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent.prefix { $0 != "-" })
                    return EngineCheck.Report(
                        engine: engine, version: version, executable: path, capabilities: CLIVersionWatcher.requiredCapabilities(engine),
                        steps: [
                            EngineCheck.Step(name: "起こす", passed: true, detail: ""), EngineCheck.Step(name: "送る", passed: failed != "送る", detail: ""),
                        ])
                }, now: { [clock] in clock.now })
        }

        var verified: [String] { VerifiedCLI.load(engine, supportDirectory: support)?.entries.map(\.version) ?? [] }

        func cleanUp() { try? FileManager.default.removeItem(at: support.deletingLastPathComponent()) }
    }

    @Test("入っている版のうち実行できる最も新しい版を 1 回だけ確かめ、通れば確かめた版に足して health に出す")
    func checksNewest() async throws {
        let world = try World()
        defer { world.cleanUp() }
        let watcher = world.watcher
        #expect(await watcher.newestInstalled()?.version == "2.1.303")
        #expect(await watcher.checkNewest())
        #expect(world.calls.value == [world.executable("2.1.303")])
        #expect(world.verified == ["2.1.303"])
        #expect(await watcher.checkNewest() == false)
        #expect(world.calls.value.count == 1)
        await watcher.publish()
        let status = try #require(await world.state.machineInfo().claudeCLI)
        #expect(status.using == "2.1.303" && status.newest == "2.1.303" && status.failedVersion == nil)
        #expect(world.slots.count == 0, "確かめ終えたら枠を返す")
    }

    @Test("通らなかった版は記録して health に段を出し、1 日たつまで試し直さない")
    func retriesFailedVersionAfterADay() async throws {
        let world = try World()
        defer { world.cleanUp() }
        world.failing.update { $0 = "送る" }
        let watcher = world.watcher
        #expect(await watcher.checkNewest())
        #expect(world.verified.isEmpty)
        #expect(await watcher.attempts().map(\.failedStep) == ["送る"])
        await watcher.publish()
        let status = try #require(await world.state.machineInfo().claudeCLI)
        #expect(status.using == nil && status.failedVersion == "2.1.303" && status.failedStep == "送る")

        world.clock.advance(23 * 3600)
        #expect(await watcher.checkNewest() == false)
        world.failing.update { $0 = nil }
        world.clock.advance(3600 + 1)
        #expect(await watcher.checkNewest())
        #expect(world.calls.value.count == 2 && world.verified == ["2.1.303"])
        #expect(await watcher.attempts().map(\.passed) == [true], "同じ版の前の記録は置き換える")
    }

    @Test("通った版が確かめた版の記録から落ちたら、待たずに試し直す")
    func rechecksWhenDropped() async throws {
        let world = try World()
        defer { world.cleanUp() }
        let watcher = world.watcher
        #expect(await watcher.checkNewest())
        try FileManager.default.removeItem(at: VerifiedCLI.file(.claude, supportDirectory: world.support))
        #expect(await watcher.checkNewest())
        #expect(world.calls.value.count == 2 && world.verified == ["2.1.303"])
    }

    @Test("codex：releases の `<版>-<target>/bin/codex` の最も新しい版を確かめ、Claude Code と別の記録に書いて health の codex に出す")
    func checksCodex() async throws {
        let world = try World(.codex)
        defer { world.cleanUp() }
        let watcher = world.watcher
        #expect(await watcher.newestInstalled()?.version == "2.1.303")
        #expect(await watcher.checkNewest())
        #expect(world.calls.value == [world.executable("2.1.303")])
        #expect(world.verified == ["2.1.303"])
        #expect(VerifiedCLI.load(.claude, supportDirectory: world.support) == nil, "Claude Code の記録に混ぜない")
        await watcher.publish()
        let machine = await world.state.machineInfo()
        #expect(machine.codexCLI?.using == "2.1.303" && machine.claudeCLI == nil)
        #expect(await watcher.attempts().map(\.version) == ["2.1.303"])
        #expect(await world.watcher.slotKey == "codex-version-check")
    }

    @Test("codex が入っていないマシンでは、health に codex の様子を出さない")
    func quietWithoutCodex() async throws {
        let world = try World(.codex)
        defer { world.cleanUp() }
        try FileManager.default.removeItem(at: world.versions)
        await world.watcher.publish()
        #expect(await world.state.machineInfo().codexCLI == nil)
    }

    @Test("会話の枠の目安に空きが無ければ確かめずに待つ")
    func waitsForSlot() async throws {
        let world = try World()
        defer { world.cleanUp() }
        #expect(world.slots.reserve("a", withinSoft: true) && world.slots.reserve("b", withinSoft: true))
        let watcher = world.watcher
        #expect(await watcher.checkNewest() == false)
        #expect(world.calls.value.isEmpty)
        world.slots.release("a")
        #expect(await watcher.checkNewest())
    }
}
