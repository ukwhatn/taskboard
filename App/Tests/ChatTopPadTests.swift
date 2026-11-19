import Foundation
import Testing
@testable import Taskboard

/// 短い会話を下に寄せる上の余白（`ChatTopPad`）。中身 427・幅 402 で、余白を書くと一覧の高さが 548 と 600 を行き来した記録の値
@Suite struct ChatTopPadTests {
    @Test("中身が短ければ空いた分を上の余白にし、同じ値なら書かない")
    func padsShortContent() {
        var pad = ChatTopPad()
        #expect(pad.next(free: 245.6, current: 0, contentHeight: 427, width: 402, now: 0) == 245)
        #expect(pad.next(free: 245.2, current: 245, contentHeight: 427, width: 402, now: 0.01) == nil)
        #expect(pad.next(free: -30, current: 245, contentHeight: 900, width: 402, now: 0.02) == 0)
    }

    @Test("2 つの値を行き来し始めたら、大きい方で止め、1 秒たつまでは書かない")
    func stopsOscillation() {
        var pad = ChatTopPad()
        #expect(pad.next(free: 121, current: 245, contentHeight: 427, width: 402, now: 0) == 121)
        #expect(pad.next(free: 173, current: 121, contentHeight: 427, width: 402, now: 0.001) == 173)
        #expect(pad.next(free: 121, current: 173, contentHeight: 427, width: 402, now: 0.002) == nil)
        for step in 0..<100 {
            #expect(pad.next(free: step.isMultiple(of: 2) ? 121 : 173, current: 173, contentHeight: 427, width: 402, now: 0.003 + Double(step) * 0.001) == nil)
        }
        #expect(pad.next(free: 121, current: 173, contentHeight: 427, width: 402, now: 1.01) == 121)
    }

    @Test("止めている間でも、中身の高さか幅が変われば計算し直す（発言が届いた・回転した）")
    func shapeChangeReleasesHold() {
        var pad = ChatTopPad()
        _ = pad.next(free: 121, current: 245, contentHeight: 427, width: 402, now: 0)
        _ = pad.next(free: 173, current: 121, contentHeight: 427, width: 402, now: 0.001)
        _ = pad.next(free: 121, current: 173, contentHeight: 427, width: 402, now: 0.002)
        #expect(pad.next(free: 60, current: 173, contentHeight: 540, width: 402, now: 0.003) == 60)
        #expect(pad.next(free: 300, current: 60, contentHeight: 540, width: 874, now: 0.004) == 300)
    }
}
