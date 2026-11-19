import Darwin
import Foundation
import Logging
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// 流れてきた Run の出来事を持つ
private actor RunEvents {
    private(set) var updates: [ConversationRunUpdate] = []
    private(set) var finished: [String] = []

    func add(_ event: ConversationRuns.Event) {
        switch event {
        case .update(_, let update): updates.append(update)
        case .finished(let id): finished.append(id)
        }
    }

    func output(_ run: String) -> String { updates.filter { $0.id == run }.map(\.chunk).joined() }
    func last(_ run: String) -> ConversationRunUpdate? { updates.last { $0.id == run } }
}

/// host の知らせを今の daemon（`ConversationShells`）へ渡す。daemon の入れ替えで渡す先を替える
private final class NoticeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var target: ConversationShells?

    func set(_ shells: ConversationShells) { lock.withLock { target = shells } }
    func deliver(_ notice: AgentHostNotice) { lock.withLock { target }?.deliver(notice) }
}

private let fish = "/opt/homebrew/bin/fish"
private let hasFish = FileManager.default.isExecutableFile(atPath: fish)

@Suite("ConversationRuns（コードブロックの Run）", .serialized)
struct ConversationRunsTests {
    private final class World: @unchecked Sendable {
        let host: InProcessAgentHost
        let relay: NoticeRelay
        let directory: URL
        let limits: ConversationRuns.Limits
        private(set) var runs: ConversationRuns
        private(set) var events = RunEvents()
        private var pump: Task<Void, Never>

        private init(host: InProcessAgentHost, relay: NoticeRelay, directory: URL, limits: ConversationRuns.Limits, runs: ConversationRuns, events: RunEvents, pump: Task<Void, Never>) {
            self.host = host
            self.relay = relay
            self.directory = directory
            self.limits = limits
            self.runs = runs
            self.events = events
            self.pump = pump
        }

