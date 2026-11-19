import Foundation

/// 作業ディレクトリの欄の補完（`GET /v1/workdirs/complete?prefix=`）。入力の最後の `/` までを親、その後ろを名前の頭として、
/// 親の中のディレクトリを返す。返す形は入力に揃える（`~/` で打てば `~/` のまま）。末尾に `/` を付けないのは、
/// 選んだ値をそのまま作業ディレクトリにでき、ブックマーク・最近使ったものと同じ書き方になるため
enum WorkdirCompleter {
    static let limit = 20

    static func complete(_ typed: String, home: String, fileManager: FileManager = .default) -> [String] {
        guard typed.hasPrefix("/") || typed.hasPrefix("~/"), let slash = typed.lastIndex(of: "/") else { return [] }
        let parent = String(typed[...slash])
        let partial = String(typed[typed.index(after: slash)...])
        let directory = parent.hasPrefix("~/") ? home + "/" + parent.dropFirst(2) : parent
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { name in
                // 空の文字の range(of:) は nil を返すので、空のときは比べない
                guard name != partial, partial.isEmpty || name.range(of: partial, options: [.caseInsensitive, .anchored]) != nil else { return false }
                guard partial.hasPrefix(".") || !name.hasPrefix(".") else { return false }
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: directory + name, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            // 端末の言語で順が変わらないよう、locale を使わずに比べる
            .sorted { $0.compare($1, options: [.caseInsensitive, .numeric]) == .orderedAscending }
            .prefix(limit)
            .map { parent + $0 }
    }
}
