import Foundation
import Testing

@testable import TaskboardKit

@Suite("音声入力の差し込み")
struct DictationDraftTests {
    @Test("カーソルの位置に聞き取った文を差し込み、カーソルを文の後ろに置く")
    func insertsAtCursor() {
        let draft = "前の文。後ろの文"
        let cursor = draft.index(draft.startIndex, offsetBy: 4)
        let insertion = DictationDraft(draft: draft, selection: cursor..<cursor)
        let result = insertion.inserting("真ん中")
        #expect(result.text == "前の文。真ん中後ろの文")
        #expect(result.text[result.cursor...] == "後ろの文")
    }

    @Test("範囲を選んでいれば、選んだ文を聞き取った文に置き換える")
    func replacesSelection() {
        let draft = "abc DEF ghi"
        let lower = draft.index(draft.startIndex, offsetBy: 4), upper = draft.index(lower, offsetBy: 3)
        let result = DictationDraft(draft: draft, selection: lower..<upper).inserting("デフ")
        #expect(result.text == "abc デフ ghi")
        #expect(result.text[result.cursor...] == " ghi")
    }

    @Test("カーソルが分からなければ末尾に足す")
    func appendsWithoutCursor() {
        let result = DictationDraft(draft: "書きかけ", selection: nil).inserting("の続き")
        #expect(result.text == "書きかけの続き")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test("何も聞き取れなければ、聞き始める前の文とカーソルに戻る")
    func emptyRestores() {
        let draft = "そのまま"
        let cursor = draft.index(after: draft.startIndex)
        let result = DictationDraft(draft: draft, selection: cursor..<cursor).inserting("")
        #expect(result.text == "そのまま")
        #expect(result.text[result.cursor...] == "のまま")
    }

    @Test("空の欄に入れる")
    func emptyDraft() {
        let result = DictationDraft(draft: "", selection: nil).inserting("こんにちは")
        #expect(result.text == "こんにちは")
        #expect(result.cursor == result.text.endIndex)
    }

    @Test("途中の文を何度入れ替えても、聞き始める前の文の前後は変わらない")
    func volatileReplacements() {
        let insertion = DictationDraft(draft: "A|B", selection: nil)
        _ = insertion.inserting("途中")
        #expect(insertion.inserting("確定した文").text == "A|B確定した文")
    }
}

@Suite("音声入力の語彙")
struct DictationVocabularyTests {
    private func message(_ text: String, role: ChatMessage.Role = .assistant, kind: ChatMessage.Kind = .text) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: role, kind: kind, text: text)
    }

    @Test("タスクの題と番号を先に、発言に出た番号のような語を新しい発言から並べる")
    func collects() {
        let messages = [
            message("PROJ-12 と #40 を見ました"),
            message("r#3 と #41 を直します", role: .user),
        ]
        let phrases = DictationVocabulary.phrases(taskTitle: "音声入力の追加", taskNumber: 172, messages: messages)
        #expect(phrases == ["音声入力の追加", "#172", "r#3", "#41", "PROJ-12", "#40"])
    }

    @Test("同じ語は 1 回だけにする")
    func deduplicates() {
        let phrases = DictationVocabulary.phrases(taskTitle: nil, taskNumber: 5, messages: [message("#5 と #5、#6"), message("#6")])
        #expect(phrases == ["#5", "#6"])
    }

    @Test("ツールの入出力と思考は読まない")
    func skipsToolsAndThinking() {
        let messages = [
            message("#900", kind: .toolResult),
            message("#901", kind: .toolUse),
            ChatMessage(id: "t", role: .assistant, kind: .text, text: "#902", thinking: true),
        ]
        #expect(DictationVocabulary.phrases(taskTitle: nil, taskNumber: nil, messages: messages).isEmpty)
    }

    @Test("語は上限の数までにする")
    func capsAtLimit() {
        let text = (1...300).map { "#\($0)" }.joined(separator: " ")
        let phrases = DictationVocabulary.phrases(taskTitle: "題", taskNumber: nil, messages: [message(text)])
        #expect(phrases.count == DictationVocabulary.limit)
        #expect(phrases.first == "題")
    }

    @Test("題が空白だけなら入れない。番号の無い発言からは何も取らない")
    func emptyInputs() {
        #expect(DictationVocabulary.phrases(taskTitle: "  ", taskNumber: nil, messages: [message("番号はありません")]).isEmpty)
    }
}

