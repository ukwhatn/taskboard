import Foundation
import Logging
import TaskboardKit

/// codex app-server の stdio。本物は `CodexAppServerProcess`、テストは行を返す偽物
protocol CodexChannel: Sendable {
    /// stdout の 1 行ずつ（改行を除く）。子が終わると終わる
    var lines: AsyncStream<Data> { get }
    func write(_ data: Data) throws
    func terminate()
}

/// thread を持たない codex app-server を daemon の子として 1 本持ち、アカウント・利用枠・モデルの一覧・コネクタを読む。
/// 子が終わったら間をおいて起こし直す（間は `Timing.restartMax` まで倍にしていく）
actor CodexMachine {
    struct Timing: Sendable {
        var request: Duration = .seconds(30)
        /// 利用枠を読み直す間（thread の無い接続には `account/rateLimits/updated` がほぼ来ない）
        var refresh: Duration = .seconds(300)
        /// `account/rateLimits/updated`・`account/updated` が続けて届いたとき、まとめて 1 回読むまでの間
        var coalesce: Duration = .seconds(3)
        var restartFirst: Duration = .seconds(2)
        var restartMax: Duration = .seconds(300)
        /// これより長く動いた子が終わったら、起こし直す間を最初に戻す
        var healthy: Duration = .seconds(60)
        /// コネクタの読み直しを頼まれても、前に読んでからこれより短ければ読まない（1 回 3 秒ほどかかり、MCP の server を起こす）
        var connectorsMinInterval: TimeInterval = 30
        /// コネクタの認証を待つ長さ（codex に `timeoutSecs` で渡し、過ぎた待ちの戻り先のアドレスは開かない）
        var login: TimeInterval = 600
    }

    typealias Launch = @Sendable () async throws -> any CodexChannel
    /// 戻り先のアドレスをこのマシンの上で開く（redirect は追わない）。本物は `CodexCallbackOpener.open`
    typealias OpenCallback = @Sendable (URL) async throws -> Void
    /// `codex mcp logout <名前>` を走らせる。失敗は `LogoutError`。本物は `CodexConnectors.logout`
    typealias Logout = @Sendable (String) async throws -> Void

    private let state: DaemonState
    private let launch: Launch
    private let timing: Timing
    private let now: @Sendable () -> Date
    private let openCallback: OpenCallback
    private let logoutCommand: Logout
    private let logger: Logger

    private(set) var version: String?
    private(set) var account: CodexMachineInfo.Account?
    private(set) var models: [CodexMachineInfo.Model]?
    private(set) var connectors: [CodexMachineInfo.Connector]?
    private var connectorsReadAt: Date?
    private var connectorsRead: Task<Void, Never>?

    private var session: Session?
    private var logins: CodexOAuthLogins
    /// コネクタごとの最後の認証の結果
    private var loginResults: [String: CodexMachineInfo.Login] = [:]

    private struct Session {
        let channel: any CodexChannel
        var ids: CodexRequestIDs
        let triggers: AsyncStream<Trigger>.Continuation
        var pending: [CodexRequestID: CheckedContinuation<CodexRPCLine, any Error>] = [:]
        /// 起こした直後の読みが済むまでは、届いた更新の合図で読み直さない（その読みに含まれる）
        var ready = false
        var scheduled: Set<Trigger> = []
    }

    private enum Trigger: Hashable, Sendable {
        case rateLimits
        case account
        /// 認証が終わった（30 秒の間隔に関わらず読む）
        case connectors
    }

    private enum RequestError: Error {
        case timeout
        case closed
    }

    init(
        state: DaemonState, launch: @escaping Launch, timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() },
        openCallback: @escaping OpenCallback = CodexCallbackOpener.open, logout: @escaping Logout = CodexConnectors.logout(),
        logger: Logger = Logger(label: "uk.whatn.taskboardd.codex")
    ) {
        self.state = state
        self.launch = launch
        self.timing = timing
        self.now = now
        self.openCallback = openCallback
        self.logoutCommand = logout
        self.logger = logger
        logins = CodexOAuthLogins(limit: timing.login)
    }

    func run() async {
        var generation = 0
        var delay = timing.restartFirst
        while !Task.isCancelled {
            generation += 1
            let started = ContinuousClock.now
            await runSession(generation: generation)
            if Task.isCancelled { break }
            if ContinuousClock.now - started >= timing.healthy { delay = timing.restartFirst }
            logger.notice("codex app-server ended; restarting", metadata: ["delay": .stringConvertible(delay)])
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, timing.restartMax)
        }
    }

    func info() -> CodexMachineInfo {
        dropExpiredLogins()
        return CodexMachineInfo(
            connected: session?.ready == true, version: version, account: account, models: models, connectors: connectors,
            connectorsReadAt: connectorsReadAt,
            logins: (logins.waiting.values.map { CodexMachineInfo.Login(id: $0.loginId, name: $0.name, state: .waiting) } + loginResults.values).sorted { $0.name < $1.name })
    }

    /// コネクタを読み直してから今の値を返す。前に読んでから `connectorsMinInterval` 秒たっていなければ読まず、読んでいる途中なら終わるのを待つ
    func refreshConnectors() async -> CodexMachineInfo {
        await refreshConnectors(force: false)
    }

    private func refreshConnectors(force: Bool) async -> CodexMachineInfo {
        if let connectorsRead {
            await connectorsRead.value
            if !force { return info() }
        }
        if session?.ready == true, force || connectorsReadAt.map({ now().timeIntervalSince($0) >= timing.connectorsMinInterval }) ?? true {
            let read = Task { await readConnectors() }
            connectorsRead = read
            await read.value
            connectorsRead = nil
        }
        return info()
    }

    /// 子を終わらせる（daemon の終わり。`run` の task を cancel しても終わる）
    func shutdown() {
        session?.channel.terminate()
    }

    private func runSession(generation: Int) async {
        let channel: any CodexChannel
        do {
            channel = try await launch()
        } catch {
            logger.warning("codex app-server unavailable", metadata: ["error": .string("\(error)")])
            return
        }
        let (triggers, continuation) = AsyncStream<Trigger>.makeStream()
        session = Session(channel: channel, ids: CodexRequestIDs(generation: generation), triggers: continuation)
        let reader = Task {
            for await data in channel.lines { self.received(data) }
            continuation.finish()
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: timing.refresh)
                continuation.yield(.rateLimits)
            }
        }
        defer {
            ticker.cancel()
            reader.cancel()
            channel.terminate()
            continuation.finish()
            if let pending = session?.pending.values {
                for waiter in pending { waiter.resume(throwing: RequestError.closed) }
            }
            session = nil
            // 子が終わると codex の待ちも消える
            for login in logins.waiting.values { loginResults[login.name] = CodexMachineInfo.Login(id: login.loginId, name: login.name, state: .failed) }
            logins.removeAll()
        }

        guard await handshake(channel) else { return }
        await readAccount()
        await readRateLimits()
        await readModels()
        await readConnectors()
        session?.ready = true
        for await trigger in triggers {
            session?.scheduled.remove(trigger)
            switch trigger {
            case .rateLimits:
                await readRateLimits()
            case .account:
                await readAccount()
                await readRateLimits()
            case .connectors:
                _ = await refreshConnectors(force: true)
            }
        }
    }

    private func handshake(_ channel: any CodexChannel) async -> Bool {
        let params = InitializeParams(
            clientInfo: .init(name: "taskboard", title: "taskboard", version: Daemon.version), capabilities: .init(experimentalApi: true))
        guard case .value(let result) = await read("initialize", params, as: InitializeResult.self) else { return false }
        version = Self.version(userAgent: result.userAgent)
        logger.notice("codex app-server connected", metadata: ["version": .string(version ?? "unknown")])
        do {
            try channel.write(CodexRPC.notification(method: "initialized"))
        } catch {
            return false
        }
        return true
    }

    // MARK: コネクタの認証

    /// `mcpServer/oauth/login` で認証を始め、開く認証のページを返す。同じコネクタの前の待ちは消す
    func startLogin(name: String) async throws -> CodexConnectorLogin {
        guard session?.ready == true else { throw CodexOAuthLogins.Failure.notConnected }
        let line: CodexRPCLine
        do {
            line = try await request("mcpServer/oauth/login", logins.params(name: name))
        } catch {
            throw CodexOAuthLogins.Failure.notConnected
        }
        if case .failure(_, let code, let message) = line.kind {
            logger.notice("codex oauth login refused", metadata: ["connector": .string(name), "code": .stringConvertible(code)])
            throw CodexOAuthLogins.Failure.refused(message)
        }
        let (loginId, page) = try logins.start(name: name, response: line, at: now())
        loginResults[name] = nil
        logger.notice("codex oauth login started", metadata: ["connector": .string(name), "login": .string(loginId)])
        return CodexConnectorLogin(loginId: loginId, authorizationURL: page.absoluteString)
    }

    /// ほかの端末で受けた戻り先のアドレスを、このマシンの上で 1 度だけ開く。
    /// 開くのは `OAuthLinks.callback` を満たし、port・path・state が待っている認証の redirect_uri と同じものだけ
    func deliverCallback(loginId: String, url raw: String) async throws {
        dropExpiredLogins()
        let url = try logins.openCallback(loginId: loginId, url: raw)
        do {
            try await openCallback(url)
        } catch {
            logins.callbackFailed(loginId: loginId)
            logger.notice("codex oauth callback unreachable", metadata: ["connector": .string(logins.waiting[loginId]?.name ?? "")])
            throw CodexOAuthLogins.Failure.callbackUnreachable
        }
    }

    /// 待ちを消す。codex には取り消しの口が無いので、codex の待ちは時間が過ぎるまで残る
    func cancelLogin(loginId: String) {
        logins.cancel(loginId: loginId)
    }

    /// 時間の過ぎた待ちは失敗にする
    private func dropExpiredLogins() {
        for login in logins.expire(at: now()) {
            loginResults[login.name] = CodexMachineInfo.Login(id: login.loginId, name: login.name, state: .failed)
        }
    }

    private func loginCompleted(_ line: CodexRPCLine) {
        dropExpiredLogins()
        guard let (login, success) = logins.complete(line) else { return }
        loginResults[login.name] = CodexMachineInfo.Login(id: login.loginId, name: login.name, state: success ? .succeeded : .failed)
        logger.notice("codex oauth login completed", metadata: ["connector": .string(login.name), "success": .stringConvertible(success)])
        session?.triggers.yield(.connectors)
    }

    // MARK: コネクタの認証の解除

    enum LogoutError: Error, Equatable {
        case notConnected
        /// 読んだコネクタの一覧に無い名前
        case unknownConnector
        /// codex がログインシェルの PATH に無い・起こせない
        case codexUnavailable
        /// codex が終了コード 0 以外で終わった（OAuth でないコネクタ、設定に無い名前など）
        case refused
        case timedOut
    }

    /// `codex mcp logout` でコネクタの認証を解除し、コネクタを読み直した今の値を返す。名前は今読んでいるコネクタのものだけ受ける
    func logout(name: String) async throws -> CodexMachineInfo {
        guard session?.ready == true else { throw LogoutError.notConnected }
        guard connectors?.contains(where: { $0.name == name }) == true else { throw LogoutError.unknownConnector }
        do {
            try await logoutCommand(name)
        } catch {
            logger.notice("codex mcp logout failed", metadata: ["connector": .string(name), "reason": .string("\(error)")])
            throw error
        }
        logger.notice("codex mcp logout done", metadata: ["connector": .string(name)])
        // 走らせた CLI が消した資格情報を app-server は覚えているので、読み直させてから読む（失敗しても読み直す）
        _ = await read("config/mcpServer/reload", EmptyParams(), as: IgnoredResult.self)
        return await refreshConnectors(force: true)
    }

    // MARK: 読む

    private func readAccount() async {
        switch await read("account/read", EmptyParams(), as: AccountResult.self) {
        case .value(let result): account = CodexMachineInfo.Account(kind: result.account?.type, planType: result.account?.planType)
        case .unsupported: account = nil
        case .unavailable: break
        }
    }

    private func readRateLimits() async {
        switch await read("account/rateLimits/read", RateLimitsParams(excludeResetCreditDetails: true), as: RateLimitsResult.self) {
        case .value(let result): await state.setCodex(Self.usage(result.rateLimits, at: now()))
        case .unsupported: await state.setCodex(nil)
        case .unavailable: break
        }
    }

    private func readModels() async {
        switch await readPages("model/list", { ModelListParams(cursor: $0, includeHidden: true) }, as: ModelEntry.self) {
        case .value(let list): models = list.map(\.model)
        case .unsupported: models = nil
        case .unavailable: break
        }
    }

    private func readConnectors() async {
        switch await readPages("mcpServerStatus/list", { McpStatusParams(cursor: $0, detail: "toolsAndAuthOnly") }, as: ConnectorEntry.self) {
        case .value(let list):
            connectors = list.map(\.connector)
            connectorsReadAt = now()
        case .unsupported:
            connectors = nil
            connectorsReadAt = now()
        case .unavailable: break
        }
    }

    private enum ReadResult<T> {
        case value(T)
        /// method が無い（JSON-RPC の error）か、応答の形が読めない。古い codex では値を無しにする
        case unsupported
        /// 子が答えない・終わった。前の値を残す
        case unavailable
    }

    private static let pageLimit = 20

    private func readPages<P: Encodable & Sendable, T: Decodable>(
        _ method: String, _ params: (String?) -> P, as type: T.Type
    ) async -> ReadResult<[T]> {
        var items: [T] = []
        var cursor: String?
        for _ in 0..<Self.pageLimit {
            switch await read(method, params(cursor), as: Page<T>.self) {
            case .value(let page):
                items += page.data
                guard let next = page.nextCursor else { return .value(items) }
                cursor = next
            case .unsupported: return .unsupported
            case .unavailable: return .unavailable
            }
        }
        return .value(items)
    }

    private func read<P: Encodable & Sendable, T: Decodable>(_ method: String, _ params: P, as type: T.Type) async -> ReadResult<T> {
        let line: CodexRPCLine
        do {
            line = try await request(method, params)
        } catch {
            logger.warning("codex read failed", metadata: ["method": .string(method), "error": .string("\(error)")])
            return .unavailable
        }
        if case .failure(_, let code, _) = line.kind {
            logger.notice("codex method unsupported", metadata: ["method": .string(method), "code": .stringConvertible(code)])
            return .unsupported
        }
        do {
            return .value(try line.result(type))
        } catch {
            logger.notice("codex response unreadable", metadata: ["method": .string(method), "error": .string("\(error)")])
            return .unsupported
        }
    }

    private func request<P: Encodable & Sendable>(_ method: String, _ params: P) async throws -> CodexRPCLine {
        guard var current = session else { throw RequestError.closed }
        let id = current.ids.next()
        session = current
        let data = try CodexRPC.request(id: id, method: method, params: params)
        let timeout = Task { [timing] in
            try await Task.sleep(for: timing.request)
            self.fail(id, RequestError.timeout)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                guard session != nil else { return waiter.resume(throwing: RequestError.closed) }
                session?.pending[id] = waiter
                do {
                    try current.channel.write(data)
                } catch {
                    fail(id, error)
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    private func fail(_ id: CodexRequestID, _ error: any Error) {
        session?.pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func received(_ data: Data) {
        guard let line = CodexRPCLine(data) else { return }
        switch line.kind {
        case .response(let id), .failure(let id, _, _):
            session?.pending.removeValue(forKey: id)?.resume(returning: line)
        case .notification(let method):
            switch method {
            // 一部の欄だけを運ぶ（従量の契約の `individualLimit` は null で届く）ので、値は使わず読み直す
            case "account/rateLimits/updated": schedule(.rateLimits)
            case "account/updated": schedule(.account)
            case "mcpServer/oauthLogin/completed": loginCompleted(line)
            default: break
            }
        case .request(_, let method):
            // thread の無い接続には、答えの要る要求は来ない想定。来たら答えずに記録だけ残す
            logger.notice("codex server request ignored", metadata: ["method": .string(method)])
        }
    }

    private func schedule(_ trigger: Trigger) {
        guard var current = session, current.ready, !current.scheduled.contains(trigger) else { return }
        current.scheduled.insert(trigger)
        session = current
        let triggers = current.triggers
        Task { [timing] in
            try? await Task.sleep(for: timing.coalesce)
            triggers.yield(trigger)
        }
    }

    // MARK: 写す

    /// `individualLimit` は従量の契約の枠で、`monthly` に入れる。使用率は used / limit（枠を超えても 100 で止まらない）、
    /// 読めなければ 100 − remainingPercent（remainingPercent は 0 で止まる）
    static func usage(_ snapshot: RateLimitSnapshot, at date: Date) -> CodexUsage? {
        func window(_ raw: RateLimitSnapshot.Window?) -> UsageWindow? {
            guard let raw else { return nil }
            return UsageWindow(
                usedPercent: raw.usedPercent, resetsAt: raw.resetsAt.map { Date(timeIntervalSince1970: $0) },
                windowSeconds: (raw.windowDurationMins ?? 0) * 60)
        }
        var monthly: CodexUsage.Monthly?
        if let limit = snapshot.individualLimit {
            let used = Double(limit.used)
            let total = Double(limit.limit)
            let percent: Double
            if let used, let total, total > 0 {
                percent = used / total * 100
            } else {
                percent = 100 - limit.remainingPercent
            }
            monthly = CodexUsage.Monthly(usedPercent: percent, used: used, limit: total, resetsAt: limit.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
        let usage = CodexUsage(primary: window(snapshot.primary), secondary: window(snapshot.secondary), monthly: monthly, fetchedAt: date)
        return usage.primary == nil && usage.secondary == nil && usage.monthly == nil ? nil : usage
    }

    /// `initialize` の `userAgent`（`taskboard/0.162.1 (Mac OS 26.7.1; arm64) ...`）の版
    static func version(userAgent: String) -> String? {
        guard let slash = userAgent.firstIndex(of: "/") else { return nil }
        let rest = userAgent[userAgent.index(after: slash)...]
        let token = rest.prefix { !$0.isWhitespace }
        return token.first?.isNumber == true ? String(token) : nil
    }
}

// MARK: 読んだ値の形（email・token・URL は読まない）

/// `model/list` の 1 件。古い codex に無い欄は既定の値にする
private struct ModelEntry: Decodable {
    var model: CodexMachineInfo.Model

    enum CodingKeys: String, CodingKey {
        case id, displayName, isDefault, hidden, defaultReasoningEffort, supportedReasoningEfforts
    }

    private struct EffortOption: Decodable {
        var reasoningEffort: String
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        model = CodexMachineInfo.Model(
            id: id, displayName: try c.decodeIfPresent(String.self, forKey: .displayName) ?? id,
            isDefault: try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false, hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
            defaultEffort: try c.decodeIfPresent(String.self, forKey: .defaultReasoningEffort),
            efforts: try c.decodeIfPresent([EffortOption].self, forKey: .supportedReasoningEfforts)?.map(\.reasoningEffort) ?? [])
    }
}

/// `mcpServerStatus/list` の 1 件。tools は数だけを読む
private struct ConnectorEntry: Decodable {
    var connector: CodexMachineInfo.Connector

    enum CodingKeys: String, CodingKey {
        case name, authStatus, runtimeStatus, tools, toolsError
    }

    private struct AnyValue: Decodable {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connector = CodexMachineInfo.Connector(
            name: try c.decode(String.self, forKey: .name), authStatus: try c.decodeIfPresent(String.self, forKey: .authStatus),
            runtimeStatus: try c.decodeIfPresent(String.self, forKey: .runtimeStatus),
            toolCount: try c.decodeIfPresent([String: AnyValue].self, forKey: .tools)?.count ?? 0,
            toolsError: try c.decodeIfPresent(String.self, forKey: .toolsError) != nil)
    }
}

/// `account/rateLimits/read` の `rateLimits`（窓のある契約は primary・secondary、従量の契約は individualLimit）
struct RateLimitSnapshot: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        var usedPercent: Double
        var windowDurationMins: Int?
        var resetsAt: TimeInterval?
    }

    struct IndividualLimit: Decodable, Sendable {
        /// 数の文字列（"6000"・"4304.33"）
        var limit: String
        var used: String
        var remainingPercent: Double
        var resetsAt: TimeInterval?
    }

    var primary: Window?
    var secondary: Window?
    var individualLimit: IndividualLimit?
}

// MARK: 要求と応答の形（要る欄だけ）

private struct EmptyParams: Encodable, Sendable {}

/// 中身を使わない応答（`{}` でも null でも読める）
private struct IgnoredResult: Decodable {
    init(from decoder: any Decoder) throws {}
}

private struct InitializeParams: Encodable, Sendable {
    struct ClientInfo: Encodable, Sendable {
        var name: String
        var title: String
        var version: String
    }
    struct Capabilities: Encodable, Sendable {
        var experimentalApi: Bool
    }
    var clientInfo: ClientInfo
    var capabilities: Capabilities
}

private struct InitializeResult: Decodable {
    var userAgent: String
}

private struct AccountResult: Decodable {
    struct Account: Decodable {
        var type: String
        var planType: String?
    }
    var account: Account?
}

private struct RateLimitsParams: Encodable, Sendable {
    var excludeResetCreditDetails: Bool
}

private struct RateLimitsResult: Decodable {
    var rateLimits: RateLimitSnapshot
}

private struct ModelListParams: Encodable, Sendable {
    var cursor: String?
    var includeHidden: Bool
}

private struct McpStatusParams: Encodable, Sendable {
    var cursor: String?
    var detail: String
}

private struct Page<T: Decodable>: Decodable {
    var data: [T]
    var nextCursor: String?
}
