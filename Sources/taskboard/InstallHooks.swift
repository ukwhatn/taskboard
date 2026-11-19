import ArgumentParser
import Foundation
import TaskboardDaemon

/// `~/.claude/settings.json` の hooks を taskboard に向ける。
/// backup → 構造的に編集 → JSON として読み直す → `taskboard hook session` を空打ち → 失敗なら backup から復元。
struct InstallHooks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-hooks",
        abstract: "Claude Code の hooks（SessionStart / Stop / PostToolUse / UserPromptSubmit）を taskboard に向け、taskherd-sync と kairan の hook を外す")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "settings.json のパス（既定 ~/.claude/settings.json。CLAUDE_CONFIG_DIR があればその下）")
    var settings: String?

    @Flag(name: .long, help: "書き換えずに差分だけ出す")
    var dryRun = false

    func run() async throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard executable.path.hasPrefix("/") else { throw ValidationError("実行ファイルの絶対パスを解決できない。絶対パスで起動する") }
        let settingsURL = Self.settingsURL(override: settings)
        let paths = try Paths(directory: common.supportDirectoryURL)
        let link = try Self.installSymlink(to: executable, dryRun: dryRun)
        let edit = try HooksEdit.load(settingsURL)
        let plan = edit.plan()
        for line in plan.summary { print(line) }
        if plan.unchanged {
            print("hooks は既に taskboard 向き。変更なし")
            return
        }
        if dryRun { return }

        let backup = try await Self.apply(plan: plan, edit: edit, settingsURL: settingsURL, backupDirectory: paths.backupDirectory) {
            try await Self.probe(executable: link, common: common)
        }
        print("backup: \(backup.path)")
        print("wrote \(settingsURL.path)")
    }

    /// settings.json は複数の Mac で同期するので、hook の command には機械ごとに違う build のパスを書かず
    /// `$HOME/.local/bin/taskboard` を書く。その symlink をここで張る（既にあれば向け直す。symlink でない実体があれば止まる）。
    static func installSymlink(to executable: URL, dryRun: Bool = false) throws -> URL {
        let link = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".local/bin/taskboard")
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: link.path) {
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let current = try fm.destinationOfSymbolicLink(atPath: link.path)
                if current == executable.path { return link }
                print("symlink: \(link.path) → \(executable.path)（前は \(current)）")
                if !dryRun { try fm.removeItem(at: link) }
            } else {
                throw ValidationError("\(link.path) が symlink でない。手で退避してから実行する")
            }
        } else {
            print("symlink: \(link.path) → \(executable.path)")
        }
        if dryRun { return link }
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: executable)
        return link
    }

    /// backup → 書く → 読み直す → 空打ち。どこかで失敗したら backup から戻して投げる。戻した backup の URL を返す。
    static func apply(
        plan: HooksEdit.Plan, edit: HooksEdit, settingsURL: URL, backupDirectory: URL, probe: () async throws -> Int32
    ) async throws -> URL {
        let backup = try edit.backup(to: backupDirectory)
        do {
            try plan.write(to: settingsURL)
            // 読み直して JSON として壊れていないことを確かめる
            _ = try HooksEdit.load(settingsURL)
            // 空打ち: hook の入口が動くか（daemon が居なくても exit 0 で返る契約）
            let status = try await probe()
            guard status == 0 else { throw ValidationError("`taskboard hook session` の空打ちが \(status) で終わった") }
        } catch {
            try Self.restore(backup, to: settingsURL)
            throw ValidationError("hooks の書き換えに失敗したので backup から戻した: \(error)")
        }
        return backup
    }

    static func restore(_ backup: URL, to url: URL) throws {
        try Data(contentsOf: backup).write(to: url, options: .atomic)
    }

    static func settingsURL(override: String?) -> URL {
        if let override { return URL(fileURLWithPath: (override as NSString).expandingTildeInPath) }
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude", directoryHint: .isDirectory)
        return base.appending(path: "settings.json")
    }

    static func probe(executable: URL, common: CommonOptions) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        var args = ["hook", "session", "--port", String(common.port)]
        if let dir = common.supportDir { args += ["--support-dir", dir] }
        process.arguments = args
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// settings.json の hooks 部分の編集。他のキーには触らない。
struct HooksEdit {
    static let taskherdMarker = "taskherd-sync.py"
    static let kairanMarker = "kairan hook stop"
    static let ourMarker = "taskboard\" hook "
    /// Stop hook は人の回答を待つので長く、`asyncRewake` でモデルを止めない（kairan と同じ値）
    static let stopTimeout = 3900
    static let stopStatusMessage = "taskboard: 回答を待っています"
    /// hook の command に書くパス。`$HOME` は hook を動かすシェルが展開する
    static let portableExecutable = "$HOME/.local/bin/taskboard"