        static func make(_ change: (inout ConversationRuns.Limits) -> Void = { _ in }) async throws -> World {
            var limits = ConversationRuns.Limits()
            limits.killGrace = .seconds(2)
            change(&limits)
            let directory = FileManager.default.temporaryDirectory.appending(path: "tb-runs-\(UUID().uuidString)", directoryHint: .isDirectory)
            // ユーザーの設定ファイルを読ませない（zsh は startup ファイルが無いと新しい人向けの案内を出す）
            try FileManager.default.createDirectory(at: directory.appending(path: "home/sub"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appending(path: "home/.zshrc").path, contents: Data())
            let host = InProcessAgentHost(logDirectory: directory.appending(path: "logs"), logger: Logger(label: "test"))
            let relay = NoticeRelay()
            await host.start { notice in relay.deliver(notice) }
            let (runs, events, pump) = await Self.daemon(host: host, relay: relay, directory: directory, limits: limits)
            return World(host: host, relay: relay, directory: directory, limits: limits, runs: runs, events: events, pump: pump)
        }

        private static func daemon(host: InProcessAgentHost, relay: NoticeRelay, directory: URL, limits: ConversationRuns.Limits) async -> (ConversationRuns, RunEvents, Task<Void, Never>) {
            let shells = ConversationShells(host: host, logger: Logger(label: "test"))
            relay.set(shells)
            await shells.hostConnected(version: AgentHostWire.protocolVersion)
            let runs = ConversationRuns(shells: shells, directory: directory.appending(path: "runs"), loginShell: "/bin/zsh", limits: limits, logger: Logger(label: "test"))
            let events = RunEvents()
            let pump = Task { for await event in runs.events { await events.add(event) } }
            return (runs, events, pump)
        }

        /// daemon を入れ替える（host とシェルは残る）
        func restartDaemon() async {
            pump.cancel()
            (runs, events, pump) = await Self.daemon(host: host, relay: relay, directory: directory, limits: limits)
        }

        var home: String { directory.appending(path: "home").path }

        func start(_ code: String, language: String = "bash", conversation: String = "c1") async throws -> ConversationRun {
            try await runs.start(
                conversationID: conversation, cwd: home,
                environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": home, "XDG_CONFIG_HOME": "\(home)/.config"],
                ConversationRunRequest(code: code, language: language, messageID: "m1"))
        }

        /// 終わり、終わった様子の出来事が届くまで待って、終わった記録を返す（出来事は別の Task が受けるので、記録より遅れて届く）
        func finished(_ run: ConversationRun, conversation: String = "c1", timeout: Duration = .seconds(10)) async throws -> ConversationRun {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let current = await runs.get(conversationID: conversation, run.id), current.status != .running,
                    await events.last(run.id)?.status == current.status
                {
                    return current
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("終わらなかった")
            return try #require(await runs.get(conversationID: conversation, run.id))
        }

        func run(_ code: String, language: String = "bash", conversation: String = "c1") async throws -> ConversationRun {
            try await finished(try await start(code, language: language, conversation: conversation), conversation: conversation)
        }

        /// 出力に `text` が出るまで待つ
        func wait(for text: String, in run: ConversationRun, conversation: String = "c1") async throws {
            for _ in 0..<250 {
                if await runs.get(conversationID: conversation, run.id)?.output.contains(text) == true { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("\(text) が出なかった")
        }

        func cleanUp(_ conversations: [String] = ["c1"]) async {
            for id in conversations { await runs.reset(conversationID: id) }
            pump.cancel()
            await host.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("標準出力と標準エラーを合わせて、作業フォルダで動かす。標準入力は空。0 以外で終われば failed と終了コード。流した続きと全部が同じ（日本語と英語）")
    func output() async throws {
        let world = try await World.make()
        let run = try await world.start("printf 'あいう\\n'; echo err >&2; basename \"$(pwd -P)\"; cat; printf 'no newline'; false")
        #expect(run.status == .running && run.output.isEmpty && run.messageID == "m1")
        let done = try await world.finished(run)
        #expect(done.status == .failed && done.exitCode == 1 && done.endedAt != nil)
        #expect(done.output == "あいう\nerr\nhome\nno newline")
        #expect(await world.events.output(run.id) == done.output)
        for _ in 0..<100 where await world.events.finished.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await world.events.finished == ["c1"])
        await world.cleanUp()
    }

    @Test("変数と cd が次の Run に残る（bash・zsh）。色の列は落とす", arguments: ["bash", "zsh"])
    func keepsState(language: String) async throws {
        let world = try await World.make()
        #expect(try await world.run("A=hello; cd sub", language: language).status == .succeeded)
        let done = try await world.run("printf '\\033[31m%s\\033[0m %s\\n' \"$A\" \"$(basename \"$PWD\")\"", language: language)
        #expect(done.output == "hello sub\n" && done.exitCode == 0)
        await world.cleanUp()
    }

    @Test("fish も変数と cd が次の Run に残る", .enabled(if: hasFish))
    func keepsStateFish() async throws {
        let world = try await World.make()
        #expect(try await world.run("set -g A hello; cd sub", language: "fish").status == .succeeded)
        let done = try await world.run("echo $A (basename $PWD); false", language: "fish")
        #expect(done.output == "hello sub\n" && done.exitCode == 1 && done.status == .failed)
        await world.cleanUp()
    }

    @Test("bash と sh は同じシェル、zsh は別のシェル。shell・console はログインシェル（ここでは zsh）。ほかの言語は断る")
    func languages() async throws {
        let world = try await World.make()
        _ = try await world.run("A=bash")
        #expect(try await world.run("echo $A", language: "sh").output == "bash\n")
        #expect(try await world.run("echo \"[$A]\" ${ZSH_VERSION:+zsh}", language: "zsh").output == "[] zsh\n")
        #expect(try await world.run("echo ${ZSH_VERSION:+zsh}", language: "shell").output == "zsh\n")
        await #expect(throws: ConversationError.invalid("実行できる言語は bash・console・fish・sh・shell・zsh")) {
            try await world.start("print(1)", language: "python")
        }
        await world.cleanUp()
    }

    @Test("コードが exit するとシェルごと終わるが、終了コードは取れる。次の Run は新しいシェルで動く", arguments: ["bash", "zsh"])
    func exitInCode(language: String) async throws {
        let world = try await World.make()
        _ = try await world.run("B=kept", language: language)
        let done = try await world.run("echo bye; exit 3", language: language)
        #expect(done.status == .failed && done.exitCode == 3 && done.output == "bye\n")
        #expect(try await world.run("echo \"[$B]\"", language: language).output == "[]\n")
        await world.cleanUp()
    }

    @Test("取り消すと Ctrl-C で止まって cancelled。シェルと変数は残る", arguments: ["bash", "zsh", "fish"])
    func cancel(language: String) async throws {
        guard language != "fish" || hasFish else { return }
        let world = try await World.make()
        _ = try await world.run(language == "fish" ? "set -g B kept" : "B=kept", language: language)
        let run = try await world.start("echo started; sleep 600; echo after", language: language)
        try await world.wait(for: "started", in: run)
        let stopped = ContinuousClock.now
        #expect(await world.runs.cancel(conversationID: "c1", run.id))
        let done = try await world.finished(run)
        #expect(done.status == .cancelled && done.output == "started\n")
        #expect(ContinuousClock.now - stopped < .seconds(2), "閉じる前に Ctrl-C で止まる")
        #expect(try await world.run("echo $B", language: language).output == "kept\n")
        await world.cleanUp()
    }

    @Test("Ctrl-C を無視するコードは、猶予の後にシェルを閉じて止める。次の Run は新しいシェル")
    func closeAfterGrace() async throws {
        let world = try await World.make { $0.killGrace = .milliseconds(800) }
        let run = try await world.start("trap '' INT; echo started; sleep 600")
        try await world.wait(for: "started", in: run)
        _ = await world.runs.cancel(conversationID: "c1", run.id)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await world.runs.get(conversationID: "c1", run.id)?.status == .running, "Ctrl-C では止まらない")
        #expect(try await world.finished(run).status == .cancelled)
        #expect(try await world.run("echo again").output == "again\n")
        await world.cleanUp()
    }

    @Test("時間の上限を過ぎたら止めて timedOut。出力は上限で切って truncated。同じシェルで動いている間は 409、別のシェルは動かせる")
    func limits() async throws {
        let world = try await World.make {
            $0.duration = .milliseconds(1500)
            $0.outputBytes = 10
        }
        let slow = try await world.start("sleep 5")
        do {
            _ = try await world.start("echo x", language: "sh")
            Issue.record("同じシェルで 2 つ動いた")
        } catch let error as ConversationError {
            #expect(error.status == 409 && error.code == .runLimit && error.params["limit"] == "1")
        }
        #expect(try await world.run("echo z", language: "zsh").output == "z\n")
        #expect(try await world.finished(slow).status == .timedOut)

        let long = try await world.run("printf '0123456789abcdef'")
        #expect(long.output == "0123456789" && long.truncated && long.status == .succeeded)
        #expect(await world.events.last(long.id)?.truncated == true)
        await world.cleanUp()
    }

    @Test("シェルを再起動すると変数を捨て、動いている Run は cancelled")
    func reset() async throws {
        let world = try await World.make()
        _ = try await world.run("A=old")
        let run = try await world.start("echo started; sleep 600")
        try await world.wait(for: "started", in: run)
        await world.runs.reset(conversationID: "c1")
        #expect(try await world.finished(run).status == .cancelled)
        #expect(try await world.run("echo \"[$A]\"").output == "[]\n")
        await world.cleanUp()
    }

    @Test("daemon を入れ替えても、host のシェルを使い続ける（変数が残る）")
    func survivesDaemonRestart() async throws {
        let world = try await World.make()
        _ = try await world.run("A=kept")
        await world.restartDaemon()
        #expect(try await world.run("echo $A").output == "kept\n")
        await world.cleanUp()
    }

    @Test("会話ごとに直近の件数だけ持つ（古い終わったものから捨てる）。ほかの会話の Run は引けない。会話を消すと動いている Run を止めて捨てる")
    func kept() async throws {
        let world = try await World.make { $0.kept = 2 }
        var runs: [ConversationRun] = []
        for _ in 0..<3 { runs.append(try await world.run("true")) }
        #expect(await world.runs.get(conversationID: "c1", runs[0].id) == nil)
        #expect(await world.runs.get(conversationID: "c1", runs[2].id) != nil)
        #expect(await world.runs.get(conversationID: "c2", runs[2].id) == nil)
        #expect(await !world.runs.cancel(conversationID: "c2", runs[2].id))

        let running = try await world.start("echo started; sleep 600", conversation: "c3")
        try await world.wait(for: "started", in: running, conversation: "c3")
        await world.runs.remove(conversationID: "c3")
        for _ in 0..<100 where await world.runs.get(conversationID: "c3", running.id) != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await world.runs.get(conversationID: "c3", running.id) == nil, "止まったら記録も捨てる")
        await world.cleanUp()
    }

    @Test("コードのファイルは終わったら消す")
    func removesCodeFile() async throws {
        let world = try await World.make()
        _ = try await world.run("true")
        let files = try FileManager.default.contentsOfDirectory(atPath: world.directory.appending(path: "runs").path)
        #expect(files.isEmpty)
        await world.cleanUp()
    }

    @Test("文字の途中で切れた末尾のバイトは次に回す。途中の読めないバイトは置き換える")
    func decodePrefix() {
        let a = Array("あ".utf8)
        #expect(ConversationRuns.decodePrefix(Data()) == ("", 0))
        #expect(ConversationRuns.decodePrefix(Data(a.prefix(2))) == ("", 0))
        #expect(ConversationRuns.decodePrefix(Data([0x61] + a.prefix(1))) == ("a", 1))
        #expect(ConversationRuns.decodePrefix(Data([0x61] + a)) == ("aあ", 4))
        let broken = ConversationRuns.decodePrefix(Data([0x61, 0xFF, 0xFE, 0xFD, 0xFC, 0x62]))
        #expect(broken.1 == 6 && broken.0.hasPrefix("a") && broken.0.hasSuffix("b"))
    }
}

@Suite("RunShell（実行のシェルの行と出力の読み分け）")
struct RunShellTests {
    @Test("札からシェルを選ぶ。ログインシェルと同じ種類ならその実行ファイル")
    func resolve() {
        #expect(RunShell.resolve(language: "sh", loginShell: "/opt/homebrew/bin/fish", path: nil)! == (.bash, "/bin/bash"))
        #expect(RunShell.resolve(language: "zsh", loginShell: "/usr/local/bin/zsh", path: nil)! == (.zsh, "/usr/local/bin/zsh"))
        #expect(RunShell.resolve(language: "Shell", loginShell: "/bin/zsh", path: nil)! == (.zsh, "/bin/zsh"))
        #expect(RunShell.resolve(language: "console", loginShell: "/bin/tcsh", path: nil)! == (.bash, "/bin/bash"))
        #expect(RunShell.resolve(language: "shell", loginShell: nil, path: nil)! == (.bash, "/bin/bash"))
        #expect(RunShell.resolve(language: "fish", loginShell: "/bin/zsh", path: "/nowhere") == nil)
        #expect(RunShell.resolve(language: "python", loginShell: "/bin/zsh", path: nil) == nil)
    }

