import Foundation

/// 音声入力の音（16kHz・モノラルの Float）の扱い
public enum DictationSignal {
    public static let sampleRate = 16_000
    /// 大きさを測る 1 区切り（20 ms）
    static let frameLength = 320

    /// 話している区切りの大きさを `targetLevel` にそろえる。話している区切りの大きさは、区切りの RMS の 90 パーセンタイルで測る
    /// （無音の区切りを数に入れない）。上げるのは `maxGain` 倍まで（雑音だけを持ち上げない）で、頭打ちの手前（ピーク 0.98）で止める
    public static func normalized(_ samples: [Float], targetLevel: Float = 0.1, maxGain: Float = 30) -> [Float] {
        guard let peak = samples.lazy.map(abs).max(), peak > 0 else { return samples }
        let levels = stride(from: 0, to: samples.count, by: frameLength).map { start in
            rms(samples[start..<min(start + frameLength, samples.count)])
        }.sorted()
        let level = levels[min(levels.count - 1, levels.count * 9 / 10)]
        guard level > 0 else { return samples }
        let gain = min(targetLevel / level, maxGain, 0.98 / peak)
        guard abs(gain - 1) > 0.01 else { return samples }
        return samples.map { $0 * gain }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func decibels(_ level: Float) -> Float { 20 * log10(max(level, 1e-5)) }
}

/// 聞いている音から、話し始めと、話し終えた後の無音を見分ける（ハンズフリーで聞くのを終える合図）。
/// 雑音の大きさ（直近 5 秒の区切りの dB の最小。0 の音の区切りは数えない）より `margin` dB 大きい区切りが 100 ms 続いたら話したとみなす。
/// 話した後に `silence` 秒、話している区切りが無ければ終わり。話す前の無音は数えない（押してすぐ黙っても切らない）
public struct DictationEndpoint: Sendable {
    public let silence: Double
    public let margin: Float
    public private(set) var heardSpeech = false
    public private(set) var ended = false

    private var pending: [Float] = []
    /// 直近の区切りの dB（雑音の大きさを測る窓）
    private var recent: [Float] = []
    private var run = 0
    private var quietFrames = 0
    /// 雑音の大きさを測る窓（5 秒）。話し続けても語の間の区切りが窓に残り、雑音が大きくなったら 5 秒で追いつく
    private static let window = 250
    /// これより小さい区切りは 0 の音（マイクの立ち上がり・機器の切り替え）で、雑音の大きさに数えない
    private static let digitalSilence: Float = -90
    /// 話したとみなす続きの区切りの数（100 ms）
    private static let speechRun = 5

    public init(silence: Double = 2.0, margin: Float = 10) {
        self.silence = silence
        self.margin = margin
    }

    /// 届いた音を足し、話し終えた後の無音が `silence` 秒に達したら true
    @discardableResult
    public mutating func feed(_ samples: [Float]) -> Bool {
        pending += samples
        let length = DictationSignal.frameLength
        var used = 0
        while pending.count - used >= length {
            take(DictationSignal.decibels(DictationSignal.rms(pending[used..<used + length])))
            used += length
        }
        pending.removeFirst(used)
        return ended
    }

    private mutating func take(_ level: Float) {
        if level > Self.digitalSilence {
            recent.append(level)
            if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
        }
        let speaking = recent.min().map { level > $0 + margin } ?? false
        if speaking {
            run += 1
            if run >= Self.speechRun { heardSpeech = true }
            quietFrames = 0
        } else {
            run = 0
            if heardSpeech { quietFrames += 1 }
        }
        let silentSeconds = Double(quietFrames * DictationSignal.frameLength) / Double(DictationSignal.sampleRate)
        if heardSpeech, silentSeconds >= silence { ended = true }
    }
}
