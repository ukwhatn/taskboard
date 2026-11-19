import Testing
@testable import Taskboard

@Suite struct SidebarOrderTests {
    @Test("保存した順に並べ、順に無いものは元の順のまま末尾に足す")
    func savedOrderFirst() {
        #expect(SidebarOrder.arrange(["a", "b", "c", "d"], by: ["c", "a"]) == ["c", "a", "b", "d"])
    }

    @Test("保存した順にあって今は無いもの（消したボード・外した接続先）は飛ばす")
    func skipsMissing() {
        #expect(SidebarOrder.arrange(["a", "b"], by: ["x", "b", "y"]) == ["b", "a"])
    }

    @Test("保存が空なら元の順")
    func emptyOrder() {
        #expect(SidebarOrder.arrange(["b", "a"], by: []) == ["b", "a"])
        #expect(SidebarOrder.arrange([], by: ["a"]) == [])
    }

    @Test("ドラッグで動かした結果を、今の並びのまま保存できる形にする")
    func move() {
        // 「c」を先頭へ（List の onMove は移す前の添字と、移す先の添字を渡す）
        #expect(SidebarOrder.move(["a", "b", "c"], from: [2], to: 0) == ["c", "a", "b"])
        #expect(SidebarOrder.move(["a", "b", "c"], from: [0], to: 3) == ["b", "c", "a"])
    }

    @Test("日本語の名前でも id で並べる")
    func cjk() {
        #expect(SidebarOrder.arrange(["認証", "決済", "taskboard"], by: ["taskboard", "決済"]) == ["taskboard", "決済", "認証"])
    }
}
