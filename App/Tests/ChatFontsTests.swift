import Testing
@testable import Taskboard

/// チャットの文字の段（Claude Desktop の Code の画面の compact の値）
@Suite struct ChatFontsTests {
    @Test("14pt の本文は行 20、コードは 12pt で行 17、行どうしは 10、発言の切れ目は 15")
    func claudeDesktopValues() {
        let fonts = ChatFonts(size: 14)
        #expect(fonts.line == 20)
        #expect(fonts.codeLine == 17)
        #expect(fonts.itemGap == 10)
        #expect(fonts.turnGap == 15)
    }

    @Test("⌘+ で大きくしても行の高さは同じ比で伸びる")
    func scalesWithSize() {
        let fonts = ChatFonts(size: 16)
        #expect(fonts.line == 23)
        #expect(fonts.codeLine == 20)
    }
}
