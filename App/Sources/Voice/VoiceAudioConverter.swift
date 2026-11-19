import AVFoundation
import TaskboardKit

/// マイクやファイルの音を、Whisper が読む 16kHz・モノラルの Float に変える。1 つの入力の形式に 1 つ作る（形式が変わったら作り直す）。
/// マイクの tap の thread から呼ばれるので、同じ変換を 2 つの thread から同時に呼ばない
final class VoiceAudioConverter: @unchecked Sendable {
    static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(DictationSignal.sampleRate), channels: 1, interleaved: false)!

    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(from inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            return nil
        }
        converter.downmix = true
        self.inputFormat = inputFormat
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// 音声ファイルの全体を変える（debug の口と、音声ファイルでの評価）
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = VoiceAudioConverter(from: file.processingFormat) else { throw VoiceAudioError.unsupportedFormat }
        var samples: [Float] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            samples += converter.convert(buffer)
        }
        return samples
    }
}

enum VoiceAudioError: Error {
    case unsupportedFormat
}
