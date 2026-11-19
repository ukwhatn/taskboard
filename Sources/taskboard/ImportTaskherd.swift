import ArgumentParser
import Darwin
import Foundation
import TaskboardDaemon
import TaskboardKit

/// `taskboard import taskherd`: taskherd の `tasks.json` を lock を取って読み、動いている daemon に取り込ませる。
struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "既存ツールのデータを取り込む", subcommands: [Taskherd.self])

    struct Taskherd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "taskherd の tasks.json を daemon のボードに取り込む（冪等）")

        @OptionGroup var common: CommonOptions

        @Option(name: .long, help: "tasks.json のパス（既定: ~/.local/state/taskherd/tasks.json）")
        var file: String?

        @Option(name: .long, help: "config.toml のパス（既定: ~/.config/taskherd/config.toml）。列の並びを読む")
        var config: String?

        @Option(name: .long, help: "取り込み先のボード名")
        var board: String = "default"

        func run() async throws {
            let home = NSHomeDirectory()
            let tasksURL = URL(fileURLWithPath: file ?? "\(home)/.local/state/taskherd/tasks.json")
            let configURL = URL(fileURLWithPath: config ?? "\(home)/.config/taskherd/config.toml")
            let source = try TaskherdFiles.read(tasksURL: tasksURL, configURL: configURL)
            var request = TaskherdImportRequest(boardName: board, columns: source.columns, tasks: source.file.tasks)
            request.promptTemplate = source.sessionStart.promptTemplate
            request.columnTemplates = source.sessionStart.templates.isEmpty ? nil : source.sessionStart.templates
            let endpoint = try Daemon.localEndpoint(port: common.port, supportDirectory: common.supportDirectoryURL)
            let result = try await DaemonClient(endpoint: endpoint).importTaskherd(request)
            print("取り込み先ボード: \(board) (\(result.boardID))")
            var line = "追加 \(result.inserted) / 更新 \(result.updated) / 変更なし \(result.unchanged)"
            if result.keptLocal > 0 { line += " / daemon 側が新しいので据え置き \(result.keptLocal)" }
            print(line + "（元ファイル \(source.file.tasks.count) 件）")
            if source.sessionStart.promptTemplate != nil || !source.sessionStart.templates.isEmpty {
                print("起動プロンプト: ボード既定\(source.sessionStart.promptTemplate == nil ? "なし" : "あり") / 列の上書き \(source.sessionStart.templates.count) 件を取り込んだ")
            }
            // gh のアカウント対応（[github.accounts]）は daemon が PR を見るときに使う。空なら書かない
            if let toml = try? String(contentsOf: configURL, encoding: .utf8) {
                let accounts = GitHubAccounts.parseTaskherdConfig(toml)
                if !accounts.mapping.isEmpty {
                    let paths = try Paths(directory: common.supportDirectoryURL)
                    try accounts.write(to: paths.githubAccountsFile)
                    print("gh のアカウント対応 \(accounts.mapping.count) 件を \(paths.githubAccountsFile.path) に書いた（daemon は次の巡回から使う）")
                }
            }
        }
    }
}

/// taskherd のファイル読み。書き込み側（`store.go` の `Update`）と同じ `tasks.lock` を flock で取る。
enum TaskherdFiles {
    struct File: Decodable {
        var version: Int
        var tasks: [TaskherdImportRequest.TaskherdTask]

        enum CodingKeys: String, CodingKey {
            case version, tasks
        }
    }

    struct Source {
        var file: File
        var columns: [BoardColumn]
        var sessionStart = SessionStartConfig()
    }

    /// taskherd の `[session_start]`。`prompt_template` がボード既定、`[session_start.templates]` が列ごとの上書き。
    struct SessionStartConfig: Equatable {
        var promptTemplate: String?
        var templates: [String: String] = [:]
    }

