import AVFoundation
import Foundation
import OSLog
import TaskboardKit

#if os(iOS)
import UIKit
#endif

/// 会話の入力欄の音声入力。アプリに 1 つだけ持ち、1 回押すと、もう一度押すまで聞き続ける（会話を切り替えても止めない）。
/// 押し続けてから離したら、離したときに終える。話している間は区切りの音を `partialInterval` ごとに文字にして確定前の文（`tentative`）に出し、
/// 無音が `silence` 秒続いたら区切りを確定して、そのとき開いている会話の入力欄（`Target`）に入れ、会話の文脈を付けて校正した文に置き換える。
/// 区切りの最後が合図の言葉（`DictationCue`）なら、合図を除いた文を入れ、校正を待ってから（`polishLimit` 秒まで）入力欄の送信と同じ経路で送る。
/// 会話が問いの回答を待っていれば、送る代わりに回答にする（`DictationAnswer`）。
/// 入れる先が無い間に確定した文は溜め、入れる先ができたら入れる（溜めた文の合図では送らない）。
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
        /// 聞き終えた後、最後の区切りを文字にしている
        case transcribing
    }

    /// 音声入力の文を入れる先（会話の入力欄）。入力欄が出ている間だけ登録する
    struct Target {
        let key: ConversationKey
        var vocabulary: @MainActor () -> [String]
        /// 校正を頼む口。nil なら校正しない（fixtures など）
        var polish: (@Sendable (String) async throws -> String)?
        /// 今のカーソルの位置（範囲を選んでいればその範囲）に文を入れ、入れた区切りを返す
        var insert: @MainActor (String) -> DictationSpan?
        /// 入れた区切りを置き換える。打ち直していて見つからなければ nil
        var replace: @MainActor (DictationSpan, String) -> DictationSpan?
        /// 入力欄の送信と同じ経路で送る。会話が問いの回答を待っていれば、入力欄の文を回答にする
        var submit: @MainActor () async -> Void
    }

    /// 入力欄の上に 1 行で出す、音声入力が送った・答えた・溜めていた文を入れた知らせ
    enum Notice: Equatable {
        case answered(option: String?)
        case delivered(count: Int)
    }

    /// 1 回の区切りにかかった時間（秒）。`firstText` は話し始めてから確定前の文が出るまで、`committed` は話し終えてから確定した文が入るまで
    /// （無音を待つ `silence` 秒を含む）、`polished` と `sent` は話し終えてから校正した文が入るまでと送るまで
    struct Timing: Equatable {
        var firstText: Double?
        var committed: Double?
        var polished: Double?
        var sent: Double?
    }

    private(set) var phase: Phase = .idle
    /// 話している区切りの確定前の文と、それを出す入力欄
    private(set) var tentative: (key: ConversationKey, text: String)?
    /// 校正を待っている区切りの数
    private(set) var polishing = 0
    /// 入れる先が無い間に確定した文
    private(set) var held: [String] = []
    private(set) var lastTiming: Timing?
    /// 入力欄の上の失敗の帯に出す（入力欄が受け取って消す）
    var failure: UserFacingError?
    /// 会話ごとの最後の知らせ（閉じるか、次の区切りを入れたら消す）
    var notices: [ConversationKey: Notice] = [:]
    /// マイクへのアクセスを断られた（入力欄の上に理由と設定を開く操作を出す。閉じるか、次に許可されていれば消す）
    var microphoneDenied = false

    /// これより長く押してから離したら、離したときに終える
    static let holdThreshold: Duration = .milliseconds(350)
    /// 話し終えた後にこの秒数の無音が続いたら、区切りを確定する
    static let silence = 2.0
    /// 話している間、確定前の文を作り直す間隔（秒）
    static let partialInterval = 1.0
    /// 話す前の音は、区切りの頭としてこの秒数だけ残す
    static let preroll = 1.0
    /// 合図で送るときに校正を待つ上限（秒）。過ぎたら校正の前の文を送る
    static let polishLimit = 20.0

    private let recognizer: WhisperRecognizer
    private let makeMicrophone: @MainActor () -> any VoiceMicrophone
    private let drafts: ChatDraftTexts?
    private let clock = ContinuousClock()
    private var listeningSince: ContinuousClock.Instant?
    /// 聞いている途中に押した（その押しで終えたので、続く離しは何もしない）
    private var ignoreRelease = false
    private var source: (any VoiceSampleSource)?
    private var endpoint = DictationEndpoint(silence: VoiceDictation.silence)
    /// 今の区切りの音
    private var segment: [Float] = []
    private var segmentID = 0
    private var segmentTimes: (spoke: ContinuousClock.Instant?, firstText: Double?) = (nil, nil)
    private var partialRunning = false
    private var partialAt = 0
    /// 確定した区切りを順に文字にして入れる（前の区切りが入るまで次を入れない）
    private var commits: Task<Void, Never>?
    /// 校正を待っている区切り（合図で送るときに待つ）
    private var polishTasks: [Int: Task<Void, Never>] = [:]
    private var commitCount = 0
    private var watcher: Task<Void, Never>?
    private var targets: [(id: UUID, target: Target)] = []
    #if os(macOS)
    private let keys = VoiceKeyMonitor()
    #endif
    #if os(iOS)
    private var background: (any NSObjectProtocol)?
    #endif

    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "dictation")

    init(
        recognizer: WhisperRecognizer = .shared, drafts: ChatDraftTexts? = nil,
        makeMicrophone: @escaping @MainActor () -> any VoiceMicrophone = { EngineMicrophone() }
    ) {
        self.recognizer = recognizer
        self.drafts = drafts
        self.makeMicrophone = makeMicrophone
    }

    // MARK: 入れる先

    /// 入力欄が出た・中身が変わった。同じ `id` なら差し替える。前にいなければ入れる先にし、溜めていた文を入れる
    func register(_ id: UUID, _ target: Target) {
        if let index = targets.firstIndex(where: { $0.id == id }) {
            targets[index].target = target
        } else {
            targets.append((id, target))
            deliverHeld()
        }
        #if os(macOS)
        startKeys()
        #endif
    }

    /// 入力欄にフォーカスが来た。並べて 2 つ出ているときは、最後にフォーカスした方に入れる
    func focus(_ id: UUID) {
        guard let index = targets.firstIndex(where: { $0.id == id }), index != targets.count - 1 else { return }
        targets.append(targets.remove(at: index))
    }

    /// 入力欄が消えた。聞くのは止めない
    func unregister(_ id: UUID) {
        targets.removeAll { $0.id == id }
    }

    /// 今の入れる先か
    func isTarget(_ id: UUID) -> Bool { targets.last?.id == id }

    private var target: Target? { targets.last?.target }

    private func target(for key: ConversationKey) -> Target? { targets.last { $0.target.key == key }?.target }

    // MARK: 操作

    /// 押した。止まっていれば聞き始め、聞いていれば終える
    func press() {
        switch phase {
        case .idle:
            ignoreRelease = false
            phase = .preparing
            Task { await begin(source: nil) }
        case .listening:
            ignoreRelease = true
            stop()
        default:
            break
        }
    }

    /// 離した。聞き始めてから `holdThreshold` より長く押していれば終える。短ければ聞き続ける
    func release() {
        if ignoreRelease {
            ignoreRelease = false
            return
        }
        guard phase == .listening, let listeningSince, clock.now - listeningSince >= Self.holdThreshold else { return }
        stop()
    }

    /// 聞くのを終える。話している途中の区切りは文字にして入れる
    func stop() {
        guard phase == .listening else { return }
        watcher?.cancel()
        watcher = nil
        let rest = source?.stop() ?? []
        source = nil
        #if os(iOS)
        if let background { NotificationCenter.default.removeObserver(background) }
        background = nil
        #endif
        take(rest)
        if endpoint.heardSpeech { closeSegment() } else { tentative = nil }
        phase = .transcribing
        let pending = commits
        Task {
            await pending?.value
            if phase == .transcribing { phase = .idle }
        }
    }

    /// 音声入力のボタンを隠した。聞いていれば捨てずに終える
    func disable() {
        if phase == .listening { stop() }
    }

    /// モデルを取得し終えていれば、読み込んでおく（初めて押したときに待たせない）
    func prewarm() {
        Task { [recognizer] in
            guard await recognizer.isDownloaded else { return }
            try? await recognizer.prepare { _ in }
        }
    }

    /// 音声ファイルを、マイクの代わりに同じ手順（区切り・確定前の文・合図・校正）へ実時間で流す（debug の口）。止まっていればファイルで聞き始め、
    /// ファイルで聞いていれば続けて流す。流し終えた後は無音を流し続ける（止めるのは `press` か `stop`）
    func feedFile(_ url: URL) {
        do {
            let samples = try VoiceAudioConverter.read(url)
            if let file = source as? FileSampleSource {
                file.append(samples)
            } else if phase == .idle {
                phase = .preparing
                Task { await begin(source: FileSampleSource(samples)) }
            }
        } catch {
            Self.logger.error("音声ファイルを読めなかった: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: 聞く

    private func begin(source file: FileSampleSource?) async {
        if file == nil {
            guard await microphoneAllowed() else {
                phase = .idle
                return
            }
        }
        do {
            try await prepareModel()
        } catch {
            Self.logger.error("音声認識のモデルを用意できなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            failed(.dictationModelFailed)
            return
        }
        guard phase != .idle else { return }
        let source: any VoiceSampleSource =
            file ?? VoiceCapture(microphone: makeMicrophone(), preferBuiltIn: AppDefaults.store.object(forKey: AppPreferences.preferBuiltInMicrophoneKey) as? Bool ?? true)
        do {
            try source.start()
        } catch {
            Self.logger.error("マイクを開けなかった: \(String(describing: error), privacy: .public)")
            phase = .idle
            failed(.dictationNoMicrophone)
            return
        }
        self.source = source
        endpoint = DictationEndpoint(silence: Self.silence)
        resetSegment()
        phase = .listening
        listeningSince = clock.now
        #if os(iOS)
        // 裏に回るとマイクは止まるので、そこで区切りを確定して終える
        background = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        #endif
        // 準備の間に長く押して離していても、聞き始めた後は 1 回押したのと同じに扱う
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                self.watch()
            }
        }
    }

    /// 届いた音を区切りに貯め、話している間は確定前の文を作り直し、話し終えたら区切りを確定する
    private func watch() {
        guard phase == .listening, let source else { return }
        take(source.drain())
        if endpoint.ended {
            closeSegment()
        } else if endpoint.heardSpeech, !partialRunning, segment.count - partialAt >= Int(Self.partialInterval * Double(DictationSignal.sampleRate)) {
            transcribePartial()
        }
    }

    private func take(_ samples: [Float]) {
        let spoke = endpoint.heardSpeech
        segment += samples
        endpoint.feed(samples)
        if !endpoint.heardSpeech {
            let keep = Int(Self.preroll * Double(DictationSignal.sampleRate)) + samples.count
            if segment.count > keep { segment.removeFirst(segment.count - keep) }
        } else if !spoke {
            segmentTimes.spoke = clock.now
        }
    }

    private func resetSegment() {
        segment = []
        segmentID += 1
        segmentTimes = (nil, nil)
        partialAt = 0
    }

    private func transcribePartial() {
        partialRunning = true
        partialAt = segment.count
        let id = segmentID, samples = segment, key = target?.key, vocabulary = target?.vocabulary() ?? []
        Task {
            defer { partialRunning = false }
            guard let text = try? await recognizer.transcribe(DictationSignal.normalized(samples), vocabulary: vocabulary), id == segmentID, phase == .listening else { return }
            guard let key, !text.isEmpty else { return }
            tentative = (key, text)
            if segmentTimes.firstText == nil, let spoke = segmentTimes.spoke {
                // 話したとみなすのは声が 300 ms 続いてからなので、その分を足す
                segmentTimes.firstText = Self.seconds(clock.now - spoke) + 0.3
            }
        }
    }

    /// 今の区切りを確定し、前の区切りが入り終えてから文字にして入れる
    private func closeSegment() {
        let samples = segment, firstText = segmentTimes.firstText
        let ended = clock.now - (endpoint.ended ? Duration.seconds(Self.silence) : .zero)
        let vocabulary = target?.vocabulary() ?? []
        resetSegment()
        endpoint.nextSegment()
        let previous = commits
        commits = Task {
            await previous?.value
            await commit(samples, vocabulary: vocabulary, ended: ended, firstText: firstText)
        }
    }

    private func commit(_ samples: [Float], vocabulary: [String], ended: ContinuousClock.Instant, firstText: Double?) async {
        let text: String
        do {
            text = try await recognizer.transcribe(DictationSignal.normalized(samples), vocabulary: vocabulary)
        } catch {
            Self.logger.error("音声を文字にできなかった: \(String(describing: error), privacy: .public)")
            tentative = nil
            failed(.dictationFailed)
            return
        }
        tentative = nil
        guard !text.isEmpty else { return }
        commitCount += 1
        let number = commitCount
        lastTiming = Timing(firstText: firstText, committed: Self.seconds(clock.now - ended))
        let cue = DictationCue.split(text)
        Self.logger.notice("区切りを確定した: \(self.lastTiming?.committed ?? 0, format: .fixed(precision: 2), privacy: .public) 秒 合図 \(cue.send, privacy: .public)")
        guard let target else {
            if !cue.body.isEmpty { held.append(cue.body) }
            return
        }
        notices[target.key] = nil
        if !cue.body.isEmpty, let span = target.insert(cue.body), let polish = target.polish {
            polishing += 1
            let key = target.key
            polishTasks[number] = Task {
                defer {
                    polishing -= 1
                    polishTasks[number] = nil
                }
                guard let result = try? await Self.withLimit(Self.polishLimit, { try await polish(cue.body) }), result != cue.body else { return }
                replace(span, with: result, for: key)
                record(number) { $0.polished = Self.seconds(clock.now - ended) }
            }
        }
        guard cue.send else { return }
        // 前の区切りの校正も待ってから送る（どれも `polishLimit` 秒で打ち切る）
        for task in polishTasks.values { await task.value }
        guard let current = self.target(for: target.key) else { return }
        await current.submit()
        record(number) { $0.sent = Self.seconds(clock.now - ended) }
    }

    /// 最後の区切りの時間だけを書き足す（後の区切りが確定していれば書かない）
    private func record(_ number: Int, _ change: (inout Timing) -> Void) {
        guard number == commitCount, var timing = lastTiming else { return }
        change(&timing)
        lastTiming = timing
    }

    /// 入力欄が出ていればそこで、出ていなければ書きかけの控え（`ChatDraftTexts`）で置き換える
    private func replace(_ span: DictationSpan, with text: String, for key: ConversationKey) {
        if let target = target(for: key) {
            _ = target.replace(span, text)
        } else if let drafts, let result = span.replacing(with: text, in: drafts.text(for: key)) {
            drafts.set(result.text, selection: nil, for: key)
        }
    }

    private func deliverHeld() {
        guard !held.isEmpty, let target else { return }
        let count = held.count
        _ = target.insert(held.joined())
        held = []
        notices[target.key] = .delivered(count: count)
    }

    private func failed(_ error: UserFacingError) {
        failure = error
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

    #if os(macOS)
    /// ⌥Space はアプリのどの画面でも効く（音声入力のボタンを隠していれば効かない）
    private func startKeys() {
        keys.onPress = { [weak self] in self?.press() }
        keys.onRelease = { [weak self] in self?.release() }
        keys.isEnabled = { AppDefaults.store.object(forKey: AppPreferences.voiceInputKey) as? Bool ?? true }
        keys.start()
    }
    #endif

    private static func withLimit<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

/// 音声入力の音の出どころ（マイクの `VoiceCapture` と、確認用の `FileSampleSource`）。16kHz・モノラルの Float を返す
@MainActor
protocol VoiceSampleSource: AnyObject {
    func start() throws
    /// 前に取り出してから届いた音
    func drain() -> [Float]
    /// 止めて、まだ取り出していない音を返す
    func stop() -> [Float]
}

extension VoiceCapture: VoiceSampleSource {}

/// 音声ファイルの音を、取り出すたびに経った時間の分だけ返す（マイクと同じ速さで流す）。流し終えたら無音を返す
@MainActor
final class FileSampleSource: VoiceSampleSource {
    private var samples: [Float]
    private var position = 0
    private var startedAt: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(_ samples: [Float]) { self.samples = samples }

    /// 流し終えた後に足したら、今の位置から流す（読み位置は無音を返した分だけ末尾を越えている）
    func append(_ more: [Float]) {
        if position > samples.count { samples += [Float](repeating: 0, count: position - samples.count) }
        samples += more
    }

    func start() throws { startedAt = clock.now }

    func drain() -> [Float] {
        guard let startedAt else { return [] }
        let elapsed = clock.now - startedAt
        let due = Int((Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) * Double(DictationSignal.sampleRate))
        guard due > position else { return [] }
        let end = min(due, samples.count)
        let chunk = position < end ? Array(samples[position..<end]) : []
        let silence = [Float](repeating: 0, count: due - max(position, end))
        position = due
        return chunk + silence
    }

    func stop() -> [Float] {
        let rest = drain()
        startedAt = nil
        return rest
    }
}

extension UserFacingError {
    static let dictationFailed = UserFacingError("音声入力できませんでした", remedy: String(localized: "時間をおいて、やり直してください"))
    static let dictationNoMicrophone = UserFacingError(
        "音声入力できませんでした", cause: String(localized: "マイクが見つかりません"), remedy: String(localized: "マイクを接続して、やり直してください"))
    static let dictationModelFailed = UserFacingError(
        "音声認識のモデルを取得できませんでした", remedy: String(localized: "ネットワークの接続を確認して、やり直してください"))
}
