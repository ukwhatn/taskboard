import AVFoundation
import OSLog
import TaskboardKit

/// マイク（本番は `AVAudioEngine` の入力）。テストは構成の変更を送る偽物に替える
@MainActor
protocol VoiceMicrophone: AnyObject {
    /// 構成の変更（`AVAudioEngineConfigurationChange`）を送ってくる相手
    var configurationSource: AnyObject { get }
    /// 入力の機器を選び直し、今の入力の形式を返す。機器が切り替わる途中で形式が分からなければ nil
    func prepareInput(preferBuiltIn: Bool) throws -> AVAudioFormat?
    func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func start() throws
    func stop()
}

/// 聞いている間のマイクの音を 16kHz・モノラルで貯める。AirPods の接続・入力の切り替え・サンプルレートの変化で構成が変わったら、
/// tap を外して形式を読み直し、変換を作り直して聞き続ける（貯めた音は捨てない）。形式が分からない間は次の知らせを待つ
@MainActor
final class VoiceCapture {
    private let microphone: any VoiceMicrophone
    private let preferBuiltIn: Bool
    private let center: NotificationCenter
    private let samples = VoiceSampleBuffer()
    private var observer: (any NSObjectProtocol)?
    private(set) var isRunning = false
    /// 構成の変更で作り直した回数
    private(set) var rebuilds = 0
    private(set) var format: AVAudioFormat?
    private static let logger = Logger(subsystem: "uk.whatn.taskboard", category: "dictation")

    init(microphone: any VoiceMicrophone, preferBuiltIn: Bool, center: NotificationCenter = .default) {
        self.microphone = microphone
        self.preferBuiltIn = preferBuiltIn
        self.center = center
    }

    /// 聞き始める。マイクが無ければ `VoiceCaptureError.noMicrophone`
    func start() throws {
        guard !isRunning else { return }
        guard try attach() else { throw VoiceCaptureError.noMicrophone }
        isRunning = true
        observer = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: microphone.configurationSource, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// 前に取り出してから届いた音
    func drain() -> [Float] { samples.drain() }

    /// 止めて、まだ取り出していない音を返す
    func stop() -> [Float] {
        if let observer { center.removeObserver(observer) }
        observer = nil
        if isRunning {
            microphone.removeTap()
            microphone.stop()
        }
        isRunning = false
        return samples.drain()
    }

    private func rebuild() {
        guard isRunning else { return }
        rebuilds += 1
        microphone.removeTap()
        microphone.stop()
        do {
            let attached = try attach()
            Self.logger.notice("マイクの構成が変わった。取り込みを作り直した: \(attached, privacy: .public) \(self.format?.description ?? "-", privacy: .public)")
        } catch {
            Self.logger.error("マイクの構成が変わった後に聞き直せなかった: \(String(describing: error), privacy: .public)")
        }
    }

    /// 形式を読んで tap を付けて動かす。形式が分からなければ false
    private func attach() throws -> Bool {
        guard let format = try microphone.prepareInput(preferBuiltIn: preferBuiltIn), let converter = VoiceAudioConverter(from: format) else {
            format = nil
            return false
        }
        self.format = format
        let samples = samples
        microphone.installTap(format: format) { buffer, _ in samples.append(converter.convert(buffer)) }
        try microphone.start()
        return true
    }
}

enum VoiceCaptureError: Error {
    case noMicrophone
}

/// tap の thread が足し、主 actor が取り出す
final class VoiceSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock { stored += samples }
    }

    func drain() -> [Float] {
        lock.withLock {
            defer { stored = [] }
            return stored
        }
    }
}

/// 本物のマイク。内蔵のマイクを優先するときは、Mac は入力の機器を内蔵のマイクに固定し（AirPods を通話用の形式に切り替えさせない）、
/// iPhone・iPad は入力の候補から内蔵のマイクを選ぶ
@MainActor
final class EngineMicrophone: VoiceMicrophone {
    private let engine = AVAudioEngine()
    var configurationSource: AnyObject { engine }

    func prepareInput(preferBuiltIn: Bool) throws -> AVAudioFormat? {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: preferBuiltIn ? [.duckOthers] : [.duckOthers, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        if preferBuiltIn, let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtIn)
        } else if !preferBuiltIn {
            try session.setPreferredInput(nil)
        }
        #else
        if preferBuiltIn, let device = BuiltInMicrophone.deviceID(), let unit = engine.inputNode.audioUnit {
            var device = device
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        #endif
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func installTap(format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format, block: block)
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

#if os(macOS)
import CoreAudio

/// Mac の内蔵のマイク（接続の種類が内蔵で、入力の stream を持つ機器）
enum BuiltInMicrophone {
    static func deviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
#endif
