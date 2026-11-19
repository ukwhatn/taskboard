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
/// 20 ms の区切りの大きさを 100 ms で均し、雑音の大きさ（均した大きさの直近 10 秒の 10 パーセンタイル）より `margin` dB 大きい間を話しているとみなす。
/// 300 ms 続いたら話した、とする。話した後に `silence` 秒、200 ms 以上続けて話している間が無ければ終わり（一瞬の物音では数えを戻さない）。
/// 聞き始めの 200 ms（マイクの立ち上がりの小さい区切り）と 0 の音（-90 dB 未満。立ち上がりと機器の切り替え）は雑音の大きさに数えない。話す前の無音は数えない（押してすぐ黙っても切らない）
public struct DictationEndpoint: Sendable {
    public let silence: Double
    public let margin: Float
    public private(set) var heardSpeech = false
    public private(set) var ended = false

    private var pending: [Float] = []
    private var frames = 0
    /// 均すための直近の区切りの力（振幅の 2 乗の平均）
    private var powers: [Float] = []
    /// 雑音の大きさを測る、均した大きさ（dB）の直近の並び
    private var smoothed: [Float] = []
    private var run = 0
    private var quietFrames = 0

    private static let skipFrames = 10
    private static let smoothFrames = 5
    private static let window = 500
    private static let speechRun = 15
    /// 無音の数えを戻すのに要る、続けて話している区切りの数（200 ms。均す 100 ms で一瞬の物音も 100 ms ほど大きく見えるため）
    private static let resetRun = 10
    private static let digitalSilence: Float = 1e-9

    public init(silence: Double = 2.0, margin: Float = 10) {
        self.silence = silence
        self.margin = margin
    }

    /// 区切りを終えて次の区切りを聞く。雑音の大きさの並びは残す（聞き続けている間は、区切りごとに測り直さない）
    public mutating func nextSegment() {
        heardSpeech = false
        ended = false
        run = 0
        quietFrames = 0
    }

    /// 届いた音を足し、話し終えた後の無音が `silence` 秒に達したら true
    @discardableResult
    public mutating func feed(_ samples: [Float]) -> Bool {
        pending += samples
        let length = DictationSignal.frameLength
        var used = 0
        while pending.count - used >= length {
            let level = DictationSignal.rms(pending[used..<used + length])
            take(level * level)
            used += length
        }
        pending.removeFirst(used)
        return ended
    }

    private mutating func take(_ power: Float) {
        frames += 1
        guard frames > Self.skipFrames else { return }
        guard power >= Self.digitalSilence else {
            // 0 の音は雑音の大きさに数えず、話した後なら無音に数える（雑音を 0 に切るマイクがある）
            run = 0
            countQuiet()
            return
        }
        powers.append(power)
        if powers.count > Self.smoothFrames { powers.removeFirst() }
        let level = 10 * log10(max(powers.reduce(0, +) / Float(powers.count), 1e-10))
        smoothed.append(level)
        if smoothed.count > Self.window { smoothed.removeFirst() }
        let sorted = smoothed.sorted()
        let floor = sorted[sorted.count / 10]
        if level > floor + margin {
            run += 1
            if run >= Self.speechRun { heardSpeech = true }
            if run >= Self.resetRun { quietFrames = 0 }
        } else {
            run = 0
        }
        if run < Self.resetRun { countQuiet() }
    }

    private mutating func countQuiet() {
        guard heardSpeech else { return }
        quietFrames += 1
        if Double(quietFrames * DictationSignal.frameLength) / Double(DictationSignal.sampleRate) >= silence { ended = true }
    }
}
