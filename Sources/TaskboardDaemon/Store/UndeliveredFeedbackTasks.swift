import Foundation
import GRDB

/// 未受領の回答・レビューがあるタスクの番号の控え。state のイベントのたびに走る「届けるものがあるか」の判定（`FeedbackService`）を DB に行かせない。
/// `ask`・`review`・`workItem`（済ませた手作業）への書き込みが commit されたら捨て、次に要るときに読み直す。読んでいる間に commit されたら、読んだ値は控えない
final class UndeliveredFeedbackTasks: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var numbers: Set<Int>?
    private var generation = 0
    private var changed = false

    func numbers(reading load: () throws -> Set<Int>) rethrows -> Set<Int> {
        let start: Int
        lock.lock()
        if let numbers {
            lock.unlock()
            return numbers
        }
        start = generation
        lock.unlock()
        let loaded = try load()
        lock.withLock { if generation == start { numbers = loaded } }
        return loaded
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        ["ask", "review", "workItem", "panelAnswer"].contains(eventKind.tableName)
    }

    func databaseDidChange(with event: DatabaseEvent) {
        lock.withLock { changed = true }
        stopObservingDatabaseChangesUntilNextTransaction()
    }

    // commit より前に捨てると、その間に読み始めた側が commit 前の値を控えてしまう
    func databaseDidCommit(_ db: Database) {
        lock.withLock {
            if changed {
                numbers = nil
                generation += 1
            }
            changed = false
        }
    }

    func databaseDidRollback(_ db: Database) {
        lock.withLock { changed = false }
    }
}
