import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 接続の状態の語と文（設定の［接続先］・セッションの一覧・見出しが同じものを出す）と、「このMac」の判定
@MainActor
@Suite struct MachineConnectionStatusTests {
    private func machine(host: AgentHostInfo? = nil) -> MachineInfo {
        MachineInfo(id: MachineID(rawValue: "m"), name: "m", daemonVersion: "t", agentHost: host)
    }

    private func failed(_ failure: SessionSourceError?, lastError: String? = "x") -> MachineState {
        var state = MachineState(lastError: lastError)
        state.authFailure = failure
        return state
    }

    @Test("状態ごとの判定と、行に出す文・見出しの短い語")
    func texts() {
        let cases: [(MachineState?, Bool, MachineConnectionStatus, String, String?)] = [
            (nil, false, .notConnected, "未接続", "未接続"),
            (MachineState(), false, .connecting, "接続しています…", "未接続"),
            (MachineState(machine: machine(), connected: true), false, .connected, "接続済み", nil),
            (MachineState(machine: machine(host: AgentHostInfo(connected: true, draining: true)), connected: true), false, .updatingHost(remaining: 0), "接続済み（更新しています）", nil),
            (
                MachineState(machine: machine(host: AgentHostInfo(connected: true, draining: true, remaining: ["a", "b"])), connected: true), false, .updatingHost(remaining: 2),
                "接続済み（更新を待っています。動いている会話2件を終了すると、会話を起動できます）", nil
            ),
            (failed(.unauthorized), true, .failed(.unpaired), "接続できません。このデバイスの登録が解除されています。QRコードで追加し直してください。", "未接続"),
            (failed(.unauthorized), false, .failed(.unauthorized), "接続できません。接続先のトークンが一致しません。［設定］>［接続先］で資格情報を入力し直してください。", "未接続"),
            (failed(.forbidden), false, .failed(.forbidden), "接続できません。Cloudflare Accessに拒否されました。［設定］>［接続先］でClient IDとClient Secretを確認してください。", "未接続"),
            (failed(nil), false, .failed(.unreachable), "接続できません。ネットワークと、接続先のMacが起動しているかを確認してください。", "未接続"),
        ]
        for (state, paired, status, detail, short) in cases {
            let actual = MachineConnectionStatus.of(state, paired: paired)
            #expect(actual == status)
            #expect(actual.detail == detail)
            #expect(actual.shortLabel == short)
        }
    }

    @Test("資格情報を直す必要があるのは、トークンと Cloudflare Access に断られたときだけ")
    func needsCredentials() {
        #expect(MachineConnectionStatus.failed(.unauthorized).needsCredentials)
        #expect(MachineConnectionStatus.failed(.unpaired).needsCredentials)
        #expect(MachineConnectionStatus.failed(.forbidden).needsCredentials)
        #expect(!MachineConnectionStatus.failed(.unreachable).needsCredentials)
        #expect(!MachineConnectionStatus.connecting.needsCredentials)
    }

    @Test("同じ Mac は既定の接続とループバックのアドレス。fixtures とほかのホストは違う")
    func thisMac() {
        #expect(AppModel.isThisMac(fleetID: "local"))
        #expect(AppModel.isThisMac(fleetID: "http://127.0.0.1:5780"))
        #expect(AppModel.isThisMac(fleetID: "http://localhost:5780"))
        #expect(AppModel.isThisMac(fleetID: "http://[::1]:5780"))
        #expect(!AppModel.isThisMac(fleetID: "https://taskboard-studio.example.com"))
        #expect(!AppModel.isThisMac(fleetID: "fixture:settings"))
    }

    @Test("名前を付けていない接続の名前: 同じ Mac は「このMac」、ほかはホスト名、fixtures はデータの中のマシンの名前")
    func machineNames() {
        AppDefaults.useScratch("test-machine-connection")
        let model = AppModel(options: LaunchOptions(scenario: "settings"))
        #expect(model.machineName(fleetID: "local", state: nil) == "このMac")
        #expect(model.machineName(fleetID: "http://[::1]:5780", state: nil) == "このMac")
        #expect(model.machineName(fleetID: "https://studio.example.com", state: nil) == "studio.example.com")
        #expect(model.machineName(fleetID: "fixture:x", state: MachineState(machine: machine())) == "m")
        #expect(model.machineName(fleetID: "fixture:x", state: nil) == "x")
    }
}
