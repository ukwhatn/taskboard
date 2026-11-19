import Foundation
import Testing
@testable import Taskboard

/// 押した値を先に出し、daemon の値が届くか失敗するまで持つ部品（docs/ui-system.md「設定」）
@Suite struct PendingValueTests {
    @Test("押す前は daemon の値、押したら押した値。daemon の値が届いたら daemon の値に戻る")
    func sendThenSettle() {
        var pending = PendingValue<Int>()
        #expect(pending.shown(10) == 10)
        pending.send(30)
        #expect(pending.shown(10) == 30)
        pending.settle()
        #expect(pending.shown(30) == 30)
        #expect(pending.shown(10) == 10)
    }

    @Test("失敗したら daemon の値に戻す")
    func failureRestores() {
        var pending = PendingValue<Bool>()
        pending.send(true)
        pending.failed(true)
        #expect(pending.shown(false) == false)
    }

    @Test("続けて押し直していたら、前に押した値の失敗では戻さない")
    func laterPressSurvivesEarlierFailure() {
        var pending = PendingValue<Int>()
        pending.send(30)
        pending.send(60)
        pending.failed(30)
        #expect(pending.shown(10) == 60)
        pending.failed(60)
        #expect(pending.shown(10) == 10)
    }
}
