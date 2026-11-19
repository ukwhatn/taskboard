import Foundation
import TaskboardKit

/// チャットの入力欄の `/` の候補（`GET /v1/commands?cwd=`）。このマシンの Claude Code が読む skill（`skills/<名前>/SKILL.md`）と
/// command（`commands/<名前>.md`）を、作業ディレクトリとその親（ホームの手前まで）の `.claude`、`~/.claude` の順に集める。
/// 同じ名前は先に見つけた方（作業ディレクトリに近い方）を残す。plugin の skill は読まない。
/// その後に Claude Code の組み込み（`BuiltinSlashCommands`。固定の一覧で、版が上がったら足す）を、同じ名前の無いものだけ足す
enum SlashCommandCatalog {
    /// 説明は 1 行にして、この長さで切る
    static let descriptionLimit = 200

    static func list(cwd: String?, home: String, builtins: [SlashCommand] = BuiltinSlashCommands.all, fileManager: FileManager = .default) -> [SlashCommand] {
        var roots: [(path: String, scope: SlashCommand.Scope)] = projectDirectories(cwd: cwd, home: home).map { ($0 + "/.claude", .project) }
        roots.append((home + "/.claude", .user))
        var seen = Set<String>()
        var result: [SlashCommand] = []
        for root in roots {
            for command in skills(in: root.path + "/skills", scope: root.scope, fileManager: fileManager)
                + commands(in: root.path + "/commands", scope: root.scope, fileManager: fileManager)
            where seen.insert(command.name).inserted {
                result.append(command)
            }
        }
        result += builtins.filter { seen.insert($0.name).inserted }
        return result.sorted { $0.name.compare($1.name, options: [.caseInsensitive, .numeric]) == .orderedAscending }
    }

    /// 作業ディレクトリから親へ。ホームと `/` は含めない（ホームの `.claude` は利用者の分として別に読む）
    static func projectDirectories(cwd: String?, home: String) -> [String] {
        guard var path = cwd.map({ ($0 as NSString).standardizingPath }), path.hasPrefix("/") else { return [] }
        let home = (home as NSString).standardizingPath
        var result: [String] = []
        while path != "/", path != home, !path.isEmpty {
            result.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        return result
    }

    private static func skills(in directory: String, scope: SlashCommand.Scope, fileManager: FileManager) -> [SlashCommand] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix("."), let text = try? String(contentsOfFile: "\(directory)/\(name)/SKILL.md", encoding: .utf8) else { return nil }
            let fields = frontMatter(text)
            if fields["user-invocable"]?.lowercased() == "false" { return nil }
            let skillName = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name
            return SlashCommand(name: skillName, description: oneLine(fields["description"] ?? ""), kind: .skill, scope: scope)
        }
    }

    private static func commands(in directory: String, scope: SlashCommand.Scope, fileManager: FileManager) -> [SlashCommand] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".md"), let text = try? String(contentsOfFile: "\(directory)/\(name)", encoding: .utf8) else { return nil }
            let fields = frontMatter(text)
            // 説明が無ければ本文の最初の行
            let description = fields["description"] ?? body(text).split(separator: "\n").first.map(String.init) ?? ""
            return SlashCommand(name: String(name.dropLast(3)), description: oneLine(description), kind: .command, scope: scope)
        }
    }

    /// 先頭の `---` から次の `---` までの `key: value`。`>` と `|` の続きの行は 1 つの値につなぐ
    static func frontMatter(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.first == "---" else { return [:] }
        var fields: [String: String] = [:]
        var block: String?
        for line in lines.dropFirst() {
            if line == "---" { break }
            if let key = block, line.hasPrefix(" ") || line.hasPrefix("\t") {
                let part = line.trimmingCharacters(in: .whitespaces)
                fields[key] = fields[key].map { $0.isEmpty ? part : $0 + " " + part } ?? part
                continue
            }
            block = nil
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == "|" || value == ">-" || value == "|-" {
                block = key
                value = ""
            } else if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return fields
    }

    private static func body(_ text: String) -> String {
        guard text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > descriptionLimit ? String(line.prefix(descriptionLimit - 1)) + "…" : line
    }
}
