import Foundation
import Testing

@testable import TaskboardDaemon
@testable import TaskboardKit

@Suite("音声入力の校正")
struct DictationPolisherTests {
    @Test("校正した文の前後の空白を落として返す")
    func returnsPolished() async throws {
        let polisher = DictationPolisher { _ in "  snapshot test を回して\n" }
        #expect(try await polisher.polish(DictationPolishRequest(text: "スナップショットテストを回して")) == "snapshot test を回して")
    }

    @Test("元の文から字数が大きく離れた答えは、指示に答えたとみなして断る")
    func rejectsAnswers() async {
        let long = DictationPolisher { _ in String(repeating: "了解しました。", count: 10) }
        await #expect(throws: DictationPolishError.rejected) { try await long.polish(DictationPolishRequest(text: "確認して")) }
        let empty = DictationPolisher { _ in " " }
        await #expect(throws: DictationPolishError.rejected) { try await empty.polish(DictationPolishRequest(text: "確認して")) }
    }

    @Test("字数の幅は元の半分から 2 倍まで（空白を数えない）")
    func plausibleRange() {
        #expect(DictationPolisher.plausible("ab", from: "abcd"))
        #expect(!DictationPolisher.plausible("a", from: "abcd"))
        #expect(DictationPolisher.plausible("a b c d e f g h", from: "abcd"))
        #expect(!DictationPolisher.plausible("abcdefghi", from: "abcd"))
    }

    @Test("同時に回すのは上限の本数までで、超えた分は混んでいるとして断る")
    func limitsConcurrency() async throws {
        let gate = AsyncGate()
        let polisher = DictationPolisher(concurrency: 1) { request in
            await gate.wait()
            return request.text
        }
        let first = Task { try await polisher.polish(DictationPolishRequest(text: "一つ目")) }
        while await gate.waiting == 0 { await Task.yield() }
        await #expect(throws: DictationPolishError.busy) { try await polisher.polish(DictationPolishRequest(text: "二つ目")) }
        await gate.open()
        #expect(try await first.value == "一つ目")
        #expect(try await polisher.polish(DictationPolishRequest(text: "三つ目")) == "三つ目")
    }

    @Test("標準入力には、タスク・最近の発言（1 件 1 行）・語彙・文字にした文を分けて渡す")
    func input() {
        let request = DictationPolishRequest(text: "段階ビーをマージして", taskTitle: "音声入力", taskNumber: 9, recent: ["段階 B の\nPR です"], vocabulary: ["PR", "#9"])
        #expect(
            ClaudeDictationPolish.input(request) == """
                <task>
                音声入力 #9
                </task>
                <recent>
                - 段階 B の PR です
                </recent>
                <vocabulary>
                PR
                #9
                </vocabulary>
                <dictation>
                段階ビーをマージして
                </dictation>
                """)
    }
}

private actor AsyncGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    var waiting: Int { continuations.count }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}
