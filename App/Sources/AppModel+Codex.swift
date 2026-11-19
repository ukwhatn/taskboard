import Foundation
import TaskboardKit

extension AppModel {
    /// そのマシンの codex の値を取り、コネクタを読み直した値で入れ直す（読み直しは 3 秒ほどかかるので、先に今の値を出す）。
    /// codex の口が無い daemon は 404
    func loadCodex(fleetID: String) async throws {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id, let source = fleet.terminalSource(for: machine) else { return }
        fleet.setCodexMachine(try await source.codexMachine(), for: machine)
        fleet.setCodexMachine(try await source.refreshCodexConnectors(), for: machine)
    }

    /// Codex の会話と起動の欄が使うモデルの一覧を、まだ無ければ読む。読めなければ（古い daemon・codex が無い）一覧は無いまま（欄を出さない）
    func loadCodexModels(_ machine: MachineID) async {
        guard fleet.machineState(for: machine)?.codex?.models == nil else { return }
        if scenario != nil {
            if let info = fixtureExtras.codex { fleet.setCodexMachine(info, for: machine) }
            return
        }
        guard let source = fleet.terminalSource(for: machine), let info = try? await source.codexMachine() else { return }
        fleet.setCodexMachine(info, for: machine)
    }

    func startCodexLogin(fleetID: String, name: String) async throws -> CodexConnectorLogin {
        try await codexSource(fleetID).startCodexLogin(name: name)
    }

    /// 認証を解除し、daemon が読み直したコネクタで入れ直す
    func logoutCodexConnector(fleetID: String, name: String) async throws {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id else { throw SessionSourceError.disconnected }
        fleet.setCodexMachine(try await codexSource(fleetID).logoutCodexConnector(name: name), for: machine)
    }

    func sendCodexCallback(fleetID: String, loginId: String, url: String) async throws {
        try await codexSource(fleetID).sendCodexCallback(CodexConnectorCallbackRequest(loginId: loginId, callbackURL: url))
    }

    func cancelCodexLogin(fleetID: String, loginId: String) async {
        try? await codexSource(fleetID).cancelCodexLogin(loginId: loginId)
    }

    /// 認証が終わるまで 3 秒ごとに codex の値を取り直す（daemon の待ちと同じ 10 分まで。画面を閉じたら止める）。
    /// 終わったら、daemon が読み直しているコネクタを待って入れ、結果を返す
    func waitForCodexLogin(fleetID: String, loginId: String) async -> CodexMachineInfo.Login.State? {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id, let source = fleet.terminalSource(for: machine) else { return nil }
        for _ in 0..<200 {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return nil }
            guard let info = try? await source.codexMachine() else { continue }
            fleet.setCodexMachine(info, for: machine)
            guard let state = info.logins?.first(where: { $0.id == loginId })?.state, state != .waiting else { continue }
            if let refreshed = try? await source.refreshCodexConnectors() { fleet.setCodexMachine(refreshed, for: machine) }
            return state
        }
        return nil
    }

    private func codexSource(_ fleetID: String) throws -> any DaemonWriter {
        guard let machine = fleet.allMachines[fleetID]?.machine?.id, let source = fleet.terminalSource(for: machine) else { throw SessionSourceError.disconnected }
        return source
    }
}
