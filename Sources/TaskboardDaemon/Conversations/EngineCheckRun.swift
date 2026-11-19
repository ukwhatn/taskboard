import Foundation
import TaskboardKit

/// 確かめの 1 回分（`ClaudeCheck`・`CodexCheck`）が持つ、段の実行と出来事の待ち。会話の出来事を全部ためておき、段ごとに「ここより後」を見る
protocol EngineCheckRun: Actor {
    var events: [ConversationEvent] { get set }
    var steps: [EngineCheck.Step] { get set }
    var progress: @Sendable (EngineCheck.Step) -> Void { get }
    /// `mark` より後の返事の文（engine ごとに、返事に数える発言が違う）
    func assistantText(after mark: Int) -> String
}

extension EngineCheckRun {
    static var answerTimeout: Duration { .seconds(180) }

    /// `body` が nil を返したら期待した答えでなかった、"" か文字を返したら通った（文字は補足）
    func step(_ name: String, _ body: () async throws -> String?) async -> Bool {
        let started = ContinuousClock.now
        do {
            if let detail = try await body() {
                note(name, true, [detail, Self.elapsed(since: started)].filter { !$0.isEmpty }.joined(separator: "、"))
                return true
            }
            note(name, false, "答えが違う: \(lastAssistantText().prefix(200))")
        } catch {
            note(name, false, "\(error)")
        }
        return false
    }

    func note(_ name: String, _ passed: Bool, _ detail: String) {
        let step = EngineCheck.Step(name: name, passed: passed, detail: detail)
        steps.append(step)
        progress(step)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return String(format: "%.1f 秒", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    func received(_ event: ConversationEvent) { events.append(event) }

    /// `mark` より後のターンの終わりまで待ち、その間の返事の文を返す
    func turnText(after mark: Int) async throws -> String {
        let turn = try await waitFor(after: mark, Self.answerTimeout) { event in
            if case .turn(let turn) = event.kind { return turn }
            return nil
        }
        if turn.isError { throw CheckFailure("ターンが失敗した（\(turn.stopReason ?? "-")）") }
        return assistantText(after: mark)
    }

    func waitFor<T: Sendable>(after mark: Int, _ timeout: Duration, _ match: (ConversationEvent) -> T?) async throws -> T {
        let deadline = ContinuousClock.now + timeout
        var index = mark
        while ContinuousClock.now < deadline {
            while index < events.count {
                if let found = match(events[index]) { return found }
                index += 1
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CheckFailure("\(timeout) のうちに来なかった")
    }

    func lastAssistantText() -> String {
        assistantText(after: max(events.count - 40, 0))
    }
}

/// host の知らせを key（会話の id）ごとの会話へ回す（フォークの段で 2 つ目の会話を起こす）
final class EngineCheckRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var inboxes: [String: AsyncStream<AgentHostNotice>.Continuation] = [:]
    func set(_ key: String, _ value: AsyncStream<AgentHostNotice>.Continuation) { lock.withLock { inboxes[key] = value } }
    func yield(_ notice: AgentHostNotice) { lock.withLock { inboxes[notice.key] }?.yield(notice) }
}

struct CheckFailure: Error, CustomStringConvertible, Sendable {
    var description: String
    init(_ description: String) { self.description = description }
}
