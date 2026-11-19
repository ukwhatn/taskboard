import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話 ID から引くタスク")
struct SessionActivityTests {
    private let machine = MachineID(rawValue: "m")

    @Test("会話 ID から引くタスクは、その ID を最後に結んだもの（daemon の Store と同じ、紐づけの記録の id の大きい方）")
    func taskLinkedToSession() {
        let t0 = Date(timeIntervalSince1970: 0)
        func task(_ number: Int, _ refs: [(Int64, String)]) -> BoardTask {
            BoardTask(
                machine: machine, number: number, boardID: "b", columnID: "working", title: "t\(number)",
                sessions: refs.map { TaskSessionRef(id: $0.0, agent: "claude", sessionID: $0.1, cwd: "/tmp", linkedAt: t0) }, createdAt: t0, updatedAt: t0)
        }
        let tasks = [task(1, [(5, "s1"), (2, "s2")]), task(2, [(9, "s1")]), task(3, [(7, "s3")])]
        #expect(tasks.task(linkedToSession: "s1")?.number == 2)
        #expect(Array(tasks.reversed()).task(linkedToSession: "s1")?.number == 2)
        #expect(tasks.task(linkedToSession: "s2")?.number == 1)
        #expect(tasks.task(linkedToSession: "nope") == nil)
    }
}