    static func read(tasksURL: URL, configURL: URL, lockTimeout: TimeInterval = 5) throws -> Source {
        let lockURL = tasksURL.deletingLastPathComponent().appending(path: "tasks.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw TaskherdReadError.lockOpenFailed(lockURL.path, errno) }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw TaskherdReadError.lockTimeout(lockURL.path) }
            usleep(50_000)
        }
        defer { flock(fd, LOCK_UN) }

        let data = try Data(contentsOf: tasksURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = plain.date(from: text) ?? fractional.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "日時を読めない: \(text)"))
        }
        let file = try decoder.decode(File.self, from: data)
        let toml = try? String(contentsOf: configURL, encoding: .utf8)
        return Source(file: file, columns: toml.map(parseColumns) ?? [], sessionStart: toml.map(parseSessionStart) ?? SessionStartConfig())
    }

    /// `[[columns]]` の表だけを読む最小の TOML 読み。ラベルは taskboard の日本語（99_history 2026-10-02 の裁定）に置き換え、未知の id は config のラベル。
    static func parseColumns(_ toml: String) -> [BoardColumn] {
        var columns: [BoardColumn] = []
        var current: [String: String]? = nil
        func flush() {
            guard let table = current, let id = table["id"] else { return }
            let standard = BoardColumn.standard.first { $0.id == id }
            columns.append(
                BoardColumn(
                    id: id, label: standard?.label ?? table["label"] ?? id,
                    kind: BoardColumn.Kind(rawValue: table["kind"] ?? "") ?? standard?.kind ?? .open, position: columns.count))
        }
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line == "[[columns]]" {
                flush()
                current = [:]
                continue
            }
            if line.hasPrefix("[") {
                flush()
                current = nil
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            current?[key] = value
        }
        flush()
        return columns
    }
}

extension TaskherdFiles {
    /// `[session_start]` と `[session_start.templates]` を読む。基本文字列（`"..."`、`\n` 等のエスケープ）と
    /// 複数行基本文字列（`"""`。開始直後の改行は捨てる）だけを扱う。
    static func parseSessionStart(_ toml: String) -> SessionStartConfig {
        var config = SessionStartConfig()
        var section: String? = nil
        var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[...]
        while let rawLine = lines.popFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section == "session_start" || section == "session_start.templates", let eq = line.firstIndex(of: "=") else { continue }
            let key = unquoteKey(line[..<eq].trimmingCharacters(in: .whitespaces))
            let rest = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let value: String
            if rest.hasPrefix("\"\"\"") {
                var body = String(rest.dropFirst(3))
                if let end = body.range(of: "\"\"\"") {
                    value = unescape(String(body[..<end.lowerBound]))
                } else {
                    var collected: [String] = []
                    if !body.isEmpty { collected.append(body) }
                    var closed = false
                    while let next = lines.popFirst() {
                        if let end = next.range(of: "\"\"\"") {
                            collected.append(String(next[..<end.lowerBound]))
                            closed = true
                            break
                        }
                        collected.append(next)
                    }
                    body = collected.joined(separator: "\n")
                    // 開始 """ 直後の改行は TOML の規則で捨てる
                    if rest == "\"\"\"", body.hasPrefix("\n") { body.removeFirst() }
                    value = closed ? unescape(body) : unescape(body)
                }
            } else if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
                value = unescape(String(rest[rest.index(after: rest.startIndex)..<close]))
            } else {
                continue
            }
            if section == "session_start", key == "prompt_template" {
                config.promptTemplate = value
            } else if section == "session_start.templates" {
                config.templates[key] = value
            }
        }
        return config
    }

    private static func unquoteKey(_ key: String) -> String {
        if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 { return String(key.dropFirst().dropLast()) }
        return key
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\", let next = iterator.next() else {
                out.append(ch)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default:
                out.append("\\")
                out.append(next)
            }
        }
        return out
    }
}

enum TaskherdReadError: Error, CustomStringConvertible {
    case lockOpenFailed(String, Int32)
    case lockTimeout(String)

    var description: String {
        switch self {
        case .lockOpenFailed(let path, let code): "lock ファイルを開けない: \(path) (errno \(code))"
        case .lockTimeout(let path): "taskherd が書き込み中で lock を取れない: \(path)"
        }
    }
}
