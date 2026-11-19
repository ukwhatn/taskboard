import SwiftUI

/// 入力欄の［音声入力］。押したときと離したときを `VoiceDictation` に渡す（1 回押すとハンズフリーで聞き、押し続けると離すまで聞く）。
/// 聞いている間は塗りのマイクにして、不透明度だけをゆっくり動かす（視差効果を減らす設定では動かさない）。
/// VoiceOver は押すたびに聞き始めと終わりを切り替える
struct ComposerVoiceButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: VoiceDictation.Phase
    /// 校正を待っている（押せば次の音声入力を始められる）
    let polishing: Bool
    let press: () -> Void
    let release: () -> Void
    @State private var pressing = false
    @State private var dim = false

    var body: some View {
        let listening = phase == .listening
        Image(systemName: listening ? "mic.fill" : "mic")
            .font(.title3)
            .foregroundStyle(listening ? Color.accentColor : ChatPalette.secondaryText)
            .opacity(listening && dim ? 0.45 : busy ? 0.5 : 1)
            .animation(listening && !reduceMotion ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil, value: dim)
            .hitTarget()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressing else { return }
                        pressing = true
                        press()
                    }
                    .onEnded { _ in
                        pressing = false
                        release()
                    }
            )
            .onChange(of: listening, initial: true) { _, now in dim = now }
            .accessibilityElement()
            .accessibilityLabel("音声入力")
            .accessibilityValue(listening ? Text("聞き取り中") : polishing ? Text("校正中") : Text(verbatim: ""))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                // 押してすぐ離したのと同じ（止まっていればハンズフリーで聞き始め、聞いていれば終える）
                press()
                release()
            }
            #if os(macOS)
            .help("話した内容を入力します。もう一度押すか話し終えると止まり、押し続けると離したときに止まります（⌥Space）")
            #endif
    }

    /// 準備・取得・読み込み・文字にしている間は押しても始まらないので薄くする。校正を待つ間も薄くする（押せば次の音声入力を始める）
    private var busy: Bool {
        switch phase {
        case .idle: polishing
        case .listening: false
        case .preparing, .downloading, .loading, .transcribing: true
        }
    }
}

#if os(macOS)
import AppKit

/// 入力欄にいる間の ⌥Space の押し下げと離し（短く押すとハンズフリーの開始と終了、押し続けると離すまで聞く）。押し続けている間の繰り返しは捨てる（入力欄に空白を入れない）
@MainActor
final class VoiceKeyMonitor {
    var isActive = false {
        didSet { if !isActive, holding { end() } }
    }
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    private var token: Any?
    private var holding = false

    private static let space: UInt16 = 49

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.keyCode == Self.space else { return event }
            switch event.type {
            case .keyDown:
                guard self.isActive, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option else { return event }
                if !event.isARepeat, !self.holding {
                    self.holding = true
                    self.onPress()
                }
                return nil
            case .keyUp:
                // ⌥ を先に離しても、Space を離したときに終える
                guard self.holding else { return event }
                self.end()
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        if holding { end() }
    }

    private func end() {
        holding = false
        onRelease()
    }
}
#endif
