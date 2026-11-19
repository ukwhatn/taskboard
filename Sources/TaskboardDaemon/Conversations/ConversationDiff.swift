import Foundation
import TaskboardKit

/// 会話の作業フォルダの git の差分（`GET /v1/conversations/{id}/diff`）。cwd を含む git の根で、比べる相手は `ConversationDiffScope`
/// （すべての変更は HEAD（初めのコミットの前は空の tree）と作業フォルダ）。git は `GIT_OPTIONAL_LOCKS=0` で動かし（agent の git と index.lock を取り合わない）、1 回 5 秒で打ち切る
enum ConversationDiff {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    /// 1 ファイルの diff の上限
    static let fileLimit = 1 << 20
    static let statusLimit = 8 << 20
    /// 行を数える追跡していないファイル（1 つ 1MB まで・数の上限まで）。超えた分の行の数は nil
    static let untrackedCountLimit = 500
    static let timeout = GitCommand.defaultTimeout

    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    struct Status: Equatable {
        var branch: String?
        var initial = false
        var files: [ConversationDiffFile] = []
        /// `git status` の XY（index と作業フォルダ）。1 と 2 の行の path ごと
        var columns: [String: Columns] = [:]
        /// ブランチ全体と比べたブランチ。比べるブランチが無ければ nil
        var base: String?
    }

    struct Columns: Equatable {
        var index: Character
        var tree: Character
    }

    /// 比べる相手の diff の引数（`git diff` の後ろ）
    private struct Comparison {
        var revision: [String]
        var base: String?
    }

