import Testing
@testable import Taskboard

/// snapshot の比べ方で、AppKit の入力欄が 1 pt 高く配置された形だけを参照と同じとみなす判定
struct FieldGrowthTests {
    /// 幅 1 px・行ごとに違う色の画像（倍率 2。1 pt = 2 行）。下がった所より下は、違ってよい帯（32 行）より長くとる
    private func bitmap(_ rows: [UInt8]) -> SnapshotBitmap {
        SnapshotBitmap(width: 1, height: rows.count, bytes: rows.flatMap { [$0, $0, $0, 255] })
    }

    private let reference: [UInt8] = Array(0..<200)

    /// 参照の `at` 行目から下を 2 行下げ、空いた 2 行に `filler` を入れ、`band` の行を描き替えた画像
    private func grown(at row: Int, band: Range<Int>, filler: UInt8 = 250) -> [UInt8] {
        var rows = Array(reference[..<row]) + [filler, filler] + Array(reference[row..<(reference.count - 2)])
        for y in band { rows[y] = 250 }
        return rows
    }

    @Test("入力欄の行から下がそっくり 1 pt 下がり、欄の字の帯だけが違う画像は同じとみなす")
    func grownField() {
        #expect(FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(grown(at: 100, band: 90..<100))))
    }

    @Test("下がった所より下で 1 行でも中身が違えば同じとみなさない")
    func changedBelow() {
        var rows = grown(at: 100, band: 90..<100)
        rows[150] = 255
        #expect(!FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(rows)))
    }

    @Test("下がり方が 1 pt でなければ同じとみなさない")
    func otherShift() {
        let rows = Array(reference[..<100]) + [250, 250, 250, 250] + Array(reference[100..<196])
        #expect(!FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(rows)))
    }

    @Test("違う行が入力欄 1 つの高さ（16 pt）を超えて続けば同じとみなさない")
    func wideBand() {
        #expect(!FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(grown(at: 100, band: 60..<100))))
    }

    @Test("違う行が 2 つの帯に分かれていれば同じとみなさない")
    func twoBands() {
        var rows = grown(at: 100, band: 90..<94)
        rows[50] = 250
        #expect(!FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(rows)))
    }

    @Test("大きさの違う画像は同じとみなさない")
    func size() {
        #expect(!FieldGrowth.explains(reference: bitmap(reference), actual: bitmap(Array(reference.dropLast()))))
    }
}
