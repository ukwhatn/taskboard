import CoreImage.CIFilterBuiltins
import SwiftUI
import TaskboardKit

/// 接続先の端末（iPhone・iPad）の区画。登録した端末と、登録の解除
struct DeviceList: View {
    @Environment(AppModel.self) private var model
    let fleetID: String
    let title: String
    @State private var revoking: DeviceInfo?
    @State private var error: UserFacingError?
    /// P7 までの daemon（`/v1/devices` が無い）
    @State private var unsupported = false

    var body: some View {
        let loaded = model.fleet.allMachines[fleetID]?.devices
        let devices = (loaded ?? []).sorted { $0.createdAt > $1.createdAt }
        let paired = model.isPairedConnection(fleetID: fleetID)
        Section {
            if let error {
                Banner(kind: .error, message: error.text) { self.error = nil }
            }
            if unsupported {
                Text("接続先のMacのTaskboardが古いため、デバイスを表示できません。Taskboardを更新してください。").foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(alignment: .firstTextBaseline, spacing: Space.block) {
                        Image(systemName: device.platform == .macos ? "laptopcomputer" : device.platform == .ipados ? "ipad" : "iphone")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).lineLimit(1)
                            DeviceDetail(device: device)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !paired || device.current {
                            Button("登録を解除", role: .destructive) { revoking = device }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("iPhone・iPadを追加", systemImage: "qrcode") { model.pairingSheet = PairingTarget(fleetID: fleetID) }
            }
        } header: {
            Text(title)
        } footer: {
            if !unsupported, loaded != nil, devices.isEmpty {
                Text("登録したデバイスはありません。［iPhone・iPadを追加］でQRコードを表示すると、ここに表示されます。")
            }
        }
        .task {
            do {
                try await model.loadDevices(fleetID: fleetID)
            } catch let failure as SessionSourceError where failure.status == 404 {
                unsupported = true
            } catch {
                self.error = UserFacingError("デバイスの一覧を読み込めませんでした", error: error)
            }
        }
        .confirmationDialog(
            "デバイスの登録解除", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }), titleVisibility: .visible,
            presenting: revoking
        ) { device in
            Button("登録を解除", role: .destructive) { revoke(device) }
            Button("キャンセル", role: .cancel) {}
        } message: { device in
            Text("「\(device.name)」の登録を解除しますか？　このデバイスは\(model.machineName(fleetID: fleetID, state: model.fleet.allMachines[fleetID]))に接続できなくなります。")
        }
    }

    private func revoke(_ device: DeviceInfo) {
        Task {
            do {
                try await model.revokeDevice(device, fleetID: fleetID)
                error = nil
            } catch {
                self.error = UserFacingError("登録を解除できませんでした", error: error)
            }
        }
    }

}

/// 端末の追加日と最後の接続。最後の接続の「3分前」は時間の経過で描き直す（`RelativeTime`）
private struct DeviceDetail: View {
    let device: DeviceInfo

    var body: some View {
        let day = Calendar.current.dateComponents([.month, .day], from: device.createdAt)
        let added = String(localized: "\(day.month ?? 0)/\(day.day ?? 0)に追加")
        HStack(spacing: 0) {
            if let seen = device.lastSeenAt {
                Text(added + "・" + String(localized: "最終接続"))
                RelativeTime(date: seen)
            } else {
                Text(added + "・" + String(localized: "未接続"))
            }
        }
        .textRole(.caption)
        .lineLimit(1)
    }
}
