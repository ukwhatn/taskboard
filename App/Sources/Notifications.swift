import Foundation
import TaskboardKit
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// 受信箱に鳴らす項目が増えたらローカル通知を出す。
/// 通知は観測した差分で出す（daemon は持たない）。マシンごとに、最初に状態が届いたときの一覧は通知しない
/// （起動のたびに既存の分が鳴らないように。起動直後は daemon からまだ何も届いておらず、空の一覧を基準にすると全部が新しく見える）。
/// 1 台だけ表示の間は、隠したマシンの分を「見た」ことにだけして鳴らさない。解除しても、その間に来た分はまとめて鳴らない。
/// iPhone・iPad では APNs の登録（`PushCenter`）も同じ見回りで送り、APNs が届くマシンの分はローカル通知を出さない。
/// ターンの完了（`TurnWatch`）も同じ見回りで見る。見回りの間に応答を始めて終えたものは数えない
@MainActor
final class InboxNotifier: NSObject {
    static let shared = InboxNotifier()
    private weak var model: AppModel?
    private var known: Set<String> = []
    /// 最初の状態が届き、基準を取り終えたマシン
    private var baselined: Set<MachineID> = []
    private var loop: Task<Void, Never>?
    /// 鳴らした項目の id（新しい順に 20 件）。DebugServer の確認用
    private(set) var recentlyPosted: [String] = []
    /// 最後に設定したアイコンの数字。数字を変えるのはこのアプリだけ（APNs の通知は badge を運ばない）なので、変わったときだけ設定し直す
    private var badgeCount: Int?
    /// 前の見回りで見た一覧（鳴らす項目に絞る前）
    private var lastListed: (all: [InboxItem], visible: [InboxItem])?
    /// 接続先ごとの応答中の控え。最初に状態が届いたときの応答中を基準にする
    private var turnWatches: [String: TurnWatch] = [:]