    /// 印のファイル（`FeedbackMarkers`）の置き場。settings.json は複数の Mac で同期するので、既定の support ディレクトリを `$HOME` から書く
    static let portablePendingDirectory = "$HOME/Library/Application Support/taskboard/" + FeedbackMarkers.directoryName

    /// settings.json は taskboard を入れていない Mac にも同期されるので、実行ファイルがあるときだけ呼ぶ（無ければ exit 0 で黙る）
    static func command(executable: String, sub: String) -> String {
        let quoted = "\"\(executable)\""
        return "if [ -x \(quoted) ]; then \(quoted) hook \(sub); else exit 0; fi"
    }

    /// ツールのたびに走る hook。このセッションの印があるときだけ taskboard を起こす（無ければシェルの test だけで終わる）
    static func pendingCommand(executable: String, sub: String) -> String {
        let quoted = "\"\(executable)\""
        let marker = "\"\(portablePendingDirectory)/$CLAUDE_CODE_SESSION_ID\""
        return "if [ -n \"$CLAUDE_CODE_SESSION_ID\" ] && [ -e \(marker) ] && [ -x \(quoted) ]; then \(quoted) hook \(sub); else exit 0; fi"
    }

    var root: [String: Any]
    let originalData: Data
    let url: URL

    static func load(_ url: URL) throws -> HooksEdit {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError("\(url.path) の最上位がオブジェクトでない")
        }
        return HooksEdit(root: root, originalData: data, url: url)
    }

    func backup(to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let target = directory.appending(path: "settings.json.\(f.string(from: Date())).bak")
        try originalData.write(to: target)
        return target
    }

    struct Plan {
        var root: [String: Any]
        var summary: [String]
        var unchanged: Bool

        func write(to url: URL) throws {
            try Data((JSONPretty.render(root) + "\n").utf8).write(to: url, options: .atomic)
        }
    }

    /// taskherd-sync と kairan の hook を外し、SessionStart・Stop・PostToolUse・UserPromptSubmit に taskboard を足す。
    /// 同じ sub command の taskboard hook が既にあれば、command と設定（timeout / asyncRewake）が同じなら触らず、違えばその場で差し替える。
    func plan(executable: String = Self.portableExecutable) -> Plan {
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        var summary: [String] = []
        var changed = false

        // 1. taskherd-sync.py と kairan の hook を全イベントから外す
        for (marker, label) in [(Self.taskherdMarker, "taskherd-sync"), (Self.kairanMarker, "kairan")] {
            for (event, value) in hooks {
                guard var groups = value as? [[String: Any]] else { continue }
                var removed = 0
                groups = groups.compactMap { group in
                    var group = group
                    let inner = (group["hooks"] as? [[String: Any]]) ?? []
                    let kept = inner.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                    removed += inner.count - kept.count
                    if kept.isEmpty { return nil }
                    group["hooks"] = kept
                    return group
                }
                if removed > 0 {
                    changed = true
                    summary.append("\(event): \(label) の hook を \(removed) 個外す")
                    if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
                }
            }
        }

        // 2. taskboard の hook を足す
        let entries: [(event: String, matcher: String?, sub: String, hook: [String: Any])] = [
            ("SessionStart", "*", "session", ["type": "command", "command": Self.command(executable: executable, sub: "session"), "timeout": 10]),
            (
                "Stop", nil, "stop",
                [
                    "type": "command", "command": Self.command(executable: executable, sub: "stop"), "timeout": Self.stopTimeout, "asyncRewake": true,
                    "statusMessage": Self.stopStatusMessage,
                ]
            ),
            ("PostToolUse", nil, "tool", ["type": "command", "command": Self.pendingCommand(executable: executable, sub: "tool"), "timeout": 10]),
            ("UserPromptSubmit", nil, "prompt", ["type": "command", "command": Self.pendingCommand(executable: executable, sub: "prompt"), "timeout": 10]),
        ]
        for entry in entries {
            let command = entry.hook["command"] as? String ?? ""
            let sub = entry.sub
            var groups = (hooks[entry.event] as? [[String: Any]]) ?? []
            var present = false
            var replaced = 0
            groups = groups.map { group in
                var group = group
                group["hooks"] = ((group["hooks"] as? [[String: Any]]) ?? []).map { hook in
                    let existing = (hook["command"] as? String) ?? ""
                    // 素の形（`"<path>" hook stop`）も、存在確認で包んだ形も同じ hook とみなす
                    let ours = existing.contains(Self.ourMarker) && existing.contains(" hook " + sub)
                    guard ours else { return hook }
                    if Self.sameHook(hook, entry.hook) {
                        present = true
                        return hook
                    }
                    // build のパスを直書きした古い形や、timeout / asyncRewake が違うものはその場で差し替える
                    replaced += 1
                    present = true
                    return entry.hook
                }
                return group
            }
            if replaced > 0 {
                changed = true
                summary.append("\(entry.event): taskboard の hook を \(replaced) 個差し替える（\(Self.describe(entry.hook))）")
            }
            if present {
                hooks[entry.event] = groups
                continue
            }
            var group: [String: Any] = ["hooks": [entry.hook]]
            if let matcher = entry.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[entry.event] = groups
            changed = true
            summary.append("\(entry.event): `\(command)` を足す（\(Self.describe(entry.hook))）")
        }

        var root = root
        root["hooks"] = hooks
        return Plan(root: root, summary: summary, unchanged: !changed)
    }

    /// command・timeout・asyncRewake・statusMessage が同じか（type は command 固定）
    static func sameHook(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        JSONPretty.render(a) == JSONPretty.render(b)
    }

    static func describe(_ hook: [String: Any]) -> String {
        var parts = ["timeout \(hook["timeout"] ?? 0)"]
        if hook["asyncRewake"] as? Bool == true { parts.append("asyncRewake") }
        return parts.joined(separator: ", ")
    }
}

/// Claude Code が settings.json を書く形（2 スペース、`": "`、スラッシュはそのまま）に合わせる。
/// JSONSerialization の prettyPrinted は `" : "` を使い、ファイル全体の差分が膨らむ。キー順は辞書なので揃えられず、辞書順に固定する。
enum JSONPretty {
    static func render(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case let dict as [String: Any]:
            if dict.isEmpty { return "{}" }
            let body = dict.keys.sorted().map { key in "\(inner)\(string(key)): \(render(dict[key]!, indent: indent + 1))" }
            return "{\n" + body.joined(separator: ",\n") + "\n\(pad)}"
        case let array as [Any]:
            if array.isEmpty { return "[]" }
            let body = array.map { "\(inner)\(render($0, indent: indent + 1))" }
            return "[\n" + body.joined(separator: ",\n") + "\n\(pad)]"
        case let text as String:
            return string(text)
        case let number as NSNumber:
            // NSNumber の Bool は CFBoolean。それ以外は数
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        case is NSNull:
            return "null"
        default:
            return string(String(describing: value))
        }
    }

    private static func string(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }
}