@Suite("音声入力の語彙の英数字の語")
struct DictationVocabularyWordTests {
    private func message(_ text: String) -> ChatMessage {
        ChatMessage(id: UUID().uuidString, role: .assistant, kind: .text, text: text)
    }

    @Test("識別子・ファイル名・ブランチ名を 1 語で取り、1 字の語は取らない")
    func collectsWords() {
        let phrases = DictationVocabulary.phrases(
            taskTitle: nil, taskNumber: nil, messages: [message("ConversationService.swift の Stop hook を feature/9y-voice で直す。a と b")])
        #expect(phrases == ["ConversationService.swift", "Stop", "hook", "feature/9y-voice"])
    }

    @Test("1 つの発言の中では番号のような語を英数字の語より先に置き、同じ語は 1 回だけにする")
    func numbersFirst() {
        let phrases = DictationVocabulary.phrases(taskTitle: nil, taskNumber: nil, messages: [message("PR の PROJ-12 と r#3")])
        #expect(phrases == ["PROJ-12", "r#3", "PR"])
    }
}

@Suite("音声入力の音の大きさ")
struct DictationSignalTests {
    /// 440Hz の正弦波を 1 秒
    private func tone(amplitude: Float) -> [Float] {
        (0..<16_000).map { amplitude * sin(Float($0) * 2 * .pi * 440 / 16_000) }
    }

    @Test("小さい声を、話している区切りの RMS が 0.1 になるまで上げる")
    func raisesQuietSpeech() throws {
        let quiet = tone(amplitude: 0.01)
        let normalized = DictationSignal.normalized(quiet)
        // 振幅 0.01 の正弦波の RMS は 0.00707。0.1 にするには 14.1 倍
        let peak = try #require(normalized.map(abs).max())
        #expect(abs(peak - 0.141) < 0.005)
    }

    @Test("上げるのは 30 倍まで")
    func capsGain() throws {
        let normalized = DictationSignal.normalized(tone(amplitude: 0.001))
        let peak = try #require(normalized.map(abs).max())
        #expect(abs(peak - 0.03) < 0.001)
    }

    @Test("ピークが 0.98 を超えない")
    func avoidsClipping() throws {
        // 短い大きな音と長い小さな音（90 パーセンタイルは小さな音）
        var samples = tone(amplitude: 0.005)
        samples[100] = 0.5
        let normalized = DictationSignal.normalized(samples)
        let peak = try #require(normalized.map(abs).max())
        #expect(peak <= 0.98 + 1e-6)
    }

    @Test("無音と空は変えない")
    func silence() {
        #expect(DictationSignal.normalized([]) == [])
        #expect(DictationSignal.normalized([Float](repeating: 0, count: 800)) == [Float](repeating: 0, count: 800))
    }
}

