import Foundation
import TaskboardKit
#if os(iOS)
import UIKit
#endif

/// QR のシートを開く接続先（Fleet の id）
struct PairingTarget: Identifiable, Hashable {
    let fleetID: String
    var id: String { fleetID }
}

/// 読んだ QR、または手で入れたコード。確認のシートに渡す
struct PairingOffer: Identifiable, Hashable {
    let id = UUID()
    var payload: PairingPayload
}

extension AppModel {
    /// QR に載せる URL と Access。保存済みの接続先はその値、「この Mac」は別に保存した公開 URL（Keychain を読むので、描画の中で呼ばない）。無ければ nil
    func pairingEndpoint(fleetID: String) -> PublishedEndpoint? {
        if let saved = connections.first(where: { $0.fleetID == fleetID }) { return PublishedEndpoint(url: saved.url, access: saved.access) }
        if fleetID == "local" { return ConnectionStore.loadPublication() }
        return nil
    }

    func savePublication(_ endpoint: PublishedEndpoint) throws {
        try ConnectionStore.savePublication(endpoint)
    }

    /// 端末の token で繋いでいる接続先。daemon は他の端末の登録の解除を 403 で断り、コードの発行は Mac の端末の token にだけ通す
    func isPairedConnection(fleetID: String) -> Bool {
        connections.first { $0.fleetID == fleetID }?.pairedDeviceID != nil
    }

    /// 端末の区画（一覧と［iPhone・iPadを追加］）を出す接続先
    func showsDeviceSection(fleetID: String) -> Bool {
        #if os(macOS)
        true
        #else
        !isPairedConnection(fleetID: fleetID)
        #endif
    }

    func source(fleetID: String) -> (any DaemonWriter)? {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id else { return nil }
        return fleet.terminalSource(for: machine)
    }

    /// 端末の一覧を取り直す。P7 までの daemon は 404
    func loadDevices(fleetID: String) async throws {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id, let source = fleet.terminalSource(for: machine) else { return }
        fleet.setDevices(try await source.devices(), for: machine)
    }

    func revokeDevice(_ device: DeviceInfo, fleetID: String) async throws {
        guard let source = source(fleetID: fleetID) else { throw SessionSourceError.disconnected }
        try await source.revokeDevice(device.id)
        try? await loadDevices(fleetID: fleetID)
    }

    /// コードを daemon に渡して端末の token を受け取り、接続先として保存する。
    /// 同じ URL の接続先があれば置き換える（止められた端末を QR で追加し直したとき、行が増えないように）
    func pair(_ payload: PairingPayload, name: String) async throws {
        let request = PairRequest(code: payload.code, name: String(Self.deviceName.prefix(PairRequest.nameLimit)), platform: Self.devicePlatform)
        let response = try await DaemonClient.pair(request, url: payload.url, access: payload.access)
        let existing = connections.first { $0.url.host() == payload.url.host() && $0.url.port == payload.url.port }
        let connection = SavedConnection(
            id: existing?.id ?? UUID(), name: name, url: payload.url, token: response.token, access: payload.access, pairedDeviceID: response.deviceID)
        do {
            try saveConnection(connection)
        } catch {
            // 保存できないと token を失い、daemon に使えない端末の行だけが残る
            try? await DaemonClient(endpoint: connection.endpoint).revokeDevice(response.deviceID)
            throw error
        }
        // 置き換えた接続先の端末の token は、もうアプリの手元に無い。残すと daemon で有効なまま行だけが増えるので、古い token で自分を止める
        if let existing, let oldDevice = existing.pairedDeviceID, oldDevice != response.deviceID {
            try? await DaemonClient(endpoint: existing.endpoint).revokeDevice(oldDevice)
        }
    }

    /// 端末の token で繋いでいる接続先を消すときは、先に daemon 側の自分の行も登録を解除する。
    /// 解除に失敗しても削除は進め（token はもう使わない）、false を返して画面で知らせる
    func deleteConnectionAndRevoke(id: UUID) async -> Bool {
        var revoked = true
        if let connection = connections.first(where: { $0.id == id }), let deviceID = connection.pairedDeviceID {
            do {
                try await DaemonClient(endpoint: connection.endpoint).revokeDevice(deviceID)
            } catch {
                revoked = false
            }
        }
        deleteConnection(id: id)
        return revoked
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static var devicePlatform: DevicePlatform {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .ipados : .ios
        #else
        .macos
        #endif
    }
}
