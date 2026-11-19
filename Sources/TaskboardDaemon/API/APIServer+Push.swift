import Foundation
import Hummingbird
import Logging
import TaskboardKit

/// iPhone・iPad への通知（APNs）の登録・テスト、通知の「許可」「拒否」の応答
extension APIServer {
    static func registerPushRoutes(
        v1: RouterGroup<TaskboardRequestContext>, daemonOnly: RouterGroup<TaskboardRequestContext>, state: DaemonState,
        dependencies: Dependencies, encoder: JSONEncoder, logger: Logger
    ) {
        @Sendable func requireDevice(_ context: TaskboardRequestContext) throws -> String {
            guard case .device(let id) = context.principal else { throw APIError.invalid("端末の token で呼ぶ（daemon の token では登録できない）") }
            return id
        }

        v1.put("devices/current/push") { request, context in
            let id = try requireDevice(context)
            let body = try await request.decode(as: PushRegistration.self, context: context)
            guard PushRegistration.isValidToken(body.token) else { throw APIError.invalid("token は APNs の端末のトークン（hex で 64〜200 字）") }
            guard (1...PushRegistration.topicLimit).contains(body.topic.count) else {
                throw APIError.invalid("topic は 1〜\(PushRegistration.topicLimit) 字")
            }
            guard body.machineName.count <= PushRegistration.machineNameLimit else {
                throw APIError.invalid("machineName は \(PushRegistration.machineNameLimit) 字まで")
            }
            guard body.connection.count <= PushRegistration.connectionLimit else {
                throw APIError.invalid("connection は \(PushRegistration.connectionLimit) 字まで")
            }
            var registration = body
            registration.token = body.token.lowercased()
            guard try dependencies.requireStore().setPushRegistration(deviceID: id, registration, at: Date()) else {
                throw APIError.notFound(.device, "端末 \(id) が無い")
            }
            let delivering = await dependencies.push?.delivers(to: registration.environment) ?? false
            logger.info(
                "push registered",
                metadata: [
                    "device": .string(id), "token": .string(String(registration.token.prefix(8))), "environment": .string(registration.environment.rawValue),
                    "kinds": .string(registration.kinds.map(\.rawValue).joined(separator: ",")), "turns": .string(registration.turns?.rawValue ?? "-"),
                    "delivering": .stringConvertible(delivering),
                ])
            return try json(PushRegistrationResponse(delivering: delivering, turns: true), encoder)
        }
        v1.delete("devices/current/push") { _, context in
            let id = try requireDevice(context)
            if try dependencies.requireStore().clearPushRegistration(deviceID: id) {
                logger.info("push unregistered", metadata: ["device": .string(id)])
            }
            return Response(status: .noContent)
        }

        daemonOnly.post("push/test") { _, _ in
            guard let push = dependencies.push, await push.hasCredentials() else { throw APIError.unavailable("APNs の鍵が入っていない") }
            let machine = await state.machineInfo()
            return try json(await push.sendTest(machine: machine.id), encoder)
        }
    }
}
