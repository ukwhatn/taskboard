import Foundation
import Logging
import Synchronization
import TaskboardKit

/// 1 つの Slack アプリの Socket Mode の接続。止められるまで、切れたら URL を取り直してつなぎ直す。
/// 届いた envelope は、中身を渡す前に受領を返す（3 秒以内に返さないと Slack が送り直す）
struct SlackSocket: Sendable {
    let api: SlackWebAPI
    let appToken: String
    let session: URLSession
    let liveness: Liveness
    let retry: Retry
    /// 接続の様子が変わったとき
    let onState: @Sendable (SlackConnection) async -> Void
    /// 依頼として読めた知らせ
    let onRequest: @Sendable (SlackIncoming) async -> Void
    /// ショートカットと確認の画面の送信（受領を返した後に渡す。ショートカットの `trigger_id` は 3 秒で切れるので、すぐ画面を開く）
    let onInteraction: @Sendable (SlackInteraction) async -> Void
    private let logger = Logger(label: "uk.whatn.taskboardd.slack")

    /// つなぎ直すまでの間。失敗のたびに `first` から倍にして `max` まで延ばす。
    /// Slack に届かなかった失敗（接続の URL を取る HTTP が通らない）は Slack の呼び出しの上限を使わないので、延ばさずに `unreachable` ごとに試す
    struct Retry: Sendable {
        var first: Duration
        var max: Duration
        var unreachable: Duration

        static let standard = Retry(first: .seconds(1), max: .seconds(300), unreachable: .seconds(2))
    }

    /// 黙って死んだ接続を見分ける期限（回線が切れると、受け取りは何も来ないまま待ち続ける）
    struct Liveness: Sendable {
        /// つないでから Slack の hello が来るまで
        var helloTimeout: Duration
        /// hello の後に ping を送る間隔と、pong を待つ時間
        var pingInterval: Duration
        var pongTimeout: Duration

        static let standard = Liveness(helloTimeout: .seconds(30), pingInterval: DaemonStreamConnection.pingInterval, pongTimeout: DaemonStreamConnection.pongTimeout)
    }

    init(
        api: SlackWebAPI, appToken: String, session: URLSession = .shared, liveness: Liveness = .standard, retry: Retry = .standard, onState: @escaping @Sendable (SlackConnection) async -> Void,
        onRequest: @escaping @Sendable (SlackIncoming) async -> Void, onInteraction: @escaping @Sendable (SlackInteraction) async -> Void
    ) {
        self.api = api
        self.appToken = appToken
        self.session = session
        self.liveness = liveness
        self.retry = retry
        self.onState = onState
        self.onRequest = onRequest
        self.onInteraction = onInteraction
    }

    func run() async {
        var backoff = retry.first
        var unreachable = false
        while !Task.isCancelled {
            await onState(.connecting)
            let outcome = await connectOnce()
            if Task.isCancelled { return }
            switch outcome {
            case .refreshed:
                backoff = retry.first
                unreachable = false
                continue
            case .unreachable:
                await onState(.failed(message: Self.message("network")))
                if !unreachable { logger.warning("slack unreachable") }
                unreachable = true
                try? await Task.sleep(for: retry.unreachable)
                continue
            case .failed(let message):
                await onState(.failed(message: message))
                logger.warning("slack connection failed", metadata: ["reason": .string(message)])
                unreachable = false
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, retry.max)
        }
    }

    enum Outcome: Equatable {
        /// Slack が張り直しを求めた・hello の後に切れた（すぐつなぎ直す）
        case refreshed
        /// 接続の URL を取る HTTP が Slack に届かなかった
        case unreachable
        case failed(String)
    }

    private func connectOnce() async -> Outcome {
        let url: URL
        do {
            url = try await api.openConnection(appToken: appToken)
        } catch let failure as SlackWebAPI.Failure where failure.code == "network" {
            return .unreachable
        } catch let failure as SlackWebAPI.Failure {
            return .failed(Self.message(failure.code))
        } catch {
            return .unreachable
        }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
        let greeted = Mutex(false)
        let watchdog = Task { [liveness, logger] in
            try? await Task.sleep(for: liveness.helloTimeout)
            guard !Task.isCancelled else { return }
            guard greeted.withLock({ $0 }) else {
                logger.info("slack hello timed out")
                return task.cancel(with: .goingAway, reason: nil)
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: liveness.pingInterval)
                guard !Task.isCancelled else { return }
                guard await task.ping(timeout: liveness.pongTimeout) else {
                    logger.info("slack ping unanswered")
                    return task.cancel(with: .goingAway, reason: nil)
                }
            }
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await withTaskCancellationHandler {
                    try await task.receive()
                } onCancel: {
                    task.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                return greeted.withLock({ $0 }) ? .refreshed : .failed(Self.message("network"))
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            switch SlackEnvelope.parse(data) {
            case .hello:
                greeted.withLock { $0 = true }
                await onState(.connected)
            case .disconnect(let reason):
                logger.info("slack disconnect", metadata: ["reason": .string(reason)])
                return .refreshed
            case .event(let envelopeID, let request):
                try? await task.send(.string(SlackEnvelope.acknowledgement(envelopeID)))
                if let request { await onRequest(request) }
            case .interactive(let envelopeID, let interaction):
                try? await task.send(.string(SlackEnvelope.acknowledgement(envelopeID)))
                if let interaction { await onInteraction(interaction) }
            case .other(let envelopeID):
                if let envelopeID { try? await task.send(.string(SlackEnvelope.acknowledgement(envelopeID))) }
            case nil:
                continue
            }
        }
        return .refreshed
    }

    /// 接続の失敗を画面に出す文（docs/ui-copy.md のエラーの組み立て。token は含まない）
    static func message(_ code: String) -> String {
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "account_inactive":
            "接続できませんでした。アプリレベルトークンでSlackに接続できません。Slackで作り直して入れ替えてください。"
        case "missing_scope", "not_allowed_token_type":
            "接続できませんでした。アプリレベルトークンにconnections:writeの権限がありません。Slackで権限を付けて作り直してください。"
        case "ratelimited":
            "接続できませんでした。Slackの呼び出しの上限に達しました。時間をおいて接続し直します。"
        default:
            "接続できませんでした。Slackに届きません。時間をおいて接続し直します。"
        }
    }
}
