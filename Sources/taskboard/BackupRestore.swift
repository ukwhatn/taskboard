import ArgumentParser
import Foundation
import TaskboardDaemon
import TaskboardKit

/// `taskboard backup`: 動いている daemon の DB を開いて backup を取る（GRDB の online backup。daemon は止めなくてよい）。
struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "taskboard.db の backup を backups/ に取る（3 世代）")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "backup の名前に付ける印")
    var label: String?

    func run() async throws {
        let paths = try Paths(directory: common.supportDirectoryURL)
        let machineID = try paths.loadOrCreateMachineID()
        let store = try Store(databaseURL: paths.databaseFile, backupDirectory: paths.backupDirectory, machineID: machineID)
        let url = try store.backup(label: label)
        try store.close()
        let counts = try Store.verify(backupAt: url)
        print("\(url.path)（ボード \(counts.boards) / タスク \(counts.tasks)）")
        for remaining in try Store.listBackups(in: paths.backupDirectory) {
            print("  \(remaining.lastPathComponent)")
        }
    }
}

/// `taskboard restore --verify <file>`: backup を検証し、daemon が止まっていれば taskboard.db を置き換える。
struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "backup から taskboard.db を戻す。先に integrity_check とテーブルの有無を見る")

    @OptionGroup var common: CommonOptions

    @Argument(help: "backup ファイル（省略時は最新）")
    var file: String?

    @Flag(name: .long, help: "検証だけ行い、置き換えない")
    var verifyOnly = false

    func run() async throws {
        let paths = try Paths(directory: common.supportDirectoryURL)
        let source: URL
        if let file {
            source = URL(fileURLWithPath: file)
        } else {
            guard let latest = try Store.listBackups(in: paths.backupDirectory).last else {
                throw ValidationError("backups/ に backup が無い")
            }
            source = latest
        }
        let counts = try Store.verify(backupAt: source)
        print("検証 ok: \(source.path)（ボード \(counts.boards) / タスク \(counts.tasks)）")
        if verifyOnly { return }

        // daemon が動いていると WAL と食い違うので止めてもらう
        let endpoint = DaemonEndpoint.local(port: common.port, token: "")
        if (try? await DaemonClient(endpoint: endpoint).health()) != nil {
            throw ValidationError("daemon が \(common.port) で動いている。先に `launchctl bootout gui/$UID ~/Library/LaunchAgents/uk.whatn.taskboardd.plist` で止める")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.databaseFile.path) {
            let machineID = try paths.loadOrCreateMachineID()
            let current = try Store(databaseURL: paths.databaseFile, backupDirectory: paths.backupDirectory, machineID: machineID)
            let kept = try current.backup(label: "pre-restore")
            try current.close()
            print("置き換え前の DB を保存: \(kept.lastPathComponent)")
        }
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: paths.databaseFile.path + suffix)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try fm.copyItem(at: source, to: paths.databaseFile)
        print("復元した: \(paths.databaseFile.path)。daemon を起動し直す")
    }
}
