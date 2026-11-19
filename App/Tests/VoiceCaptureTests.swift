import AVFoundation
import Foundation
import Testing
@testable import Taskboard

/// マイクの構成の変更（AirPods の接続・入力の切り替え・サンプルレートの変化）で、取り込みを作り直して聞き続けること
@MainActor
@Suite struct VoiceCaptureTests {
    /// 構成の変更を送る相手になり、入力の形式を順に返す偽物のマイク
    final class FakeMicrophone: VoiceMicrophone {
        let configurationSource: AnyObject = NSObject()
        var formats: [AVAudioFormat?]
        var installed: [AVAudioFormat] = []
        var tap: AVAudioNodeTapBlock?
        var running = false
        var preferences: [Bool] = []

        init(formats: [AVAudioFormat?]) {
            self.formats = formats
        }

        func prepareInput(preferBuiltIn: Bool) throws -> AVAudioFormat? {
            preferences.append(preferBuiltIn)
            return formats.isEmpty ? nil : formats.removeFirst()
        }

        func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
            installed.append(format)
            tap = block
        }

        func removeTap() { tap = nil }
        func start() throws { running = true }
        func stop() { running = false }

        /// 今の形式で 0.1 秒分の音を届ける
        func deliver() {
            guard let format = installed.last, let tap else { return }
            let frames = AVAudioFrameCount(format.sampleRate / 10)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.1 * sin(Float(frame) * 0.1) }
            }
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
        }
    }

    private static func format(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    @Test("構成が変わったら tap を付け直し、新しい形式で聞き続ける。前に貯めた音は残る")
    func rebuildsOnConfigurationChange() throws {
        let center = NotificationCenter()
        // 内蔵のマイク（48kHz・2ch）から AirPods（24kHz・1ch）に切り替わる
        let microphone = FakeMicrophone(formats: [Self.format(48_000, 2), Self.format(24_000, 1)])
        let capture = VoiceCapture(microphone: microphone, preferBuiltIn: false, center: center)
        try capture.start()
        microphone.deliver()
        let before = capture.drain().count

        center.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationSource)

        #expect(capture.rebuilds == 1)
        #expect(microphone.installed.map(\.sampleRate) == [48_000, 24_000])
        #expect(microphone.running)
        microphone.deliver()
        let after = capture.stop().count
        // 0.1 秒は 16kHz で 1,600 サンプル。サンプルレートの変換は最初の数十 ms を次の呼び出しまで持つので、1 回目は少し短い
        #expect((1_300...1_600).contains(before))
        #expect((1_500...1_600).contains(after))
        #expect(!microphone.running)
    }

    @Test("切り替えの途中で形式が分からない間は待ち、次の知らせで聞き直す")
    func waitsWhileSwitching() throws {
        let center = NotificationCenter()
        let microphone = FakeMicrophone(formats: [Self.format(48_000, 1), nil, Self.format(16_000, 1)])
        let capture = VoiceCapture(microphone: microphone, preferBuiltIn: true, center: center)
        try capture.start()

        center.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationSource)
        #expect(capture.format == nil)
        #expect(capture.isRunning)
        center.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationSource)

        #expect(capture.rebuilds == 2)
        #expect(capture.format?.sampleRate == 16_000)
        #expect(microphone.preferences == [true, true, true])
        microphone.deliver()
        #expect(capture.drain().count == 1_600)
    }

    @Test("ほかの engine の知らせと、止めた後の知らせでは作り直さない")
    func ignoresOtherNotifications() throws {
        let center = NotificationCenter()
        let microphone = FakeMicrophone(formats: [Self.format(48_000, 1), Self.format(48_000, 1)])
        let capture = VoiceCapture(microphone: microphone, preferBuiltIn: true, center: center)
        try capture.start()
        center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        #expect(capture.rebuilds == 0)
        _ = capture.stop()
        center.post(name: .AVAudioEngineConfigurationChange, object: microphone.configurationSource)
        #expect(capture.rebuilds == 0)
        #expect(microphone.installed.count == 1)
    }

    @Test("マイクの形式が分からなければ聞き始めない")
    func noMicrophone() {
        let capture = VoiceCapture(microphone: FakeMicrophone(formats: [nil]), preferBuiltIn: true, center: NotificationCenter())
        #expect(throws: VoiceCaptureError.self) { try capture.start() }
        #expect(!capture.isRunning)
    }
}
