import Foundation
import Logging
import TaskboardKit

extension ConversationService {
    /// ログインシェルの環境（10 分は取り直さない）。取れなければ daemon の環境から引き継がない変数を除いたもの
    /// 一度取れたら、古くなってもその値をすぐ返して裏で取り直す（負荷の高いときはシェルの起動に 10 秒を超え、履歴の取得や起動を待たせていた）。
    /// 待つのは最初の 1 回だけ。取り直しは同時に 1 本で、取れなかったときは daemon の環境を控える
    /// `forLaunch` は子を起こすとき。daemon の環境で代えた値を渡すと、その子は mise などの PATH を持たないまま動き続けるので、取り直しを待つ
    /// 起こす CLI の環境。ログインシェルの環境に、この daemon の接続先を足す
    func launchEnvironment() async -> [String: String] {
        await loginShellEnvironment(forLaunch: true).merging(environment.daemon?.environment ?? [:]) { $1 }
    }

    func loginShellEnvironment(forLaunch: Bool = false) async -> [String: String] {
        if let cached = loginEnvironment {
            if !cached.fromShell, forLaunch { return await (loginCapture ?? startLoginCapture()).value }
            let stale = !cached.fromShell || environment.now().timeIntervalSince(cached.captured) >= 600
            if stale, loginCapture == nil { _ = startLoginCapture() }
            return cached.values
        }
        return await (loginCapture ?? startLoginCapture()).value
    }

    func startLoginCapture() -> Task<[String: String], Never> {
        let shell = environment.shell
        let capture = Task { await LoginShellEnvironment.capture(shell: shell) }
        let task = Task { [weak self] () -> [String: String] in
            let values = await capture.value
            return await self?.finishLoginCapture(values) ?? values ?? [:]
        }
        loginCapture = task
        return task
    }

    func finishLoginCapture(_ captured: [String: String]?) -> [String: String] {
        loginCapture = nil
        if let captured {
            loginEnvironment = (environment.now(), captured, true)
        } else if let previous = loginEnvironment, previous.fromShell {
            // 前に取れた値があれば、それを使い続ける
            environment.logger.warning("login shell environment unavailable; keeping the previous one", metadata: ["shell": .string(environment.shell)])
            loginEnvironment = (environment.now(), previous.values, true)
        } else {
            environment.logger.warning("login shell environment unavailable; using the daemon environment", metadata: ["shell": .string(environment.shell)])
            let output = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.joined(separator: "\0")
            loginEnvironment = (environment.now(), LoginShellEnvironment.parse("\n\(LoginShellEnvironment.marker)\n" + output) ?? [:], false)
        }
        return loginEnvironment?.values ?? [:]
    }
}
