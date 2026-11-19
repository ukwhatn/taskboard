import AVFoundation
import Foundation
import OSLog
import Speech
import TaskboardKit

/// 押している間だけ聞く音声入力。端末の中の `DictationTranscriber`（語彙を渡せる）で日本語を文字に起こし、聞いている間は確定した文と途中の文を
/// `update` に、離して確定した文を `finish` に渡す（送信はしない）。日本語のモデルが入っていなければ、押したときに取得を始める。
/// マイクを初めて押したときは許可を求めるだけで聞き始めない（許可のダイアログが出ている間に指が離れ、離した知らせが届かないため）。
/// モデルを取得し終えたときに押したままなら、そのまま聞き始める
@MainActor
@Observable
final class VoiceDictation {
    enum Phase: Equatable {
        case idle
        /// 権限とモデルを確かめ、マイクを開いている
        case preparing
        /// 日本語のモデルを取得している。割合が分からなければ nil
        case downloading(Double?)
        case listening
        /// 離した後、残りの音を文字に起こしている
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// マイクへのアクセスを断られた（入力欄の上に理由と設定を開く操作を出す。閉じるか、次に許可されていれば消す）
    var microphoneDenied = false

    private var held = false
    private var run: DictationRun?

    static let locale = Locale(identifier: "ja-JP")
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "dictation")

    /// 押した。聞いている途中か準備の途中なら何もしない
    func press(vocabulary: [String], update: @escaping (String) -> Void, finish: @escaping (String) -> Void, failed: @escaping (UserFacingError) -> Void) {
        guard phase == .idle else { return }
        held = true
        phase = .preparing
        Task { await begin(vocabulary: vocabulary, update: update, finish: finish, failed: failed) }
    }

    /// 離した。聞いていれば残りを確定して `finish` を呼ぶ。準備の途中なら、準備が済んでも聞き始めない
    func release() {
        held = false
        guard phase == .listening, let run else { return }
        phase = .finishing
        Task {
            await run.finish()
            self.run = nil
            phase = .idle
        }
    }

    /// 画面を離れた。聞いていた分は確定せずに捨てる（入力欄には途中までの文が残る）
    func cancel() {
        held = false
        run?.cancel()
        run = nil
        if phase == .listening || phase == .finishing { phase = .idle }
    }

    private func begin(vocabulary: [String], update: @escaping (String) -> Void, finish: @escaping (String) -> Void, failed: @escaping (UserFacingError) -> Void) async {
        guard await microphoneAllowed() else {
            phase = .idle
            return
        }
        do {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Self.locale) else {
                phase = .idle
                failed(.dictationUnsupported)
                return
            }
            let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
            guard try await installModel(for: transcriber, locale: locale) else {
                phase = .idle
                failed(.dictationModelFailed)
                return
            }
            // モデルの取得を待っている間に離していれば聞き始めない（押し直す）
            guard held else {
                phase = .idle
                return
            }
            let run = try await DictationRun.start(transcriber: transcriber, vocabulary: vocabulary, update: update, finish: finish)
            self.run = run
            phase = .listening
            if !held { release() }
        } catch {
            Self.logger.error("音声入力を始められなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            switch error as? DictationRunError {
            case .noFormat: failed(.dictationUnsupported)
            case .noMicrophone: failed(.dictationNoMicrophone)
            case nil: failed(.dictationFailed)
            }
        }
    }

    /// 許可されていれば true。まだ聞いていなければ求め、許可されても今回は聞き始めない
    private func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            microphoneDenied = false
            return true
        case .denied:
            microphoneDenied = true
            return false
        default:
            microphoneDenied = !(await AVAudioApplication.requestRecordPermission())
            return false
        }
    }

    /// 日本語のモデルを使える状態にする。取得しても入らなかったら false
    private func installModel(for transcriber: DictationTranscriber, locale: Locale) async throws -> Bool {
        try await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return true }
        Self.logger.notice("日本語のモデルを取得する")
        phase = .downloading(nil)
        let progress = Task { [request] in
            while !Task.isCancelled {
                let fraction = request.progress.fractionCompleted
                if case .downloading = phase { phase = .downloading(fraction > 0 ? fraction : nil) }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { progress.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            Self.logger.error("日本語のモデルを取得できなかった: \(String(describing: error), privacy: .public)")
            return false
        }
        let status = await AssetInventory.status(forModules: [transcriber])
        Self.logger.notice("日本語のモデルの取得の後: \(String(describing: status), privacy: .public)")
        return status == .installed
    }
}

/// 1 回の聞き取り。マイクの音を変換して `SpeechAnalyzer` に流し、結果を確定した文と途中の文に分けて控える
@MainActor
private final class DictationRun {
    private let analyzer: SpeechAnalyzer
    private let engine: AVAudioEngine
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, any Error>?
    private var finalized = ""
    private var volatile = ""
    private let finishText: (String) -> Void

    private init(analyzer: SpeechAnalyzer, engine: AVAudioEngine, input: AsyncStream<AnalyzerInput>.Continuation, finish: @escaping (String) -> Void) {
        self.analyzer = analyzer
        self.engine = engine
        self.input = input
        self.finishText = finish
    }

    static func start(
        transcriber: DictationTranscriber, vocabulary: [String], update: @escaping (String) -> Void, finish: @escaping (String) -> Void
    ) async throws -> DictationRun {
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw DictationRunError.noFormat }
        try await analyzer.prepareToAnalyze(in: format)

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let engine = AVAudioEngine()
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw DictationRunError.noMicrophone }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: Self.tap(from: micFormat, to: format, into: continuation))
        let run = DictationRun(analyzer: analyzer, engine: engine, input: continuation, finish: finish)
        run.results = Task { [weak run] in
            for try await result in transcriber.results {
                guard let run else { return }
                run.take(result, update: update)
            }
        }
        do {
            engine.prepare()
            try engine.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            run.cancel()
            throw error
        }
        return run
    }

    private func take(_ result: DictationTranscriber.Result, update: (String) -> Void) {
        let text = String(result.text.characters)
        if result.isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        update(finalized + volatile)
    }

    /// マイクを止め、届いた音を全部確定してから、確定した文（確定しきれなかった途中の文も）を渡す
    func finish() async {
        stopMicrophone()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results?.value
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        finishText(finalized + volatile)
    }

    func cancel() {
        stopMicrophone()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func stopMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input.finish()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// マイクの音を解析の形式に変えて流す。音の thread で呼ばれるので主 actor の外で作る
    private nonisolated static func tap(
        from source: AVAudioFormat, to target: AVAudioFormat, into input: AsyncStream<AnalyzerInput>.Continuation
    ) -> AVAudioNodeTapBlock {
        guard source != target, let converter = AVAudioConverter(from: source, to: target) else {
            return { buffer, _ in input.yield(AnalyzerInput(buffer: buffer)) }
        }
        let ratio = target.sampleRate / source.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }
}

private enum DictationRunError: Error {
    case noFormat, noMicrophone
}

extension UserFacingError {
    static let dictationFailed = UserFacingError("音声入力できませんでした", remedy: String(localized: "時間をおいて、やり直してください"))
    static let dictationUnsupported = UserFacingError(
        "音声入力できませんでした", cause: String(localized: "このデバイスは日本語の音声認識に対応していません"))
    static let dictationNoMicrophone = UserFacingError(
        "音声入力できませんでした", cause: String(localized: "マイクが見つかりません"), remedy: String(localized: "マイクを接続して、やり直してください"))
    static let dictationModelFailed = UserFacingError(
        "音声認識のモデルを取得できませんでした", remedy: String(localized: "ネットワークの接続を確認して、やり直してください"))
}
