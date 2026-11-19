import ArgumentParser
import Foundation
import TaskboardDaemon
import TaskboardKit

/// `~/Library/LaunchAgents/uk.whatn.taskboardd.plist`（daemon）と `uk.whatn.taskboard-agent-host.plist`（host の会話の CLI とシェルを持つ host）を
/// 作って load し、health で確認する。host を daemon の子にしないのは、daemon を入れ替えるたびに会話が全部落ちるため。
/// 前の版が入れた herdr の server の job（`uk.whatn.taskboard-herdr`）が残っていれば止めて plist を消す
struct InstallLaunchd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-launchd",
        abstract: "LaunchAgent を登録して daemon をログイン時に常駐させる")

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "plist を書くだけで load しない")
    var noLoad = false

    static let label = LaunchdJobRepair.daemonLabel
    static let herdrLabel = LaunchdJobRepair.herdrLabel
    static let agentHostLabel = LaunchdJobRepair.agentHostLabel

    func run() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path), executable.path.hasPrefix("/") else {
            throw ValidationError("実行ファイルの絶対パスを解決できない: \(executable.path)。絶対パスで起動して実行する")
        }
        let paths = try Paths(directory: common.supportDirectoryURL)
        try FileManager.default.createDirectory(at: paths.logDirectory, withIntermediateDirectories: true)

        // launchd の既定 PATH には Homebrew や ~/.local/bin が無いので、ログインシェルの PATH を渡す（取れなければ今の PATH）。
        // daemon がログインシェルの環境を取れないときはこの PATH で会話を起こすので、gh だけでなく mise の shims も要る。
        // 実行したシェルの PATH に頼ると、ssh や会話の中から実行したときに短い PATH が書かれる
        let environment = ProcessInfo.processInfo.environment
        let loginPath = await LoginShellEnvironment.capture(shell: LoginShell.path ?? "/bin/zsh", timeout: .seconds(30))?["PATH"]
        if loginPath == nil { FileHandle.standardError.write(Data("warning: ログインシェルの PATH を取れない。今の PATH を書く\n".utf8)) }
        var pathDirs = Self.launchdPath(loginPath ?? environment["PATH"] ?? "", home: NSHomeDirectory()).split(separator: ":").map(String.init)
        for dir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !pathDirs.contains(dir) { pathDirs.append(dir) }
        for tool in ["gh"] {
            if let found = which(tool) {
                let dir = (found as NSString).deletingLastPathComponent
                if !pathDirs.contains(dir) { pathDirs.insert(dir, at: 0) }
            } else {
                FileHandle.standardError.write(Data("warning: \(tool) が PATH に無い。daemon から使えない\n".utf8))
            }
        }

        var arguments = [executable.path, "serve", "--port", String(common.port)]
        if let supportDir = common.supportDir {
            arguments += ["--support-dir", supportDir]
        }

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            // アプリの画面に答える役なので、アプリと同じ扱い（制限なし）にする。Background だと負荷の高い間に CPU を後回しにされ、
            // アプリの ping（10 秒）に答えられずに接続が切れていた
            "ProcessType": "Interactive",
            "EnvironmentVariables": ["PATH": pathDirs.joined(separator: ":"), "HOME": NSHomeDirectory()],
            "StandardOutPath": paths.logDirectory.appending(path: "taskboardd.out.log").path,
            "StandardErrorPath": paths.logDirectory.appending(path: "taskboardd.err.log").path,
        ]
        let agents = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appending(path: "\(Self.label).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
        print("wrote \(plistURL.path)")

        // host は、このユーザーが画面にログインしていれば（ssh から実行しても）Aqua に置く。Background からは login keychain が
        // ロックされて見え、Keychain にだけ入る MCP の OAuth（/mcp で認証したもの）が会話で読めない。画面にログインしていない Mac
        // （FileVault で自動ログインできない）は Aqua でも Keychain が開かないので、~/.claude/.credentials.json を読む Background に置く
        let consoleOwner = (try? FileManager.default.attributesOfItem(atPath: "/dev/console")[.ownerAccountID] as? NSNumber)?.uint32Value
        let background = consoleOwner != getuid()
        let uid = getuid()
        let hostDomain = background ? "user/\(uid)" : "gui/\(uid)"
        // シェルは host の環境を引き継がない（daemon がログインシェルから取った環境を渡す）が、host 自身のロケールと PATH のために揃えておく。
        // launchd の既定の環境には SHELL・LANG が無く、PATH も短い。ssh から実行すると LANG が空のことがある（秘密を含みうる他の変数は渡さない）
        var hostEnvironment = ["HOME": NSHomeDirectory(), "PATH": pathDirs.joined(separator: ":")]
        hostEnvironment["SHELL"] = LoginShell.path ?? environment["SHELL"]
        hostEnvironment["LANG"] = environment["LANG"].flatMap { $0.uppercased().contains("UTF-8") ? $0 : nil } ?? "en_US.UTF-8"

        var hostArguments = [executable.path, "agent-host"]
        if let supportDir = common.supportDir { hostArguments += ["--support-dir", supportDir] }
        var hostPlist: [String: Any] = [
            "Label": Self.agentHostLabel,
            "ProgramArguments": hostArguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "EnvironmentVariables": hostEnvironment,
            "StandardOutPath": paths.logDirectory.appending(path: "agent-host.out.log").path,
            "StandardErrorPath": paths.logDirectory.appending(path: "agent-host.err.log").path,
        ]
        if background { hostPlist["LimitLoadToSessionType"] = "Background" }
        let hostPlistURL = agents.appending(path: "\(Self.agentHostLabel).plist")
        let previousHostPlist = (try? Data(contentsOf: hostPlistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? NSDictionary
        }
        let hostPlistChanged = previousHostPlist.map { !$0.isEqual(to: hostPlist) } ?? true
        try PropertyListSerialization.data(fromPropertyList: hostPlist, format: .xml, options: 0).write(to: hostPlistURL)
        print("wrote \(hostPlistURL.path)")
        if noLoad { return }

        let domain = "gui/\(uid)"
        _ = run("/bin/launchctl", ["bootout", domain, plistURL.path])
        let otherDomain = background ? "gui/\(uid)" : "user/\(uid)"
        retireHerdr(agents: agents, domains: [domain, "user/\(uid)"])
        try await loadAgentHost(plist: hostPlistURL, changed: hostPlistChanged, domain: hostDomain, otherDomain: otherDomain, paths: paths)
        let bootstrap = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard bootstrap.status == 0 else {
            throw ValidationError("launchctl bootstrap failed (\(bootstrap.status)): \(bootstrap.output)")
        }

        let client = DaemonClient(endpoint: try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL))
        for _ in 0..<20 {
            if let health = try? await client.health(), health.ok {
                print("daemon is up: version \(health.daemonVersion), machine \(health.machineID.rawValue)")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ValidationError("daemon did not answer /v1/health within 10s. see \(paths.logDirectory.path)")
    }

    /// 前の版の herdr の server の job を、読み込まれている domain から降ろして plist を消す（中のシェルも終わる）。無ければ何もしない
    private func retireHerdr(agents: URL, domains: [String]) {
        for domain in domains where run("/bin/launchctl", ["print", "\(domain)/\(Self.herdrLabel)"]).status == 0 {
            print("stopping \(Self.herdrLabel) in \(domain)")
            _ = run("/bin/launchctl", ["bootout", "\(domain)/\(Self.herdrLabel)"])
        }
        let plist = agents.appending(path: "\(Self.herdrLabel).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            try? FileManager.default.removeItem(at: plist)
            print("removed \(plist.path)")
        }
    }

    /// host は入れ替えると子の会話が止まる。動いていれば、plist が変わって、しかも動いている会話が無いときだけ入れ替える
    /// （実行ファイルの更新は、protocol の版が変わったときに daemon が drain を送って取り込ませる）
    private func loadAgentHost(plist: URL, changed: Bool, domain: String, otherDomain: String, paths: Paths) async throws {
        let inOther = run("/bin/launchctl", ["print", "\(otherDomain)/\(Self.agentHostLabel)"]).status == 0
        let inDomain = run("/bin/launchctl", ["print", "\(domain)/\(Self.agentHostLabel)"]).status == 0
        if inOther || (inDomain && changed) {
            switch await AgentHostServer.liveChildren(supportDirectory: paths.directory) {
            case .some(let live) where live > 0:
                print("\(Self.agentHostLabel) は会話を \(live) 本持っているので入れ替えない。会話を止めてから install-launchd をもう一度実行する")
                return
            case .some:
                break
            case .none:
                // 版の違う host（会話の数を数えられない）や応答の無い host を降ろすと、子が親を失い、次の host に止められる。
                // 版の違う host は daemon が drain を送って、会話が全部終わってから入れ替える
                if await AgentHostServer.isListening(supportDirectory: paths.directory) {
                    print("\(Self.agentHostLabel) の会話の数を確かめられないので入れ替えない。会話が全部終わってから install-launchd をもう一度実行する")
                    return
                }
            }
            _ = run("/bin/launchctl", ["bootout", "\(inOther ? otherDomain : domain)/\(Self.agentHostLabel)"])
            try await Task.sleep(for: .seconds(1))
        } else if inDomain {
            return
        }
        let started = run("/bin/launchctl", ["bootstrap", domain, plist.path])
        guard started.status == 0 else {
            throw ValidationError("launchctl bootstrap failed (\(started.status)): \(started.output)")
        }
    }

    /// launchd の plist に書く PATH。mise の版ごとの置き場（`installs/<tool>/<版>`）を外し、最初に外した位置に shims を置く
    /// （版を書くと、mise で版を上げても plist を書き直すまで古い版が動く）。並びと重複の除去のほかは変えない
    static func launchdPath(_ path: String, home: String) -> String {
        let mise = "\(home)/.local/share/mise"
        let shims = "\(mise)/shims"
        var result: [String] = []
        var shimsAt: Int?
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty && !result.contains(dir) {
            if dir.hasPrefix("\(mise)/installs/") {
                if shimsAt == nil { shimsAt = result.count }
            } else if dir != shims {
                result.append(dir)
            } else if shimsAt == nil {
                shimsAt = result.count
            }
        }
        if let shimsAt { result.insert(shims, at: shimsAt) }
        return result.joined(separator: ":")
    }

    private func which(_ tool: String) -> String? {
        let result = run("/usr/bin/which", [tool])
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !path.isEmpty ? path : nil
    }

    private func run(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
