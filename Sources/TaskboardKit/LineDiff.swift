import Foundation

/// 文書の 2 つの版の、行ごとの差分（unified の形。アプリは ```diff のコードの塊として描く）
public enum LineDiff {
    private enum Line {
        case same(String), removed(String), added(String)
    }

    /// 変わった行の前後 `context` 行を残した hunk の並び。同じなら空
    public static func unified(old: String, new: String, context: Int = 3) -> String {
        let oldLines = lines(old)
        let newLines = lines(new)
        let ops = align(oldLines, newLines)
        let changed = ops.indices.filter { if case .same = ops[$0] { false } else { true } }
        guard let first = changed.first else { return "" }

        // 変わった行から context 行以内に次の変更があれば同じ hunk にする
        var ranges: [ClosedRange<Int>] = []
        var start = max(0, first - context)
        var end = min(ops.count - 1, first + context)
        for index in changed.dropFirst() {
            if index - context <= end + 1 {
                end = min(ops.count - 1, index + context)
            } else {
                ranges.append(start...end)
                start = max(0, index - context)
                end = min(ops.count - 1, index + context)
            }
        }
        ranges.append(start...end)

        // 各 op の手前までに通った旧と新の行の数
        var oldBefore = [Int](repeating: 0, count: ops.count + 1)
        var newBefore = [Int](repeating: 0, count: ops.count + 1)
        for (index, op) in ops.enumerated() {
            let (o, n): (Int, Int) = switch op {
            case .same: (1, 1)
            case .removed: (1, 0)
            case .added: (0, 1)
            }
            oldBefore[index + 1] = oldBefore[index] + o
            newBefore[index + 1] = newBefore[index] + n
        }

        var output: [String] = []
        for range in ranges {
            let oldCount = oldBefore[range.upperBound + 1] - oldBefore[range.lowerBound]
            let newCount = newBefore[range.upperBound + 1] - newBefore[range.lowerBound]
            output.append("@@ -\(position(oldBefore[range.lowerBound], oldCount)) +\(position(newBefore[range.lowerBound], newCount)) @@")
            for op in ops[range] {
                switch op {
                case .same(let text): output.append(" " + text)
                case .removed(let text): output.append("-" + text)
                case .added(let text): output.append("+" + text)
                }
            }
        }
        return output.joined(separator: "\n")
    }

    /// hunk の見出しの「始まりの行,行の数」。行が無ければ始まりは直前の行（unified の決まり）
    private static func position(_ before: Int, _ count: Int) -> String {
        "\(count == 0 ? before : before + 1),\(count)"
    }

    private static func lines(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 標準ライブラリの差分（`difference(from:)`）から、旧の順に消した行・新の順に足した行を並べる
    private static func align(_ old: [String], _ new: [String]) -> [Line] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var ops: [Line] = []
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                ops.append(.removed(old[i]))
                i += 1
            } else if j < new.count, inserted.contains(j) {
                ops.append(.added(new[j]))
                j += 1
            } else {
                ops.append(.same(old[i]))
                i += 1
                j += 1
            }
        }
        return ops
    }
}
