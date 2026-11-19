import Foundation
import Testing

@testable import TaskboardKit

@Suite("端末のマウスの報告")
struct TerminalMouseTests {
    private let press = "\u{1B}[<0;12;5M"
    private let release = "\u{1B}[<0;12;5m"

    @Test("表示のみの間に取り除くのは SGR のクリックとホイールの報告だけ。打鍵・矢印キー・単独の Esc・日本語は残す")
    func removingReports() {
        func removing(_ text: String) -> String {
            String(decoding: TerminalMouse.removingReports(from: Data(text.utf8)), as: UTF8.self)
        }
        #expect(removing(press + release) == "")
        #expect(removing("\u{1B}[<64;3;10M\u{1B}[<65;3;10M") == "")
        #expect(removing("あ" + press + "ls\r" + release) == "あls\r")
        #expect(removing("\u{1B}[A\u{1B}[B") == "\u{1B}[A\u{1B}[B")
        #expect(removing("\u{1B}") == "\u{1B}")
        #expect(removing("") == "")
        // 形の合わない列（途中で切れた・数が 2 つ・空の数）は報告とみなさない
        #expect(removing("\u{1B}[<0;12") == "\u{1B}[<0;12")
        #expect(removing("\u{1B}[<0;12M") == "\u{1B}[<0;12M")
        #expect(removing("\u{1B}[<;1;1M") == "\u{1B}[<;1;1M")
    }

    @Test("クリックの報告は WebSocket の input でバイト列のまま往復する")
    func reportsPassThroughInput() throws {
        let data = Data((press + release).utf8)
        let encoder = WireJSON.encoder()
        let decoder = WireJSON.decoder()
        let message = TerminalClientMessage.input(data)
        #expect(try decoder.decode(TerminalClientMessage.self, from: try encoder.encode(message)) == message)
    }
}
