import AVFoundation
import Foundation
import OSLog
import TaskboardKit

/// 会話の入力欄の音声入力。1 回押すと聞き始め、もう一度押すか、話し終えて無音が `silence` 秒続いたら終える（ハンズフリー）。
/// 押し続けてから離したら、離したときに終える。終えたら端末の中の Whisper で文字にして `Handlers.transcribed` に渡し（送信はしない）、
/// 続けて会話の文脈を付けて校正し、校正できたら `Handlers.polished` に渡す。校正に失敗したら何も渡さない（校正の前の文が残る）。
/// マイクを初めて押したときは許可を求めるだけで聞き始めない（許可のダイアログが出ている間に指が離れ、離した知らせが届かないため）
@MainActor
@Observable
final class VoiceDictation {
    enum Phase: Equatable {
        case idle
        /// 権限とモデルを確かめ、マイクを開いている
        case preparing
        /// 音声認識のモデルを取得している。割合が分からなければ nil
        case downloading(Double?)
        /// 音声認識のモデルを読み込んでいる
        case loading
        case listening
        /// 聞き終えた音を文字にしている
        case transcribing
    }

    struct Handlers {
        /// 校正の前の文
        var transcribed: (String) -> Void
        /// 校正の前の文と、校正した文
        var polished: (_ original: String, _ polished: String) -> Void
        var failed: (UserFacingError) -> Void
        /// 校正を頼む口。nil なら校正しない（fixtures など）
        var polish: (@Sendable (String) async throws -> String)?
    }

    /// 1 回の音声入力にかかった時間（離してから、校正の前の文と校正した文が入るまで）
    struct Timing: Equatable {
        var transcribed: Double
        var polished: Double?
    }

    private(set) var phase: Phase = .idle
    /// 校正を待っている（入力欄には校正の前の文が入っている）
    private(set) var polishing = false
    private(set) var lastTiming: Timing?
    /// マイクへのアクセスを断られた（入力欄の上に理由と設定を開く操作を出す。閉じるか、次に許可されていれば消す）
    var microphoneDenied = false

    /// これより長く押してから離したら、離したときに終える
    static let holdThreshold: Duration = .milliseconds(350)
    /// ハンズフリーで、話し終えた後にこの秒数の無音が続いたら終える
    static let silence = 2.0
    /// ハンズフリーで、話さないままこの秒数が過ぎたら終える
    static let silentStartLimit = 10.0