    func start(model: AppModel, provisional: Bool = false) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        #if os(iOS)
        PushCenter.registerCategories()
        center.requestAuthorization(options: provisional ? [.alert, .sound, .badge, .provisional] : [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in
                PushCenter.shared.set(authorization: granted ? .allowed : .denied)
                if granted { PushCenter.shared.requestToken() }
            }
        }
        foreground = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await PushCenter.shared.refreshAuthorization()
                if PushCenter.shared.authorization == .allowed { PushCenter.shared.requestToken() }
                model.syncPush(force: true)
            }
        }
        #else
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        #endif
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    #if os(iOS)
    private var foreground: (any NSObjectProtocol)?
    #endif

    private func tick() {
        guard let model else { return }
        let listed = (all: model.inboxItemsIncludingHidden, visible: model.inboxItems)
        let ready = Set(model.fleet.allMachines.values.compactMap { $0.machine?.id })
        updateBadge(count: model.inboxWaitingCount)
        model.syncPush()
        if ClientPrefsSync.shared.tick(fleet: model.fleet) { model.reloadDevicePrefs() }
        model.reconcileRewindNoticeDismissals()
        model.observeUnread()
        postFinishedTurns(model)
        // 前の見回りと同じ一覧なら、どの項目も既知なので鳴らすものは無い（Fleet は中身が変わるまで同じ一覧を返す）
        if let last = lastListed, last.all == listed.all, last.visible == listed.visible, baselined == ready { return }
        lastListed = listed
        let all = Self.loud(listed.all)
        let visible = Self.loud(listed.visible)
        defer {
            // 同じ PR を 2 台が持つと、隠したマシンを含めた一覧と見えている一覧で残る側が違うことがある。どちらの id も既知にする
            known = Set(all.map(\.id)).union(visible.map(\.id))
            baselined = ready
        }
        let fresh = Self.fresh(
            visible, baselined: baselined, known: known, kinds: DevicePrefs().notifyKinds, deliveredByPush: model.pushDeliveringMachines)
        for item in fresh {
            guard let notification = InboxNotification.make(item, machineName: model.machineName(item.machine)) else { continue }
            post(notification, thread: item.taskKey?.description ?? item.machine.rawValue)
        }
    }

    /// 応答を終えたセッション・会話を鳴らす。設定が「出さない」の間も控えは進める（オンにしたときに前の分が鳴らないように）。
    /// 隠したマシンと、ターンの完了が APNs で届くマシンの分は出さない
    private func postFinishedTurns(_ model: AppModel) {
        let setting = DevicePrefs().notifyTurns
        let byPush = model.pushTurnMachines
        for (fleetID, state) in model.fleet.allMachines {
            guard let machine = state.machine?.id else { continue }
            guard var watch = turnWatches[fleetID] else {
                var watch = TurnWatch()
                watch.reset(state)
                turnWatches[fleetID] = watch
                continue
            }
            let finished = watch.update(state)
            turnWatches[fleetID] = watch
            guard setting != .never, model.fleet.isVisible(fleetID: fleetID), !byPush.contains(machine) else { continue }
            for turn in finished {
                post(turn.notification(machineName: model.machineName(machine)), thread: turn.taskNumber.map { TaskKey(machine: machine, number: $0).description } ?? machine.rawValue)
            }
        }
    }

    /// ローカル通知を出す項目。基準を取り終えたマシンの、まだ見ていない項目のうち、止めていない種類の分
    /// （止めた種類は後でオンにしても、既知に入れたので遡って鳴らさない）。APNs が届くマシンの分は出さない
    static func fresh(
        _ items: [InboxItem], baselined: Set<MachineID>, known: Set<String>, kinds: Set<NotifyKind>, deliveredByPush: Set<MachineID>
    ) -> [InboxItem] {
        items.filter { item in
            guard baselined.contains(item.machine), !known.contains(item.id), !deliveredByPush.contains(item.machine),
                let kind = NotifyKind.of(item)
            else { return false }
            return kinds.contains(kind)
        }
    }

    /// 鳴らす項目（通知の中身を作れる項目）
    static func loud(_ items: [InboxItem]) -> [InboxItem] {
        items.filter { InboxNotification.make($0, machineName: "") != nil }
    }

    private func post(_ notification: InboxNotification, thread: String) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = DevicePrefs().notifySound ? .default : nil
        content.userInfo = ["item": notification.itemID, "url": notification.url.absoluteString]
        if notification.turn { content.userInfo[PushPayload.turn] = "1" }
        content.threadIdentifier = thread
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notification.itemID, content: content, trigger: nil))
        recentlyPosted = Array(([notification.itemID] + recentlyPosted).prefix(20))
    }

    private func updateBadge(count: Int) {
        guard count != badgeCount else { return }
        badgeCount = count
        UNUserNotificationCenter.current().setBadgeCount(count) { [weak self] error in
            // 設定できなかったら次の見回りでもう一度設定する
            guard error != nil else { return }
            Task { @MainActor in self?.badgeCount = nil }
        }
    }
}

extension InboxNotifier: UNUserNotificationCenterDelegate {
    /// アプリが前面のときに届いた通知。ターンの完了は、設定が「常に」のときだけ出す（ローカル通知も APNs も同じ）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let turn = notification.request.content.userInfo[PushPayload.turn] != nil
        return Self.presentation(turn: turn, setting: DevicePrefs().notifyTurns)
    }

    nonisolated static func presentation(turn: Bool, setting: TurnNotify) -> UNNotificationPresentationOptions {
        turn && setting != .always ? [] : [.banner, .sound, .list]
    }

    /// async 版（`didReceive response:) async`）にすると、ObjC 側へ返す completion が別スレッドから呼ばれ、
    /// UIKit が main thread 以外からの completion を assertion で落とした（iPhone 実機、通知を押したとき）。completion は main actor から呼ぶ
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        // 「許可」「拒否」はアプリを前に出さずに答える。閉じていた状態から裏で起きたときも、ここまでに model は作られている
        let answer = PushCenter.Answer(actionID: response.actionIdentifier, userInfo: info)
        let itemID = info["item"] as? String
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        Task { @MainActor in
            if let answer {
                await respond(answer)
            } else {
                model?.openNotification(itemID: itemID, fallback: url)
            }
            completionHandler()
        }
    }

    private func respond(_ answer: PushCenter.Answer) async {
        _ = await model?.answerPush(answer)
    }
}