    /// git の根と、ファイルごとの状態（行の数なし）。git の外なら nil
    static func status(cwd: String) async throws -> (root: String, status: Status)? {
        guard let root = try await root(cwd) else { return nil }
        return (root, parseStatus(try await output(root, ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"], limit: statusLimit)))
    }

    /// git の根と、`scope` のファイルごとの状態と行の数。git の外なら nil。ブランチ全体で比べるブランチが無ければファイルは空
    static func read(cwd: String, scope: ConversationDiffScope = .all) async throws -> (root: String, status: Status)? {
        guard let (root, all) = try await status(cwd: cwd) else { return nil }
        guard let comparison = try await comparison(scope, root: root, status: all) else { return (root, Status(branch: all.branch, initial: all.initial)) }
        var files = try await files(scope, root: root, status: all, comparison: comparison)
        let counts = parseNumstat(try await output(root, ["diff"] + comparison.revision + ["--numstat", "-z", "-M", "--no-ext-diff"], limit: statusLimit))
        var counted = 0
        for index in files.indices {
            if files[index].change == .untracked {
                guard counted < untrackedCountLimit else { continue }
                counted += 1
                files[index].insertions = lineCount(URL(fileURLWithPath: root).appending(path: files[index].path))
                files[index].deletions = files[index].insertions == nil ? nil : 0
            } else if let count = counts[files[index].path] {
                files[index].insertions = count.insertions
                files[index].deletions = count.deletions
            }
        }
        return (root, Status(branch: all.branch, initial: all.initial, files: files, base: comparison.base))
    }

    static func response(_ result: (root: String, status: Status)?, scope: ConversationDiffScope = .all) -> ConversationDiffResponse {
        guard let result else { return ConversationDiffResponse(summary: ConversationDiffSummary(isRepo: false), files: [], scope: scope) }
        return ConversationDiffResponse(summary: summary(result.status), files: result.status.files, scope: scope, base: result.status.base)
    }

    static func summary(_ status: Status) -> ConversationDiffSummary {
        ConversationDiffSummary(
            isRepo: true, branch: status.branch, files: status.files.count, insertions: status.files.reduce(0) { $0 + ($1.insertions ?? 0) },
            deletions: status.files.reduce(0) { $0 + ($1.deletions ?? 0) })
    }

    /// 1 ファイルの unified diff。`path` は `scope` の差分に出た path（rename の元を含む）だけを受ける
    static func file(cwd: String, path: String, scope: ConversationDiffScope = .all) async throws -> ConversationFileDiffResponse {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw Failure(description: "path が git の根の外") }
        guard let (root, status) = try await status(cwd: cwd) else { throw Failure(description: "git の外") }
        guard let comparison = try await comparison(scope, root: root, status: status),
            let entry = try await files(scope, root: root, status: status, comparison: comparison).first(where: { $0.path == path || $0.oldPath == path })
        else { throw Failure(description: "変わったファイルに無い path") }
        let common = ["--no-color", "--no-ext-diff", "--no-textconv"]
        let arguments: [String]
        switch entry.change {
        case .untracked: arguments = ["diff", "--no-index"] + common + ["--", "/dev/null", entry.path]
        case .renamed, .copied: arguments = ["diff"] + comparison.revision + ["-M"] + common + ["--", entry.oldPath ?? entry.path, entry.path]
        default: arguments = ["diff"] + comparison.revision + common + ["--", entry.path]
        }
        let outcome = try await GitCommand.run(root, arguments, limit: fileLimit)
        // diff は差があれば 1 で終わる
        guard outcome.overflowed || outcome.status == 0 || outcome.status == 1 else { throw Failure(description: GitCommand.message(outcome)) }
        var data = outcome.stdout
        if outcome.overflowed || data.count > fileLimit {
            data = data.prefix(fileLimit)
            if let newline = data.lastIndex(of: 0x0A) { data = data[..<data.index(after: newline)] }
        }
        return ConversationFileDiffResponse(path: entry.path, diff: String(decoding: data, as: UTF8.self), truncated: outcome.overflowed)
    }

    // MARK: 比べる相手

    /// ブランチ全体で比べるブランチが無ければ nil
    private static func comparison(_ scope: ConversationDiffScope, root: String, status: Status) async throws -> Comparison? {
        switch scope {
        case .all: return Comparison(revision: [status.initial ? emptyTree : "HEAD"])
        case .unstaged: return Comparison(revision: [])
        case .staged: return Comparison(revision: ["--cached"])
        case .branch:
            guard !status.initial, let base = try await baseBranch(root),
                let fork = try await line(root, ["merge-base", "HEAD", base])
            else { return nil }
            return Comparison(revision: [fork], base: base)
        }
    }

    /// 比べるブランチ：origin の既定のブランチ、無ければ main・master（手元、origin の順）
    private static func baseBranch(_ root: String) async throws -> String? {
        if let head = try await line(root, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) { return head }
        for name in ["main", "master", "origin/main", "origin/master"] {
            if try await line(root, ["rev-parse", "--verify", "--quiet", "\(name)^{commit}"]) != nil { return name }
        }
        return nil
    }

    private static func files(_ scope: ConversationDiffScope, root: String, status: Status, comparison: Comparison) async throws -> [ConversationDiffFile] {
        switch scope {
        case .all:
            return status.files
        case .unstaged:
            return status.files.compactMap { file in
                guard file.change != .untracked, file.change != .unmerged else { return file }
                guard let tree = status.columns[file.path]?.tree, tree != "." else { return nil }
                return ConversationDiffFile(path: file.path, change: tree == "D" ? .deleted : tree == "T" ? .typeChanged : .modified)
            }
        case .staged:
            return status.files.compactMap { file in
                guard file.change != .unmerged else { return file }
                guard let index = status.columns[file.path]?.index, index != "." else { return nil }
                switch index {
                case "A": return ConversationDiffFile(path: file.path, change: .added)
                case "D": return ConversationDiffFile(path: file.path, change: .deleted)
                case "R", "C": return ConversationDiffFile(path: file.path, oldPath: file.oldPath, change: index == "R" ? .renamed : .copied)
                case "T": return ConversationDiffFile(path: file.path, change: .typeChanged)
                default: return ConversationDiffFile(path: file.path, change: .modified)
                }
            }
        case .branch:
            let changed = parseNameStatus(try await output(root, ["diff"] + comparison.revision + ["--name-status", "-z", "-M", "--no-ext-diff"], limit: statusLimit))
            return changed + status.files.filter { $0.change == .untracked }
        }
    }

    // MARK: 読み方

    /// `git status --porcelain=v2 -z --branch` の出力
    static func parseStatus(_ data: Data) -> Status {
        var status = Status()
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = fields.popFirst() {
            if record.hasPrefix("# branch.oid ") {
                status.initial = record.dropFirst("# branch.oid ".count) == "(initial)"
            } else if record.hasPrefix("# branch.head ") {
                let head = String(record.dropFirst("# branch.head ".count))
                status.branch = head == "(detached)" ? nil : head
            } else if record.hasPrefix("1 ") {
                let parts = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard parts.count == 9, let change = change(String(parts[1])) else { continue }
                status.files.append(ConversationDiffFile(path: String(parts[8]), change: change))
                status.columns[String(parts[8])] = columns(parts[1])
            } else if record.hasPrefix("2 ") {
                // 元の path は NUL の後ろの次の欄
                let parts = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let origin = fields.popFirst()
                guard parts.count == 10 else { continue }
                status.files.append(ConversationDiffFile(path: String(parts[9]), oldPath: origin, change: parts[8].hasPrefix("C") ? .copied : .renamed))
                status.columns[String(parts[9])] = columns(parts[1])
            } else if record.hasPrefix("u ") {
                let parts = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count == 11 else { continue }
                status.files.append(ConversationDiffFile(path: String(parts[10]), change: .unmerged))
            } else if record.hasPrefix("? ") {
                status.files.append(ConversationDiffFile(path: String(record.dropFirst(2)), change: .untracked))
            }
        }
        return status
    }

    private static func columns(_ xy: Substring) -> Columns {
        Columns(index: xy.first ?? ".", tree: xy.dropFirst().first ?? ".")
    }

    /// `git diff --name-status -z -M` の出力（rename・copy は元と先の 2 つの欄が続く）
    static func parseNameStatus(_ data: Data) -> [ConversationDiffFile] {
        var files: [ConversationDiffFile] = []
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        while let code = fields.popFirst(), let kind = code.first {
            if kind == "R" || kind == "C" {
                guard let origin = fields.popFirst(), let path = fields.popFirst() else { break }
                files.append(ConversationDiffFile(path: path, oldPath: origin, change: kind == "R" ? .renamed : .copied))
                continue
            }
            guard let path = fields.popFirst(), !path.isEmpty else { break }
            let change: ConversationDiffFile.Change =
                switch kind {
                case "A": .added
                case "D": .deleted
                case "T": .typeChanged
                case "U": .unmerged
                default: .modified
                }
            files.append(ConversationDiffFile(path: path, change: change))
        }
        return files
    }

    /// 1 の行の XY（index と作業フォルダ）。HEAD と作業フォルダの両方に無いもの（足してから消した）は nil
    private static func change(_ xy: String) -> ConversationDiffFile.Change? {
        let x = xy.first ?? "."
        let y = xy.dropFirst().first ?? "."
        if x == "A" { return y == "D" ? nil : .added }
        if x == "D" || y == "D" { return .deleted }
        if x == "T" || y == "T" { return .typeChanged }
        return .modified
    }

    /// `git diff --numstat -z` の出力。バイナリは nil
    static func parseNumstat(_ data: Data) -> [String: (insertions: Int?, deletions: Int?)] {
        var counts: [String: (insertions: Int?, deletions: Int?)] = [:]
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = fields.popFirst() {
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            // rename・copy は path が空で、元と先が続く 2 つの欄
            if path.isEmpty {
                _ = fields.popFirst()
                path = fields.popFirst() ?? ""
            }
            guard !path.isEmpty else { continue }
            counts[path] = (Int(parts[0]), Int(parts[1]))
        }
        return counts
    }

    /// 追跡していないファイルの行の数。1MB を超えるか、NUL を含む（バイナリ）なら nil
    static func lineCount(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileLimit + 1), data.count <= fileLimit, !data.contains(0) else { return nil }
        guard !data.isEmpty else { return 0 }
        return data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } + (data.last == 0x0A ? 0 : 1)
    }

    // MARK: git

    private static func root(_ cwd: String) async throws -> String? {
        let outcome = try await GitCommand.run(cwd, ["rev-parse", "--show-toplevel"], limit: 64 << 10)
        if outcome.timedOut { throw Failure(description: "git が \(timeout) で終わらない") }
        guard outcome.status == 0 else { return nil }
        let root = String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        return root.isEmpty ? nil : root
    }

    /// 1 行の出力。0 以外で終われば nil
    private static func line(_ root: String, _ arguments: [String]) async throws -> String? {
        let outcome = try await GitCommand.run(root, arguments, limit: 64 << 10)
        if outcome.timedOut { throw Failure(description: "git が \(timeout) で終わらない") }
        guard outcome.status == 0 else { return nil }
        let line = String(decoding: outcome.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    private static func output(_ root: String, _ arguments: [String], limit: Int) async throws -> Data {
        let outcome = try await GitCommand.run(root, arguments, limit: limit)
        guard outcome.status == 0, !outcome.timedOut, !outcome.overflowed else { throw Failure(description: GitCommand.message(outcome)) }
        return outcome.stdout
    }
}
