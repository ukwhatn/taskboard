import AVFoundation
import Foundation
import Speech

/// 置き換える前の認識（`DictationTranscriber`、progressiveLongDictation）を、入力欄と同じ手順でファイルに回す。
/// マイクの代わりにファイルの音を 4096 フレームずつ解析の形式に変えて実時間で流し、確定した文と途中の文をつなぐ
enum AppleDictation {
    static func transcribe(_ url: URL, vocabulary: [String]) async throws -> String {
        let locale = Locale(identifier: "ja-JP")
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { throw Failure.unsupported }
        let transcriber = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
        try await AssetInventory.reserve(locale: supported)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure.noFormat }
        try await analyzer.prepareToAnalyze(in: format)
        let file = try AVAudioFile(forReading: url)
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let results = Task {
            var finalized = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatile = ""
                } else {
                    volatile = text
                }
            }
            return finalized + volatile
        }
        try await analyzer.start(inputSequence: stream)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let ratio = format.sampleRate / file.processingFormat.sampleRate
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer)
            let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1)!
            var supplied = false
            var error: NSError?
            _ = converter.convert(to: converted, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            if converted.frameLength > 0 { input.yield(AnalyzerInput(buffer: converted)) }
            // マイクと同じく実時間の速さで流す（速く流すと頭の語が抜けた）
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value
    }

    enum Failure: Error { case unsupported, noFormat }
}