@Suite("ハンズフリーの終わりの判定")
struct DictationEndpointTests {
    private func noise(_ seconds: Double, level: Float = 0.0005) -> [Float] {
        (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -level...level) }
    }

    private func speech(_ seconds: Double, amplitude: Float = 0.05) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    @Test("話す前の無音は数えない")
    func waitsForSpeech() {
        var endpoint = DictationEndpoint(silence: 2)
        let ended1 = endpoint.feed(noise(5))
        #expect(!ended1)
        #expect(!endpoint.heardSpeech)
    }

    @Test("話した後に 2 秒の無音が続いたら終わり、1.5 秒では終わらない")
    func endsAfterSilence() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        endpoint.feed(speech(1))
        #expect(endpoint.heardSpeech)
        let ended2 = endpoint.feed(noise(1.5))
        #expect(!ended2)
        let ended3 = endpoint.feed(noise(0.6))
        #expect(ended3)
    }

    @Test("次の区切りに移ると、話す前の無音を数えず、また話して 2 秒黙ったら終わる")
    func nextSegment() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        endpoint.feed(speech(1))
        endpoint.feed(noise(2.1))
        #expect(endpoint.ended)
        endpoint.nextSegment()
        #expect(!endpoint.ended && !endpoint.heardSpeech)
        let waited = endpoint.feed(noise(5))
        #expect(!waited)
        endpoint.feed(speech(1))
        #expect(endpoint.heardSpeech)
        let ended = endpoint.feed(noise(2.1))
        #expect(ended)
    }

    @Test("話している途中の短い間では終わらない")
    func pausesDoNotEnd() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        endpoint.feed(speech(1))
        endpoint.feed(noise(1.5))
        endpoint.feed(speech(0.5))
        let ended4 = endpoint.feed(noise(1.5))
        #expect(!ended4)
    }

    @Test("雑音の 15 dB 上の小さい声でも話したとみなす")
    func quietSpeech() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5, level: 0.001))
        // 一様な雑音 ±0.001 の RMS は 0.00058。振幅 0.0045 の正弦波の RMS は 0.0032 で、約 15 dB 上
        endpoint.feed(speech(1, amplitude: 0.0045))
        #expect(endpoint.heardSpeech)
    }

    @Test("マイクの立ち上がりの無音（0 の音）を雑音の大きさに数えない")
    func ignoresDigitalSilence() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed([Float](repeating: 0, count: 4_800))
        endpoint.feed(noise(0.5))
        let ended1 = endpoint.feed(noise(1))
        #expect(!ended1 && !endpoint.heardSpeech)
        endpoint.feed(speech(1))
        #expect(endpoint.heardSpeech)
        let ended2 = endpoint.feed(noise(2.2))
        #expect(ended2)
    }

    @Test("聞き始めた後に雑音が大きくなっても、5 秒で追いつき、話し終えたら終わる")
    func followsRisingNoise() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5, level: 0.0001))
        endpoint.feed(noise(6, level: 0.002))
        endpoint.feed(speech(1, amplitude: 0.05))
        #expect(endpoint.heardSpeech)
        let ended = endpoint.feed(noise(2.2, level: 0.002))
        #expect(ended)
    }

    /// 20 ms ごとの大きさ（dB）の並びを、その大きさの音にする
    private func levels(_ text: String) -> [Float] {
        text.split(separator: " ").flatMap { db -> [Float] in
            let amplitude = Float(pow(10, Double(db)! / 20))
            return (0..<320).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        }
    }

    /// MacBook Pro の内蔵のマイクで測った 10 秒（20 ms ごとの dB）。立ち上がりに 0 の音と -73 dB の区切りがあり、部屋の雑音は -55〜-67 dB で上下する
    private static let room = "-63 -89 -100 -100 -100 -100 -100 -100 -96 -77 -64 -61 -62 -58 -59 -60 -60 -66 -64 -66 -63 -62 -63 -60 -62 -65 -61 -59 -61 -64 -62 -63 -67 -61 -61 -64 -62 -61 -65 -62 -65 -62 -64 -62 -62 -59 -64 -60 -62 -65 -61 -57 -60 -61 -65 -64 -61 -61 -58 -69 -66 -66 -67 -66 -64 -64 -66 -62 -62 -62 -63 -62 -62 -65 -64 -62 -57 -59 -61 -61 -58 -64 -68 -64 -62 -60 -59 -58 -63 -65 -61 -57 -61 -62 -65 -61 -58 -66 -63 -63 -65 -64 -63 -57 -62 -60 -61 -62 -62 -61 -59 -63 -65 -64 -67 -64 -66 -62 -64 -65 -64 -64 -64 -62 -62 -61 -61 -63 -60 -61 -62 -58 -60 -61 -59 -62 -62 -62 -64 -60 -60 -63 -62 -61 -60 -62 -60 -63 -61 -64 -60 -61 -64 -61 -59 -63 -64 -64 -63 -65 -60 -61 -61 -62 -65 -63 -62 -64 -64 -65 -67 -64 -63 -67 -61 -59 -63 -61 -60 -62 -61 -58 -62 -60 -65 -58 -57 -63 -59 -62 -60 -59 -56 -59 -61 -61 -61 -62 -62 -61 -60 -62 -63 -59 -63 -63 -62 -62 -63 -62 -59 -64 -61 -62 -63 -61 -63 -58 -59 -60 -61 -57 -59 -58 -58 -61 -66 -65 -64 -60 -60 -62 -59 -66 -65 -64 -64 -58 -62 -62 -66 -64 -62 -60 -62 -62 -61 -64 -64 -62 -60 -60 -59 -63 -58 -61 -61 -65 -61 -62 -61 -60 -62 -64 -59 -59 -64 -65 -62 -63 -60 -62 -60 -58 -64 -62 -58 -61 -61 -66 -64 -60 -61 -59 -63 -60 -62 -54 -60 -60 -58 -60 -62 -58 -61 -58 -60 -62 -60 -63 -61 -64 -62 -60 -60 -62 -61 -60 -60 -62 -58 -57 -59 -63 -62 -61 -62 -60 -59 -63 -60 -64 -57 -59 -65 -62 -64 -62 -56 -57 -57 -58 -58 -58 -55 -55 -59 -58 -57 -59 -57 -58 -63 -63 -58 -57 -59 -59 -52 -56 -63 -61 -59 -62 -57 -60 -60 -58 -59 -60 -57 -61 -60 -61 -59 -58 -58 -62 -57 -58 -56 -59 -59 -60 -59 -56 -63 -58 -58 -60 -58 -62 -66 -65 -58 -58 -56 -61 -60 -62 -61 -62 -62 -62 -63 -60 -55 -58 -60 -60 -61 -63 -60 -62 -62 -61 -61 -62 -61 -62 -61 -61 -63 -63 -62 -61 -64 -64 -61 -62 -60 -61 -61 -62 -62 -58 -57 -64 -58 -56 -62 -58 -62 -63 -60 -60 -57 -61 -59 -60 -60 -61 -64 -59 -58 -59 -58 -62 -61 -57 -58 -59 -61 -59 -60 -60 -59 -58 -60 -58 -58 -59 -57 -60 -60 -61 -59 -55 -56 -59 -55 -59 -62 -62 -61 -62 -59 -55 -58 -58 -57 -54 -57 -56 -59 -57 -58 -55 -60 -62 -62 -60 -58 -60 -62 -59 -59 -55 -56 -56"
    /// 同じマイクで、内蔵のスピーカーから 2.2 秒から 8.6 秒まで文を読み上げた 10 秒
    private static let spoken = "-67 -83 -96 -100 -100 -100 -100 -100 -80 -57 -54 -54 -50 -50 -47 -47 -47 -49 -48 -47 -48 -50 -49 -50 -51 -50 -49 -50 -50 -46 -47 -47 -49 -53 -58 -56 -51 -48 -47 -46 -46 -45 -46 -45 -46 -46 -48 -51 -55 -59 -51 -47 -50 -53 -54 -59 -58 -60 -59 -60 -60 -63 -59 -55 -57 -57 -52 -56 -57 -56 -60 -54 -54 -53 -53 -55 -55 -55 -54 -53 -50 -56 -53 -55 -57 -53 -54 -56 -54 -53 -56 -55 -60 -59 -53 -54 -56 -56 -60 -60 -52 -54 -58 -54 -51 -54 -57 -60 -60 -56 -54 -54 -55 -58 -61 -59 -60 -55 -54 -54 -54 -45 -40 -41 -42 -42 -45 -44 -44 -45 -48 -53 -54 -55 -47 -40 -40 -40 -41 -41 -42 -43 -44 -44 -49 -52 -51 -44 -41 -40 -40 -40 -41 -41 -41 -41 -41 -41 -41 -39 -39 -41 -41 -42 -45 -50 -56 -55 -54 -50 -42 -40 -40 -40 -40 -40 -40 -40 -40 -42 -41 -41 -40 -40 -40 -40 -40 -40 -40 -42 -43 -45 -41 -40 -42 -40 -42 -42 -41 -41 -43 -46 -45 -44 -42 -41 -40 -42 -42 -42 -42 -42 -43 -47 -52 -48 -45 -48 -43 -41 -43 -46 -44 -42 -42 -46 -49 -57 -53 -55 -47 -40 -38 -39 -41 -51 -54 -51 -53 -52 -57 -53 -55 -56 -49 -54 -55 -52 -52 -55 -58 -57 -58 -59 -54 -43 -41 -41 -43 -51 -57 -57 -60 -58 -60 -59 -54 -58 -54 -44 -42 -42 -43 -49 -51 -56 -53 -43 -40 -41 -41 -43 -43 -42 -41 -44 -51 -59 -60 -52 -50 -52 -49 -45 -44 -41 -42 -42 -44 -45 -44 -41 -44 -42 -42 -47 -41 -38 -39 -40 -42 -42 -42 -43 -51 -54 -52 -52 -53 -46 -39 -40 -41 -40 -40 -39 -39 -41 -43 -42 -41 -40 -39 -39 -41 -50 -59 -58 -61 -56 -60 -57 -53 -55 -52 -55 -40 -40 -40 -41 -42 -44 -42 -42 -41 -42 -44 -48 -46 -38 -40 -40 -40 -40 -40 -41 -42 -43 -44 -42 -41 -41 -42 -43 -42 -43 -45 -44 -42 -42 -42 -45 -46 -39 -40 -41 -42 -46 -54 -51 -58 -53 -41 -42 -42 -45 -51 -53 -52 -53 -43 -42 -46 -47 -46 -40 -41 -43 -45 -46 -46 -47 -48 -48 -48 -42 -43 -43 -44 -43 -44 -45 -48 -52 -57 -59 -57 -55 -56 -53 -53 -54 -60 -57 -57 -61 -61 -60 -56 -54 -53 -53 -54 -53 -53 -58 -60 -55 -54 -56 -55 -54 -55 -56 -58 -54 -53 -57 -56 -56 -56 -55 -55 -57 -56 -58 -59 -58 -61 -58 -59 -62 -57 -56 -56 -52 -58 -58 -59 -63 -61 -58 -56 -53 -56 -53 -60 -57 -63 -56 -57 -56 -54 -51 -50 -54 -55 -51 -52 -51"

    @Test("実測の部屋の音だけでは話したとみなさない")
    func measuredRoom() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(levels(Self.room))
        endpoint.feed(levels(Self.room))
        #expect(!endpoint.heardSpeech && !endpoint.ended)
    }

    @Test("実測の声の後は、声が終わって 1.5〜2.5 秒で終わる")
    func measuredSpeech() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(levels(Self.spoken))
        #expect(endpoint.heardSpeech && !endpoint.ended)
        // 声は 8.6 秒に終わり、録った音の残りは 1.4 秒。部屋の音を 0.1 秒ずつ足して、終わった時刻を測る
        let tail = levels(Self.room)
        var fed = 0
        while !endpoint.ended, fed < tail.count {
            endpoint.feed(Array(tail[fed..<min(fed + 1_600, tail.count)]))
            fed += 1_600
        }
        let afterSpeech = 1.4 + Double(fed) / 16_000
        #expect(endpoint.ended && afterSpeech >= 1.5 && afterSpeech <= 2.5)
    }

    @Test("雑音を 0 に切るマイクでも、話し終えた後の 0 の音で終わる")
    func gatedMicrophone() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        endpoint.feed(speech(1))
        let ended = endpoint.feed([Float](repeating: 0, count: 36_000))
        #expect(ended)
    }

    @Test("話し終えた後の一瞬の物音（40 ms）では無音の数えを戻さない")
    func ignoresClicks() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        endpoint.feed(speech(1))
        endpoint.feed(noise(1))
        endpoint.feed(speech(0.04, amplitude: 0.2))
        let ended = endpoint.feed(noise(1.2))
        #expect(ended)
    }

    @Test("区切りの途中で切れた音も続けて数える")
    func splitsFrames() {
        var endpoint = DictationEndpoint(silence: 2)
        endpoint.feed(noise(0.5))
        let voice = speech(1)
        for start in stride(from: 0, to: voice.count, by: 137) { endpoint.feed(Array(voice[start..<min(start + 137, voice.count)])) }
        #expect(endpoint.heardSpeech)
    }
}