    @Test("目印・DA1・文に分ける。制御の列と CR は落とし、切れ目をまたいでも続きから読む")
    func scanner() {
        var scanner = RunShellScanner()
        let input = Data("prompt\u{1b}]7;file://x\u{07}\u{1e}TB:S:a1\u{1e}あ\u{1b}[31mred\u{1b}[0m\r\n\u{1b}(Bok\u{1b}[c\u{1e}TB:E:a1:130\u{1e}\u{1e}TB:X:a1\u{1e}".utf8)
        var pieces: [RunShellScanner.Piece] = []
        // 1 バイトずつ渡しても同じに読む
        for byte in input { pieces += scanner.feed(Data([byte])) }
        var merged: [RunShellScanner.Piece] = []
        for piece in pieces {
            if case .text(let data) = piece, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + data)
            } else {
                merged.append(piece)
            }
        }
        #expect(
            merged == [
                .text(Data("prompt".utf8)), .mark(.start("a1")), .text(Data("あred\nok".utf8)), .query, .mark(.end("a1", 130)),
            ])
        var whole = RunShellScanner()
        #expect(whole.feed(input) == merged)
    }

    @Test("Run の行はファイルのパスを引用する（空白と引用符を含むパス）")
    func quoting() {
        let bash = String(decoding: RunShell.bash.runLine(id: "a1", file: "/x/Application Support/it's"), as: UTF8.self)
        #expect(bash.contains(". '/x/Application Support/it'\\''s' </dev/null"))
        let fish = String(decoding: RunShell.fish.runLine(id: "a1", file: "/x/it's"), as: UTF8.self)
        #expect(fish.contains("source '/x/it\\'s' </dev/null"))
    }
}
