import ArgumentParser
import Foundation
import TaskboardDaemon
import TaskboardKit

/// taskherd から taskboard への切り替え（マシンごとに 1 回）。
/// (1) hooks を taskboard に向ける → (2) 動いている taskherd 系プロセスが終わるのを待つ → (3) lock を取って最終 import。
/// (3) が失敗したら (1) の backup から hooks を戻す。この順なら lock 解放後に旧 hook が書く経路が無い。
struct Cutover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "既存ツールから切り替える", subcommands: [Taskherd.self])

    struct Taskherd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "hooks を切り替えて taskherd の tasks.json を最終取り込みする")

        @OptionGroup var common: CommonOptions

        @Option(name: .long, help: "taskherd の tasks.json（既定 ~/.local/state/taskherd/tasks.json）")
        var file: String?

        @Option(name: .long, help: "taskherd の config.toml（既定 ~/.config/taskherd/config.toml）")
        var config: String?

        @Option(name: .long, help: "取り込み先のボード名")
        var board: String = "default"

        @Option(name: .long, help: "taskherd 系プロセスの終了を待つ上限（秒）")
        var waitSeconds: Int = 60

        func run() async throws {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            let settingsURL = InstallHooks.settingsURL(override: nil)
            let paths = try Paths(directory: common.supportDirectoryURL)

            // (1) hooks（command は $HOME/.local/bin/taskboard。symlink を張ってから）
            let link = try InstallHooks.installSymlink(to: executable)
            let edit = try HooksEdit.load(settingsURL)
            let plan = edit.plan()
            var backup: URL?
            if plan.unchanged {
                print("hooks: 既に taskboard 向き")
            } else {
                for line in plan.summary { print("hooks: \(line)") }
                backup = try await InstallHooks.apply(plan: plan, edit: edit, settingsURL: settingsURL, backupDirectory: paths.backupDirectory) {
                    try await InstallHooks.probe(executable: link, common: common)
                }
                print("hooks: wrote \(settingsURL.path)（backup \(backup!.lastPathComponent)）")
            }

            // (2) 起動済みの taskherd-sync / taskherd が終わるのを待つ
            let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
            while Date() < deadline {
                let running = Self.runningTaskherdProcesses()
                if running.isEmpty { break }
                print("waiting for taskherd processes: \(running.joined(separator: ", "))")
                try await Task.sleep(for: .seconds(2))
            }
            let leftover = Self.runningTaskherdProcesses()
            if !leftover.isEmpty {
                if let backup { try InstallHooks.restore(backup, to: settingsURL) }
                throw ValidationError("taskherd 系プロセスが \(waitSeconds) 秒以内に終わらない: \(leftover.joined(separator: ", "))。hooks は戻した")
            }

            // (3) 最終 import（lock を取って読む）
            do {
                var importer = Import.Taskherd()
                importer.common = common
                importer.file = file
                importer.config = config
                importer.board = board
                try await importer.run()
            } catch {
                if let backup { try InstallHooks.restore(backup, to: settingsURL) }
                throw ValidationError("最終取り込みに失敗したので hooks を戻した: \(error)")
            }

            print("cutover done. 以後 taskherd の tasks.json は書かれない（CLI は残るが、hook は taskboard を呼ぶ）")
            print("次: claude mcp add --scope user --transport stdio taskboard -- \(link.path) mcp")
        }

        /// `taskherd-sync.py` と `taskherd` の実行中プロセス（自分は除く）。
        static func runningTaskherdProcesses() -> [String] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,command="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let me = ProcessInfo.processInfo.processIdentifier
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                guard let space = text.firstIndex(of: " ") else { return nil }
                guard let pid = Int32(text[..<space]), pid != me else { return nil }
                let command = text[text.index(after: space)...]
                let name = command.split(separator: " ").first.map(String.init) ?? ""
                let base = (name as NSString).lastPathComponent
                if command.contains("taskherd-sync.py") || base == "taskherd" {
                    return "\(pid) \(command.prefix(60))"
                }
                return nil
            }
        }
    }
}