@Suite("音声入力の校正の要求")
struct DictationPolishRequestTests {
    @Test("人とアシスタントの文を新しいものから 12 件まで、古い順に、1 件 600 字までにする")
    func recentMessages() {
        var messages = (1...20).map { ChatMessage(id: "m\($0)", role: .assistant, kind: .text, text: "発言\($0)") }
        messages.append(ChatMessage(id: "tool", role: .assistant, kind: .toolResult, text: "ツール"))
        messages.append(ChatMessage(id: "long", role: .user, kind: .text, text: String(repeating: "あ", count: 700)))
        let request = DictationPolishRequest(text: "文", taskTitle: "題", taskNumber: 3, messages: messages)
        #expect(request.recent.count == 12)
        #expect(request.recent.first == "発言10")
        #expect(request.recent.last == String(repeating: "あ", count: 600))
        #expect(request.vocabulary.prefix(2) == ["題", "#3"])
        #expect(request.violation == nil)
    }

    @Test("空の文と上限を超えた要求を断る")
    func violations() {
        #expect(DictationPolishRequest(text: "  ").violation != nil)
        #expect(DictationPolishRequest(text: String(repeating: "あ", count: 4001)).violation != nil)
        #expect(DictationPolishRequest(text: "文", recent: Array(repeating: "a", count: 13)).violation != nil)
        #expect(DictationPolishRequest(text: "文", vocabulary: Array(repeating: "a", count: 101)).violation != nil)
        #expect(DictationPolishRequest(text: String(repeating: "あ", count: 4000)).violation == nil)
    }
}
