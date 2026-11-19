import ArgumentParser
import Foundation
import Logging
import TaskboardDaemon
import TaskboardKit

@main
struct TaskboardCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "taskboard",
        abstract: "taskboard daemon and tools",
        version: Daemon.version,
        subcommands: [
            Serve.self, MCPCommand.self, Hook.self, InstallHooks.self, Cutover.self, Import.self, Backup.self, Restore.self, Debug.self,
            InstallLaunchd.self, APNs.self, AgentHostCommand.self, ConversationCommand.self,
        ]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("port"), help: "daemon の listen port（既定 5780）")
    var portOption: Int?

    @Option(name: .long, help: "token と machine-id を置くディレクトリ")
    var supportDir: String?

    var port: Int { portOption ?? DaemonEndpoint.defaultPort }
    var supportDirectoryURL: URL? { supportDir.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// 引数で渡していない port と support ディレクトリを、会話を起こした daemon のもの（`DaemonLocation`）にする。
    /// 会話の中で daemon に代わって動く `mcp` と `hook` だけが使う（`serve`・`install-*` が使うと、会話のシェルから回したときに起こした daemon の値を取り違える）
    func inheritingDaemon(from environment: [String: String]) -> CommonOptions {
        guard let location = DaemonLocation(environment: environment) else { return self }
        var options = self
        if options.portOption == nil { options.portOption = location.port }
        if options.supportDir == nil { options.supportDir = location.supportDirectory }
        return options
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "daemon を前景で動かす（launchd からもこれを呼ぶ）")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "表示用のマシン名（既定はホスト名）")
    var machineName: String?

    func run() async throws {
        try await Daemon.run(
            DaemonConfiguration(
                port: common.port,
                supportDirectory: common.supportDirectoryURL,
                machineName: machineName))
    }
}

struct Debug: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "動作確認用の出力",
        subcommands: [State.self, Token.self]
    )

    struct State: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "動いている daemon の /v1/state を出す")
        @OptionGroup var common: CommonOptions

        func run() async throws {
            let endpoint = try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL)
            let snapshot = try await DaemonClient(endpoint: endpoint).snapshot()
            let encoder = WireJSON.encoder()
            encoder.outputFormatting.insert(.prettyPrinted)
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        }
    }

    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "token ファイルのパスを出す（中身は出さない）")
        @OptionGroup var common: CommonOptions

        func run() async throws {
            let paths = try Paths(directory: common.supportDirectoryURL)
            _ = try paths.loadOrCreateToken()
            print(paths.tokenFile.path)
        }
    }
}
