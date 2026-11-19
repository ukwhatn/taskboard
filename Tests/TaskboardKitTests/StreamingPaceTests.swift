import Testing
@testable import TaskboardKit

@Suite struct StreamingPaceTests {
    /// `shown` から 1 歩進めたときに見せる文
    private func reveal(_ text: String, from shown: String = "") -> String {
        let step = StreamingPace.next(text, shown: shown.utf8.count)
        return String(decoding: text.utf8.prefix(step.shown), as: UTF8.self)
    }

    private func repeated(_ character: Character, _ count: Int) -> String { String(repeating: character, count: count) }

    @Test("見せていない分を約 0.55 秒で出し切る間隔にし、25〜150 ms に収める。25 ms でも追いつかない量なら 1 歩を広げる")
    func interval() {
        let few = StreamingPace.next(repeated("あ", 22), shown: 0)
        #expect(few.wait == 0.15)
        #expect(few.shown == 22 * 3)
        // 100 字なら 0.55 × 22 ÷ 100 = 0.121 秒で 22 字
        let hundred = StreamingPace.next(repeated("あ", 100), shown: 0)
        #expect(abs(hundred.wait - 0.121) < 0.0001)
        #expect(hundred.shown == 22 * 3)
        // 1,000 字なら 25 ms に収まり、1,000 × 0.025 ÷ 0.55 = 45.5 → 46 字
        let many = StreamingPace.next(repeated("あ", 1000), shown: 0)
        #expect(many.wait == 0.025)
        #expect(many.shown == 46 * 3)
    }

    @Test("全部見せたら、そのまま 150 ms 待つ")
    func caughtUp() {
        #expect(StreamingPace.next("届いた文", shown: "届いた文".utf8.count) == StreamingPace.Step(shown: "届いた文".utf8.count, wait: 0.15))
        #expect(StreamingPace.next("", shown: 0) == StreamingPace.Step(shown: 0, wait: 0.15))
    }

    @Test("日本語はどの字の間でも切り、英数字の単語は途中で切らない（先の切れ目へ延ばすか、届いた文の終わりが単語の途中なら前の切れ目へ戻す）")
    func words() {
        #expect(reveal(repeated("い", 30)) == repeated("い", 22))
        #expect(reveal("abcdefghij klmnopqrstuvwxyz rest") == "abcdefghij klmnopqrstuvwxyz")
        #expect(reveal("short words then Supercalifrag") == "short words then ")
        #expect(reveal("進捗は 3 件の PR を確認した。", from: "進捗は") == "進捗は 3 件の PR を確認した。")
        // 切れ目が無ければ進めない
        #expect(reveal("Supercalifragilisticexpialidocious") == "")
    }

    @Test("閉じていない太字・行内のコード・リンクは記号の手前までにし、同じ行で閉じていれば閉じた後まで延ばす")
    func openMarkers() {
        #expect(reveal("前の文 **太字の途中で届いた分の文が続いています") == "前の文 ")
        #expect(reveal("ab **太字の中の文がここまでずっと長く続いて**、その後ろの文。まだ続く") == "ab **太字の中の文がここまでずっと長く続いて**")
        #expect(reveal("見て `swift build --target TaskboardKit の") == "見て ")
        #expect(reveal("[リンクの文の題](https://example.com/do") == "")
        #expect(reveal("[リンクの文の題](https://example.com/docs) の続きの文です") == "[リンクの文の題](https://example.com/docs)")
        #expect(reveal("前の文の続き ~~消した文がまだ続いている途中") == "前の文の続き ")
        // 行内のコードの中の ** は数えない
        #expect(reveal("`a ** b` と書くと掛け算の意味になります。続きの文") == "`a ** b` と書くと掛け算の意味になり")
        // 角括弧だけ（リンクにならない）は待たない
        #expect(reveal("配列 [1, 2] を並べ替えた結果を出します。続き") == "配列 [1, 2] を並べ替えた結果を出しま")
    }

    @Test("閉じない記号のある行が終わっていれば、その行の終わりまで見せる")
    func lineEnded() {
        #expect(reveal("**開いたままの太字の行の文がここまでずっと続く\n次の行") == "**開いたままの太字の行の文がここまでずっと続く")
    }

    @Test("届いた文の終わりの * ・ ` は、次の字が届くまで記号か分からないので手前で止める")
    func trailingMarker() {
        #expect(reveal("文の終わりに記号*") == "文の終わりに記号")
        #expect(reveal("文の終わりに記号`") == "文の終わりに記号")
        #expect(reveal("文の終わりに記号**太字") == "文の終わりに記号")
    }
}
