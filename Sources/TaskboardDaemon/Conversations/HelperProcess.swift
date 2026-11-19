import Foundation
import TaskboardKit

/// 会話の actor の外で起こす CLI。起こして制御要求を送り、閉じる。
/// - 巻き戻しでファイルを戻す補助：会話の key とは別の key（`<会話の id>-rewind`）で `--resume` の CLI を起こす。会話の key と分けるのは、
///   記録を替えた後に daemon が落ちても、起き直した daemon がこの CLI を会話として引き取らないため（記録の無い key なので、繋ぎ直しで止めるだけになる）
/// - 事前起動（`ConversationService` の prewarm）：会話の key で起こして initialize まで済ませ、引き取るときに会話の actor に渡す
actor HelperProcess {
    static let rewindSuffix = "-rewind"

    static func rewindKey(_ conversationID: String) -> String { conversationID + rewindSuffix }

    /// 巻き戻しの補助のプロセスの key なら、その会話の id
    static func rewindConversationID(fromKey key: String) -> String? {
        key.hasSuffix(rewindSuffix) ? String(key.dropLast(rewindSuffix.count)) : nil
    }

    nonisolated let key: String
    private let host: any AgentHostTransport
    private var waiters: [String: CheckedContinuation<ClaudeControlResponse, any Error>] = [:]
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var counter = 0
    private var appliedSeq = 0
    private(set) var exited = false
    /// host に起こさせた（起こす途中に止めると決めたら、起きた後に止める）
    private var spawned = false

    init(key: String, host: any AgentHostTransport) {
        self.key = key
        self.host = host
    }

    /// 起こして購読する。起こせなければ投げる（CLI は動いていない）
    func spawn(argv: [String], env: [String: String], cwd: String) async throws {
        guard !exited else { throw ConversationError.failed("起こす前に止めた") }
        _ = try await host.spawn(key: key, argv: argv, env: env, cwd: cwd)
        spawned = true
        try await host.subscribe(key: key, after: 0)
        // 起こしている間に止めると決めた
        if exited {
            try? await host.signal(key: key, "KILL")
            throw ConversationError.failed("起こす途中で止めた")
        }
    }

    /// daemon が起き直したとき・host に繋ぎ直したとき：控えの続きから受け直す（終わっていれば exit が届く）
    func resubscribe(alive: Bool) async {
        spawned = true
        if !alive { markExited() }
        try? await host.subscribe(key: key, after: appliedSeq)
    }

    /// host の行。制御要求の応答を待っている呼び出しに渡す
    func receive(_ notice: AgentHostNotice) {
        switch notice.event {
        case .output:
            guard let seq = notice.seq, seq > appliedSeq, let line = notice.line else { return }
            appliedSeq = seq
            if case .response(let response) = ClaudeStreamParser.parse(Data(line.utf8), index: seq) {
                waiters.removeValue(forKey: response.requestID)?.resume(returning: response)
            }
        case .gap, .oversize:
            if let through = notice.through ?? notice.seq { appliedSeq = max(appliedSeq, through) }
        case .exit:
            markExited()
        case .shellOutput, .shellExit:
            break
        }
    }

    /// host が起き直した（子は止まっている）
    func hostGone() { markExited() }

    /// 子を会話の actor に渡した：以後の行は受けない。待っている呼び出しを終わらせる（子は止めない）
    func abandon() { markExited() }

    /// 終わるまで待つ（時間の上限なし）
    func waitUntilExited() async {
        while !exited {
            await withCheckedContinuation { exitWaiters.append($0) }
        }
    }

    private func markExited() {
        guard !exited else { return }
        exited = true
        for (_, waiter) in waiters { waiter.resume(throwing: ConversationError.failed("補助のプロセスが終わった")) }
        waiters.removeAll()
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
    }

    /// 制御要求を送って応答を待つ。応答の前に終わるか `timeout` を過ぎたら投げる（送ったものが効いたかは分からない）
    func control(_ subtype: String, _ fields: [String: Any] = [:], timeout: Duration) async throws -> ClaudeControlResponse {
        guard !exited else { throw ConversationError.failed("補助のプロセスが終わった") }
        counter += 1
        let requestID = "tb_rw_\(counter)"
        let data = ClaudeStreamInput.request(id: requestID, subtype: subtype, fields)
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<ClaudeControlResponse, any Error>) in
            waiters[requestID] = waiter
            Task {
                do {
                    try await self.host.write(key: self.key, data)
                } catch {
                    self.fail(requestID, error)
                }
                try? await Task.sleep(for: timeout)
                self.fail(requestID, ConversationError.failed("\(subtype) の応答が無い"))
            }
        }
    }

    private func fail(_ requestID: String, _ error: any Error) {
        waiters.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    /// 入力を閉じて終わるのを待ち、終わらなければ TERM・KILL を送る。終わったのを確かめられたら true
    func finish(_ timing: ConversationTiming) async -> Bool {
        guard spawned else {
            markExited()
            return true
        }
        if !exited { try? await host.closeInput(key: key) }
        if await waitForExit(timing.stopInput) { return true }
        return await kill(timing)
    }

    /// TERM を送り、終わらなければ KILL を送る（daemon が起き直した後に見つけた補助のプロセス）
    func kill(_ timing: ConversationTiming) async -> Bool {
        guard spawned else {
            markExited()
            return true
        }
        if !exited { try? await host.signal(key: key, "TERM") }
        if await waitForExit(timing.stopTerm) { return true }
        try? await host.signal(key: key, "KILL")
        return await waitForExit(timing.stopTerm)
    }

    private func waitForExit(_ timeout: Duration) async -> Bool {
        guard !exited else { return true }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            exitWaiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.releaseExitWaiters()
            }
        }
        return exited
    }

    private func releaseExitWaiters() {
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
    }

    /// `--resume <会話 ID>` の CLI（ファイルの控えを読むための環境変数を付ける。hook は登録しない）
    static func rewindArguments(executable: String, agentSessionID: String, permissionMode: String?) -> [String] {
        [
            executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--resume", agentSessionID,
            "--permission-mode", permissionMode ?? ConversationInput.defaultPermissionMode,
        ]
    }
}
