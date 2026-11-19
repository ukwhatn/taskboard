#if DEBUG
import Foundation
import Network
import SwiftUI
import TaskboardKit
import UserNotifications

extension DebugServer {
    /// 接続先と端末の追加
    func respondConnections(to request: HTTPRequest, model: AppModel) async -> HTTPResponse? {
        switch (request.method, request.path) {
        case ("POST", "/pairing"):
            // {"fleetID": "local" | "conn:<uuid>"}。設定の接続先を開いて QR のシートを出す。{"close": true} で閉じる
            let body = request.jsonBody ?? [:]
            if body["close"] as? Bool == true {
                model.pairingSheet = nil
                model.pairingOffer = nil
                return .json(200, ["ok": true])
            }
            guard let fleetID = body["fleetID"] as? String, model.fleet.allMachines[fleetID] != nil else {
                return .json(400, ["error": "fleetID は " + model.fleet.allMachines.keys.sorted().joined(separator: " / ")])
            }
            model.navigate(to: .settings(.connections), from: .debug)
            model.pairingSheet = PairingTarget(fleetID: fleetID)
            return .json(200, ["ok": true])
        case ("POST", "/pair"):
            // {"payloadFile": "<path>"}。QR を読んだ後の確認のシートを出す（シミュレータにカメラが無いため。secret は引数に載せずファイルで渡す）
            guard let path = request.jsonBody?["payloadFile"] as? String, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return .json(400, ["error": "payloadFile が要る"])
            }
            guard let payload = PairingPayload.decode(text) else { return .json(400, ["error": "Taskboard の QR の中身ではない"]) }
            if request.jsonBody?["submit"] as? Bool == true {
                // 確認のシートの「追加」と同じ。シミュレータでは押せないため
                do {
                    try await model.pair(payload, name: payload.name)
                    return .json(200, ["ok": true, "connections": model.connections.map { ["name": $0.name, "paired": $0.pairedDeviceID != nil] }])
                } catch {
                    return .json(502, ["error": UserFacingError("追加できませんでした", error: error)?.text ?? "\(error)"])
                }
            }
            model.navigate(to: .settings(.connections), from: .debug)
            model.pairingOffer = PairingOffer(payload: payload)
            return .json(200, ["ok": true])
        case ("GET", "/connections"):
            // 秘密（token・service token）は返さない
            let rows: [[String: Any]] = model.fleet.machines.map { id, state in
                let saved = model.connections.first { $0.fleetID == id }
                return [
                    "id": id, "name": saved?.name ?? state.machine?.name ?? id, "url": saved?.url.absoluteString ?? "", "connected": state.connected,
                    "authFailure": state.authFailure.map { "\($0)" } as Any, "lastError": state.lastError as Any, "access": saved?.access != nil,
                ]
            }
            return .json(200, ["connections": rows])
        case ("POST", "/connections"):
            // 秘密は引数に載せず、ファイルの path で受ける。accessFile は {"clientID", "clientSecret"} の JSON
            guard let name = request.jsonBody?["name"] as? String, let url = (request.jsonBody?["url"] as? String).flatMap(URL.init(string:)),
                let tokenFile = request.jsonBody?["tokenFile"] as? String
            else { return .json(400, ["error": "name / url / tokenFile が要る"]) }
            do {
                let token = try String(contentsOfFile: NSString(string: tokenFile).expandingTildeInPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                let access = try (request.jsonBody?["accessFile"] as? String).map {
                    try JSONDecoder().decode(AccessCredential.self, from: Data(contentsOf: URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)))
                }
                let id = model.connections.first { $0.name == name }?.id ?? UUID()
                try model.saveConnection(SavedConnection(id: id, name: name, url: url, token: token, access: access))
                return .json(200, ["ok": true, "id": "conn:\(id.uuidString)"])
            } catch {
                return .json(400, ["error": error.localizedDescription])
            }
        case ("POST", "/connections/add"):
            // {"mode": "menu" | "code" | "scan"}。「接続先を追加」のシートを開く。{"close": true} で閉じる
            let body = request.jsonBody ?? [:]
            if body["close"] as? Bool == true {
                model.addingConnection = nil
                return .json(200, ["ok": true])
            }
            let modes: [String: AddConnectionSheet.Mode] = ["menu": .menu, "code": .code, "scan": .scan]
            guard let mode = modes[body["mode"] as? String ?? "menu"] else { return .json(400, ["error": "mode は menu / code / scan"]) }
            model.navigate(to: .settings(.connections), from: .debug)
            model.addingConnection = mode
            return .json(200, ["ok": true])
        case ("POST", "/connections/delete"):
            guard let name = request.jsonBody?["name"] as? String, let connection = model.connections.first(where: { $0.name == name }) else {
                return .json(404, ["error": "その名前の接続先が無い"])
            }
            _ = await model.deleteConnectionAndRevoke(id: connection.id)
            return .json(200, ["ok": true])
        default:
            return nil
        }
    }
}
#endif
