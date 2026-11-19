import Foundation
import TaskboardKit

extension AppModel {
    /// 今の接続先と通知の設定を APNs の登録に反映する（iOS・iPadOS だけ）
    func syncPush(force: Bool = false) {
        #if os(iOS)
        PushCenter.shared.sync(
            connections: connections, kinds: DevicePrefs().notifyKinds, turns: DevicePrefs().notifyTurns, sound: DevicePrefs().notifySound,
            isHidden: { !self.fleet.isVisible(fleetID: $0) }, force: force)
        #endif
    }

    /// APNs の通知が届くマシン。このマシンの項目はローカル通知を出さない（2 回鳴らさない）。macOS は APNs を使わないので空
    var pushDeliveringMachines: Set<MachineID> {
        #if os(iOS)
        let delivering = PushCenter.shared.deliveringConnections
        return Set(fleet.allMachines.compactMap { delivering.contains($0.key) ? $0.value.machine?.id : nil })
        #else
        []
        #endif
    }

    /// ターンの完了も APNs で届くマシン。このマシンのターンの完了はローカル通知を出さない。macOS は空
    var pushTurnMachines: Set<MachineID> {
        #if os(iOS)
        let delivering = PushCenter.shared.deliveringTurnConnections
        return Set(fleet.allMachines.compactMap { delivering.contains($0.key) ? $0.value.machine?.id : nil })
        #else
        []
        #endif
    }

    /// 通知の「許可」「拒否」を押した。答えられなければローカル通知で知らせる
    func answerPush(_ answer: PushCenter.Answer) async -> UserFacingError? {
        switch await PushCenter.shared.answer(answer, connections: connections) {
        case .answered:
            return nil
        case .stale:
            // もう答えてある問い。会話を開いて今の問いを見せる
            if let url = answer.url { open(url, from: .notification) }
            return nil
        case .failed(let failure):
            PushCenter.postAnswerFailure(failure, for: answer)
            return failure
        }
    }
}
