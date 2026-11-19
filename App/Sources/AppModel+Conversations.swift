import Foundation
import OSLog
import TaskboardKit

/// host の会話（stream-json の Claude Code）。画面は `ConversationView`
extension AppModel {
    /// 会話の手元。開き直したら同じ手元を使い、続きだけ取る。fixtures は `FixtureExtras.conversations` の中身
    func conversationFeed(for key: ConversationKey) -> ConversationFeed {
        guard let source = fleet.conversationSource(for: key.machine) else {
            return conversationFeeds.use(key) { ConversationFeed(key: key, fixture: fixtureExtras.conversationTimeline(key.id), tools: fixtureExtras.conversations[key.id]) }
        }
        let feed = conversationFeeds.use(key) { ConversationFeed(key: key, fleet: fleet, source: source) }
        feed.use(source)
        feed.onDelivered = { [weak self] in self?.dismissRewindNotice(key) }
        return feed
    }

    /// 巻き戻した後に送れたら、［元に戻す］のバーを出さない印を付ける（送った後に元に戻すと送った発言ごと捨てるので、バーでは勧めない）
    func dismissRewindNotice(_ key: ConversationKey) {
        guard let conversation = fleet.conversation(for: key) else { return }
        rewindNoticeDismissals.dismiss(conversation)
    }

    /// 要らなくなった印を消す。会話の一覧を読み終えたマシン（接続していて、state の snapshot を受けた）だけ突き合わせる
    func reconcileRewindNoticeDismissals() {
        var listed: [MachineID: [ConversationKey: Conversation]] = [:]
        for state in fleet.allMachines.values where state.connected {
            if let machine = state.machine?.id { listed[machine] = state.conversations }
        }
        var next = rewindNoticeDismissals
        if next.reconcile(listed: listed) { rewindNoticeDismissals = next }
    }

    /// マシンの会話（作った順）。オーケストレーターの会話はその画面に出すので除く
    func conversations(in state: MachineState) -> [Conversation] {
        state.conversations.values.filter { $0.purpose != .orchestrator }.sorted(by: Conversation.listOrder)
    }

    /// 起動の画面で会話を選んでいる間、daemon に同じ条件のプロセスを先に起こさせる（［起動］までの待ちを縮めるため）。
    /// 速くするためだけの呼び出しなので、失敗（古い daemon の 404 を含む）は画面に出さず、ログと debug の `/state` にだけ残す
    func prewarmConversation(_ target: ConversationPrewarmTarget?) async {
        guard ConversationPrewarmSchedule.shouldCall(target, last: lastPrewarm?.call, now: Date()), let target,
            let source = fleet.conversationSource(for: target.machine)
        else { return }
        let call = ConversationPrewarmSchedule.Call(target: target, at: Date())
        do {
            try await source.prewarmConversation(target.request)
            lastPrewarm = PrewarmRecord(call: call, error: nil)
        } catch {
            // 失敗した条件は覚えない（次に開いたときにまた呼ぶ）
            lastPrewarm = PrewarmRecord(call: nil, error: String(describing: error))
            Self.conversationLogger.debug("prewarm failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// オーケストレーターの画面の［停止］。プロセスを止める（常駐がオンなら daemon が起こし直す）
    func stop(conversation key: ConversationKey) {
        guard let source = fleet.conversationSource(for: key.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.stopConversation(key.id)
            } catch {
                fail("会話を停止できませんでした", error, in: window)
            }
        }
    }

    /// 会話に名前を付ける（空にすると外し、自動の題に戻る）。付いた名前は daemon の知らせで届く
    func renameConversation(_ key: ConversationKey, to name: String) async throws {
        guard let source = fleet.conversationSource(for: key.machine) else { throw ActionError.notWritable(fleet.writeAccess(key.machine)) }
        _ = try await source.controlConversation(key.id, ConversationControlRequest(kind: .rename, value: name.isEmpty ? nil : name))
    }

    func clearConversationName(_ key: ConversationKey) {
        let window = activeWindow
        Task {
            do {
                try await renameConversation(key, to: "")
            } catch {
                fail("名前を外せませんでした", error, in: window)
            }
        }
    }

    /// メニューの［終了］。確かめずに終える（daemon は記録を消さず終了の印を付け、送るか再開すると戻る）
    func close(conversation key: ConversationKey) {
        guard let source = fleet.conversationSource(for: key.machine) else { return }
        let window = beginAction()
        Task {
            do {
                try await source.closeConversation(key.id)
            } catch {
                fail("会話を終了できませんでした", error, in: window)
            }
        }
    }
}

extension Conversation {
    /// 画面に出す名前。題が無ければ「Claude Code」
    var displayTitle: String { title?.isEmpty == false ? title! : String(localized: "Claude Code") }

    /// 止まった理由が起こせなかった・予期しない終わりのときの、会話の画面の帯。人や taskboard が止めた会話は待機と同じ扱いで帯を出さない（送れば起きる）
    var stoppedFailure: UserFacingError? {
        guard phase == .stopped, let lastExit else { return nil }
        switch ConversationStopCause(lastExit: lastExit) {
        case .startFailed: return UserFacingError("会話を起動できませんでした", remedy: String(localized: "送信すると、起動し直します"))
        case .unexpected where stoppedInTurn: return UserFacingError("会話が途中で動かなくなりました", remedy: String(localized: "送信すると、起動し直します"))
        default: return nil
        }
    }
}

/// 最後に呼んだ事前起動（debug の `/state`）
struct PrewarmRecord {
    var call: ConversationPrewarmSchedule.Call?
    var error: String?
}

extension AppModel {
    static let conversationLogger = Logger(subsystem: "uk.whatn.taskboard", category: "conversation")
}
