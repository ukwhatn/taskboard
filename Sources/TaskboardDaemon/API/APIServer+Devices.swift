import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import Logging
import Security
import TaskboardKit

/// QR 接続のペアリング（一度きりのコード → 端末の token）と、ペアリングした端末の一覧・停止
extension APIServer {
    static let invalidCodeMessage = "コードが違うか、期限が切れている"

    /// 入力の誤りを 1 つずつ文面で返すため、`PairRequest` に直接 decode しない（platform が違うだけで decode 全体が落ちる）
    private struct PairRequestWire: Decodable {
        var code: String?
        var name: String?
        var platform: String?
    }

    static func registerPairRoute(
        _ router: Router<TaskboardRequestContext>, state: DaemonState, dependencies: Dependencies, encoder: JSONEncoder, logger: Logger
    ) {
        let pairings = dependencies.pairings
        router.post("/v1/pair") { request, context in
            guard let store = dependencies.store else { throw APIError.unavailable("store が無い") }
            let source = request.headers[HTTPField.Name("CF-Connecting-IP")!] ?? context.remoteAddress ?? "unknown"
            if let seconds = await pairings.retryAfter(source: source) {
                logger.notice("pairing refused: too many failures", metadata: ["source": .string(source)])
                throw APIError(
                    .tooManyRequests, .pairingTooManyFailures, "失敗が多すぎる。\(seconds) 秒後にやり直す", params: ["seconds": String(seconds)],
                    headers: [.retryAfter: String(seconds)])
            }
            @Sendable func fail(_ reason: String) async -> APIError {
                let blocked = await pairings.recordFailure(source: source)
                // コードは出さない
                logger.notice("pairing failed", metadata: ["source": .string(source), "reason": .string(reason), "blocked": .stringConvertible(blocked)])
                return APIError(.badRequest, .pairingCodeInvalid, invalidCodeMessage)
            }
            guard let body = try? await request.decode(as: PairRequestWire.self, context: context) else {
                throw APIError.invalid("本文が JSON で読めない")
            }
            guard let code = PairingCode.normalize(body.code ?? "") else { throw await fail("malformed code") }
            let name = (body.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...PairRequest.nameLimit).contains(name.count) else {
                throw APIError.invalid("name は 1〜\(PairRequest.nameLimit) 字")
            }
            guard let platform = body.platform.flatMap(DevicePlatform.init(rawValue:)) else {
                let choices = DevicePlatform.allCases.map(\.rawValue).joined(separator: " / ")
                throw APIError.invalid("platform は \(choices) のどれか")
            }
            guard await pairings.reserve(code) == .reserved else { throw await fail("unknown, expired or used code") }

            let token: String
            let device = DeviceInfo(id: UUID().uuidString.lowercased(), name: name, platform: platform, createdAt: Date())
            do {
                token = try randomToken()
                try store.insertDevice(device, tokenHash: DeviceAuth.hash(token: token))
            } catch {
                await pairings.release(code)
                logger.error("pairing insert failed", metadata: ["error": .string("\(error)")])
                throw APIError(.internalServerError, .internalError, "端末を登録できない: \(error)")
            }
            await pairings.consume(code)
            await dependencies.deviceAuth.add(deviceID: device.id, tokenHash: DeviceAuth.hash(token: token))
            logger.info("device paired", metadata: ["device": .string(device.id), "platform": .string(platform.rawValue)])
            await publishDevices(state: state, dependencies: dependencies, logger: logger)
            let machine = await state.machineInfo()
            return try json(PairResponse(deviceID: device.id, token: token, machineID: machine.id.rawValue), encoder)
        }
    }

