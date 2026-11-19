import Testing
@testable import Taskboard

/// 入力欄の部品と Binding のどちらが文を持つかの判定
struct MultilineFieldSyncTests {
    /// `#expect` の中で mutating の関数を呼べないので、参照の箱に入れる
    private final class Sync {
        private var sync = MultilineFieldSync<String>()
        func receive(_ text: String) -> Bool { sync.receive(text) }
        func wrote(_ text: String) { sync.wrote(text) }
    }

    @Test("最初に届いた文は入れ、同じ文がもう一度届いても入れない")
    func first() {
        let sync = Sync()
        #expect(sync.receive("下書き"))
        #expect(!sync.receive("下書き"))
    }

    @Test("部品が書いた文が届いても入れない")
    func echo() {
        let sync = Sync()
        _ = sync.receive("")
        sync.wrote("a")
        #expect(!sync.receive("a"))
    }

    @Test("Binding が書いた文を 1 打鍵ずつ遅れて運んでも、遅れた文を入れない")
    func lagging() {
        let sync = Sync()
        _ = sync.receive("")
        sync.wrote("a")
        #expect(!sync.receive(""))
        sync.wrote("ab")
        #expect(!sync.receive("a"))
        sync.wrote("abc")
        #expect(!sync.receive("ab"))
        #expect(!sync.receive("abc"))
    }

    @Test("書いた文が戻ってこない Binding（.constant）は、前と同じ文を運ぶだけなので入れない")
    func constant() {
        let sync = Sync()
        #expect(sync.receive("abcdef"))
        for text in ["abcXdef", "abcXYdef"] {
            sync.wrote(text)
            #expect(!sync.receive("abcdef"))
        }
    }

    @Test("外で文が変わったら入れる（送ったあとに空にする・別の書きかけに替える）")
    func external() {
        let sync = Sync()
        _ = sync.receive("")
        sync.wrote("送る文")
        #expect(!sync.receive("送る文"))
        #expect(sync.receive(""))
        sync.wrote("x")
        #expect(sync.receive("別の書きかけ"))
    }

    @Test("書いた数が上限を超えても、新しく書いた方の文は入れない")
    func manyWrites() {
        let sync = Sync()
        _ = sync.receive("")
        let texts = (1...100).map { String(repeating: "あ", count: $0) }
        texts.forEach { sync.wrote($0) }
        #expect(!sync.receive(texts[90]))
        #expect(!sync.receive(texts[99]))
    }
}
