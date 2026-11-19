import Foundation

/// Store の書き込みが触ったもの。受け手（`StatePublisher`）が Store から今の行を読み直し、`DaemonState` に入れる（無くなっていれば外す）
enum StoreChange: Hashable, Sendable {
    case board(String)
    /// タスク（作業項目・文書・質問・紐づけの数の欄も、ここで読み直す）
    case task(Int)
    /// タスクの作業項目の全部（並びの付け替えはほかの項目の position も動かす）
    case workItems(task: Int)
    case document(Int64)
    case ask(Int64)
    /// タスクのレビュー依頼
    case reviewRequest(task: Int)
    /// 定期起動（最後の回の段階は起動の行と会話の記録から決まるので、それらを書いたときも流す）
    case schedule(Int64)
    /// 起こす予定
    case wake(Int64)
    /// 見張り（取った時刻・前の様子は取るたびに変わるので流さない）
    case watch(Int64)
    /// タスクの概況（部品・ターン数・送る文面の承認）
    case panel(task: Int)
    /// 起動の段階（request ID）
    case settings
    /// タスクに結び直した会話。記録の様子は `ConversationService` が配る（`StatePublisher.onConversation`）
    case conversation(String)
}

/// 書き込みが流した `StoreChange` の、まだ配っていないものと通し番号。受け手は 1 つで、起きたら全部をまとめて取る（同じものは 1 回にまとまる）
final class StoreChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [StoreChange] = []
    private var pendingSet: Set<StoreChange> = []
    private var sequence = 0
    /// 受け手を起こす。新しい 1 つだけを残す（起きたら全部を取るので、溜めなくてよい）
    let wakes: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation

    init() {
        (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// commit の後に呼ぶ（rollback した書き込みは流さない）
    func record(_ changes: [StoreChange]) {
        guard !changes.isEmpty else { return }
        lock.withLock {
            for change in changes where pendingSet.insert(change).inserted { pending.append(change) }
            sequence += 1
        }
        wake.yield()
    }

    /// 今までに流した数。`StatePublisher.settled` がここまで配り終えるのを待つ
    var recorded: Int { lock.withLock { sequence } }

    /// まだ配っていないもの（流した順）と、そこまでの通し番号
    func take() -> (changes: [StoreChange], through: Int) {
        lock.withLock {
            defer {
                pending = []
                pendingSet = []
            }
            return (pending, sequence)
        }
    }
}