    static func registerDeviceRoutes(
        v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState,
        dependencies: Dependencies, encoder: JSONEncoder, logger: Logger
    ) {
        // 端末の token は Mac の分だけ通す（ペアリングで足した接続先の画面から QR を出す）。持ち歩く iPhone・iPad を拾った人には端末を増やさせない
        v1.post("pairings") { _, context in
            if case .device(let id) = context.principal, try dependencies.requireStore().devices().first(where: { $0.info.id == id })?.info.platform != .macos {
                throw AuthResponse.forbidden()
            }
            return try json(await dependencies.pairings.issue(), encoder)
        }
        v1.get("devices") { _, context in
            var devices = try await deviceList(store: dependencies.requireStore(), dependencies: dependencies)
            if case .device(let own) = context.principal {
                for index in devices.indices where devices[index].id == own { devices[index].current = true }
            }
            return try json(devices, encoder)
        }
        v1.delete("devices/{id}") { _, context in
            let id = try context.parameters.require("id")
            // 端末の token で止められるのは自分だけ（拾った人が他の端末を止められないため）
            if case .device(let own) = context.principal, own != id { throw AuthResponse.forbidden() }
            guard try dependencies.requireStore().deleteDevice(id: id) else { throw APIError.notFound(.device, "端末 \(id) が無い") }
            // 表から消してキャッシュから外したところで止めたことが確定する。閉じるのと配るのは失敗しても応答を変えない
            let closed = await dependencies.deviceAuth.revoke(deviceID: id)
            logger.info("device revoked", metadata: ["device": .string(id), "sockets": .stringConvertible(closed)])
            await publishDevices(state: state, dependencies: dependencies, logger: logger)
            return Response(status: .noContent)
        }
    }

    /// 表の `lastSeenAt` は 60 秒に 1 回しか書かないので、メモリの値の方が新しければそちらを出す
    private static func deviceList(store: Store, dependencies: Dependencies) async throws -> [DeviceInfo] {
        var devices: [DeviceInfo] = []
        for record in try store.devices() {
            var info = record.info
            if let memory = await dependencies.deviceAuth.lastSeen(deviceID: info.id), memory > (info.lastSeenAt ?? .distantPast) {
                info.lastSeenAt = memory
            }
            devices.append(info)
        }
        return devices
    }

    private static func publishDevices(state: DaemonState, dependencies: Dependencies, logger: Logger) async {
        guard let store = dependencies.store else { return }
        do {
            await state.publishDevices(try await deviceList(store: store, dependencies: dependencies))
        } catch {
            logger.warning("devices.updated not sent", metadata: ["error": .string("\(error)")])
        }
    }

    /// 32 バイトの乱数の hex（token ファイルと同じ作り）
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PathsError.randomFailed(status) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// WebSocket の handler を囲む。認証に落ちた接続は 1 フレームも送らず、inbound も読まずに 4401 で閉じる。
/// 端末の token なら `DeviceAuth` に登録し、止められたら 4401 で閉じて body を終わらせる
enum DeviceSocket {
    static func run(
        principal: Principal?, outbound: WebSocketOutboundWriter, devices: DeviceAuth, willRegister: (@Sendable () async -> Void)?,
        logger: Logger, _ body: @escaping @Sendable () async throws -> Void
    ) async throws {
        guard let principal else {
            try await outbound.close(.unknown(DaemonAuthHeader.revokedCloseCode), reason: "unauthorized")
            return
        }
        guard case .device(let id) = principal else {
            try await body()
            return
        }
        await willRegister?()
        guard let registration = await devices.register(deviceID: id) else {
            // upgrade の判定の後に止められた
            try await outbound.close(.unknown(DaemonAuthHeader.revokedCloseCode), reason: "revoked")
            return
        }
        defer { Task { await devices.unregister(deviceID: id, id: registration.id) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                var revoked = registration.revoked.makeAsyncIterator()
                // body が先に終わって group が cancel されたときは nil で抜ける
                guard await revoked.next() != nil else { return }
                do {
                    try await outbound.close(.unknown(DaemonAuthHeader.revokedCloseCode), reason: "revoked")
                } catch {
                    logger.warning("revoked socket close failed", metadata: ["device": .string(id), "error": .string("\(error)")])
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
