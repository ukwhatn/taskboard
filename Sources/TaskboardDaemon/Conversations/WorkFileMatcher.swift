import Foundation
import TaskboardKit

/// `@` の候補のあいまい一致。打った文字が、パスの中に順に（間をあけて）出てくるものを選び、区切り・頭文字・続けて合うものを重く数える。
/// 大文字と小文字は区別しない（ASCII のみ）。長さはバイト列で数え、非 ASCII の字は 1 字ぶんをひとまとまりで探す
struct WorkFileMatcher {
    /// 一覧の 1 件。小文字にしたバイト列は一覧を作るときに 1 度だけ作る（打鍵のたびに全件を作り直さない）
    struct Entry: Sendable {
        var file: WorkFile
        var bytes: [UInt8]
        var lower: [UInt8]
        var basenameStart: Int

        init(_ file: WorkFile) {
            self.file = file
            bytes = Array(file.path.utf8)
            lower = bytes.map(Self.lowercase)
            let body = file.isDirectory ? bytes.dropLast() : bytes[...]
            basenameStart = body.lastIndex(of: 0x2F).map { $0 + 1 } ?? 0
        }

        static func lowercase(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte }
    }

    private let units: [[UInt8]]

    init(query: String) {
        var units: [[UInt8]] = []
        for scalar in query.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            units.append(String(scalar).utf8.map(Entry.lowercase))
        }
        self.units = units
    }

    /// 合うものを点の高い順に `limit` 件まで。点が同じなら浅い・短いものを先に。打った文字が空なら浅いものから
    static func rank(_ query: String, in entries: [Entry], limit: Int) -> [WorkFile] {
        let matcher = WorkFileMatcher(query: query)
        if matcher.units.isEmpty {
            return entries.sorted { a, b in
                let depths = (a.bytes.count(where: { $0 == 0x2F }), b.bytes.count(where: { $0 == 0x2F }))
                return depths.0 != depths.1 ? depths.0 < depths.1 : a.file.path < b.file.path
            }.prefix(limit).map(\.file)
        }
        var scored: [(entry: Entry, score: Int)] = []
        for entry in entries {
            if let score = matcher.score(entry) { scored.append((entry, score)) }
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.bytes.count != b.entry.bytes.count { return a.entry.bytes.count < b.entry.bytes.count }
            return a.entry.file.path < b.entry.file.path
        }.prefix(limit).map(\.entry.file)
    }

    /// パスの全体で合わせた点と、ファイル名の中だけで合わせた点の高い方。合わなければ nil
    /// （全体で最初に合う所は、フォルダ名の中の字を拾いがちで、ファイル名に合う並びを逃す）
    func score(_ entry: Entry) -> Int? {
        let whole = score(entry, from: 0)
        guard entry.basenameStart > 0, let name = score(entry, from: entry.basenameStart) else { return whole }
        return max(whole ?? name, name)
    }

    /// `from` 以降で順に探して合う範囲を見つけ、終わりから縮めて一番詰まった範囲にしてから点を付ける
    private func score(_ entry: Entry, from: Int) -> Int? {
        guard let end = forwardEnd(entry.lower, from: from), let positions = tightestPositions(entry.lower, end: end, from: from) else { return nil }
        var total = 0
        var chain = false
        var previousEnd = -2
        for (position, count) in positions {
            total += 16
            let before: UInt8? = position > 0 ? entry.bytes[position - 1] : nil
            if let before {
                if before == 0x2F { total += 14 } else if Self.isSeparator(before) { total += 8 } else if Self.isLower(before) && Self.isUpper(entry.bytes[position]) { total += 8 }
            } else {
                total += 14
            }
            if position == previousEnd + 1 {
                total += chain ? 14 : 12
                chain = true
            } else {
                if previousEnd >= 0 { total -= min(position - previousEnd - 1, 6) }
                chain = false
            }
            previousEnd = position + count - 1
        }
        if let first = positions.first?.0, first >= entry.basenameStart { total += 30 }
        if let first = positions.first?.0, first == entry.basenameStart { total += 10 }
        // 名前の語の終わり（拡張子の手前か末尾）まで合っていれば、名前そのものを打っている
        if let last = positions.last, previousEnd + 1 >= entry.bytes.count || [0x2E, 0x2F].contains(entry.bytes[last.0 + last.1]) { total += 12 }
        return total
    }

    /// 打った文字を頭から順に探して、最後の 1 字が合った位置
    private func forwardEnd(_ path: [UInt8], from start: Int) -> Int? {
        var from = start
        var last = 0
        for unit in units {
            guard let position = find(unit, in: path, from: from, backward: false) else { return nil }
            last = position + unit.count - 1
            from = last + 1
        }
        return last
    }

    /// `end` から後ろへ探して、1 字ごとの先頭の位置とバイト数（前から順）。範囲が一番詰まる
    private func tightestPositions(_ path: [UInt8], end: Int, from lowest: Int) -> [(Int, Int)]? {
        var positions: [(Int, Int)] = []
        var limit = end
        for unit in units.reversed() {
            guard let position = find(unit, in: path, from: limit, backward: true), position >= lowest else { return nil }
            positions.append((position, unit.count))
            limit = position - 1
        }
        return positions.reversed()
    }

    /// 1 字ぶんのバイト列を `from` 以降（backward なら `from` 以前で終わるもの）で探した先頭の位置
    private func find(_ unit: [UInt8], in path: [UInt8], from: Int, backward: Bool) -> Int? {
        let count = unit.count
        if backward {
            var start = from - count + 1
            while start >= 0 {
                if matches(unit, in: path, at: start) { return start }
                start -= 1
            }
        } else {
            var start = from
            while start + count <= path.count {
                if matches(unit, in: path, at: start) { return start }
                start += 1
            }
        }
        return nil
    }

    private func matches(_ unit: [UInt8], in path: [UInt8], at start: Int) -> Bool {
        for index in unit.indices where path[start + index] != unit[index] { return false }
        return true
    }

    private static func isSeparator(_ byte: UInt8) -> Bool { byte == 0x2D || byte == 0x5F || byte == 0x2E || byte == 0x20 }
    private static func isLower(_ byte: UInt8) -> Bool { byte >= 0x61 && byte <= 0x7A }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 0x41 && byte <= 0x5A }
}