    private let recognizer: WhisperRecognizer
    private let makeMicrophone: @MainActor () -> any VoiceMicrophone
    private let clock = ContinuousClock()
    private var held = false
    private var listeningSince: ContinuousClock.Instant?
    /// ハンズフリーで聞いている途中に押した（その押しで終えたので、続く離しは何もしない）
    private var ignoreRelease = false
    private var capture: VoiceCapture?
    private var endpoint = DictationEndpoint(silence: VoiceDictation.silence)
    private var heard: [Float] = []
    private var watcher: Task<Void, Never>?
    private var vocabulary: [String] = []
    private var handlers: Handlers?

    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "dictation")

    init(recognizer: WhisperRecognizer = .shared, makeMicrophone: @escaping @MainActor () -> any VoiceMicrophone = { EngineMicrophone() }) {
        self.recognizer = recognizer
        self.makeMicrophone = makeMicrophone
    }

    /// 押した。止まっていれば聞き始め、ハンズフリーで聞いていれば終える
    func press(vocabulary: [String], handlers: Handlers) {
        switch phase {
        case .idle:
            held = true
            ignoreRelease = false
            self.vocabulary = vocabulary
            self.handlers = handlers
            phase = .preparing
            Task { await begin() }
        case .listening:
            ignoreRelease = true
            finish()
        default:
            break
        }
    }

    /// 離した。聞き始めてから `holdThreshold` より長く押していれば終える。短ければハンズフリーで聞き続ける
    func release() {
        held = false
        if ignoreRelease {
            ignoreRelease = false
            return
        }
        guard phase == .listening, let listeningSince, clock.now - listeningSince >= Self.holdThreshold else { return }
        finish()
    }

    /// 画面を離れた。準備の途中なら聞き始めず、聞いていた分は文字にせずに捨てる。校正を待っている文は、届いても入れない（モデルの取得は続ける）
    func cancel() {
        held = false
        watcher?.cancel()
        watcher = nil
        _ = capture?.stop()
        capture = nil
        handlers = nil
        polishing = false
        phase = .idle
    }

    /// モデルを取得し終えていれば、読み込んでおく（初めて押したときに待たせない）
    func prewarm() {
        Task { [recognizer] in
            guard await recognizer.isDownloaded else { return }
            try? await recognizer.prepare { _ in }
        }
    }

    /// 音声ファイルを、マイクの代わりに同じ手順（文字にして校正）に通す（debug の口）
    func transcribeFile(_ url: URL, vocabulary: [String], handlers: Handlers) {
        guard phase == .idle else { return }
        self.vocabulary = vocabulary
        self.handlers = handlers
        phase = .preparing
        Task {
            do {
                try await prepareModel()
                let samples = try VoiceAudioConverter.read(url)
                await transcribe(samples)
            } catch {
                Self.logger.error("音声ファイルを文字にできなかった: \(String(describing: error), privacy: .public)")
                phase = .idle
                handlers.failed(.dictationFailed)
            }
        }
    }

    private func begin() async {
        guard await microphoneAllowed() else {
            phase = .idle
            return
        }
        do {
            try await prepareModel()
        } catch {
            Self.logger.error("音声認識のモデルを用意できなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            handlers?.failed(.dictationModelFailed)
            return
        }
        guard phase != .idle else { return }
        let capture = VoiceCapture(
            microphone: makeMicrophone(), preferBuiltIn: AppDefaults.store.object(forKey: AppPreferences.preferBuiltInMicrophoneKey) as? Bool ?? true)
        do {
            try capture.start()
        } catch {
            Self.logger.error("マイクを開けなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            handlers?.failed(.dictationNoMicrophone)
            return
        }
        self.capture = capture
        endpoint = DictationEndpoint(silence: Self.silence)
        heard = []
        phase = .listening
        listeningSince = clock.now
        // 準備の間に長く押して離していても、聞き始めた後は 1 回押したのと同じに扱う（ハンズフリー）
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.watch()
            }
        }
    }

    /// 聞いている間、届いた音を貯めて、ハンズフリーなら話し終えたかを見る
    private func watch() {
        guard phase == .listening, let capture else { return }
        let samples = capture.drain()
        heard += samples
        endpoint.feed(samples)
        guard !held else { return }
        let elapsed = Double(heard.count) / Double(DictationSignal.sampleRate)
        if endpoint.ended || (!endpoint.heardSpeech && elapsed >= Self.silentStartLimit) { finish() }
    }

    private func finish() {
        guard phase == .listening, let capture else { return }
        watcher?.cancel()
        watcher = nil
        let rest = capture.stop()
        self.capture = nil
        heard += rest
        endpoint.feed(rest)
        let samples = heard
        heard = []
        guard endpoint.heardSpeech else {
            phase = .idle
            return
        }
        Task { await transcribe(samples) }
    }

    private func transcribe(_ samples: [Float]) async {
        phase = .transcribing
        let started = clock.now
        let text: String
        do {
            text = try await recognizer.transcribe(DictationSignal.normalized(samples), vocabulary: vocabulary)
        } catch {
            Self.logger.error("音声を文字にできなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            handlers?.failed(.dictationFailed)
            return
        }
        phase = .idle
        guard let handlers, !text.isEmpty else { return }
        let transcribed = Self.seconds(clock.now - started)
        handlers.transcribed(text)
        lastTiming = Timing(transcribed: transcribed, polished: nil)
        Self.logger.notice("音声を文字にした: \(transcribed, format: .fixed(precision: 2), privacy: .public) 秒")
        guard let polish = handlers.polish else { return }
        polishing = true
        defer { polishing = false }
        do {
            let polished = try await polish(text)
            guard self.handlers != nil else { return }
            let seconds = Self.seconds(clock.now - started)
            lastTiming = Timing(transcribed: transcribed, polished: seconds)
            Self.logger.notice("文を校正した: \(seconds, format: .fixed(precision: 2), privacy: .public) 秒")
            if polished != text { handlers.polished(text, polished) }
        } catch {
            Self.logger.notice("文を校正できなかった。校正の前の文を残す: \(String(describing: error), privacy: .public)")
        }
    }

    private func prepareModel() async throws {
        try await recognizer.prepare { stage in
            Task { @MainActor [weak self] in
                guard let self, self.phase != .idle, self.phase != .listening, self.phase != .transcribing else { return }
                switch stage {
                case .downloading(let fraction): self.phase = .downloading(fraction)
                case .loading: self.phase = .loading
                }
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

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

extension UserFacingError {
    static let dictationFailed = UserFacingError("音声入力できませんでした", remedy: String(localized: "時間をおいて、やり直してください"))
    static let dictationNoMicrophone = UserFacingError(
        "音声入力できませんでした", cause: String(localized: "マイクが見つかりません"), remedy: String(localized: "マイクを接続して、やり直してください"))
    static let dictationModelFailed = UserFacingError(
        "音声認識のモデルを取得できませんでした", remedy: String(localized: "ネットワークの接続を確認して、やり直してください"))
}
