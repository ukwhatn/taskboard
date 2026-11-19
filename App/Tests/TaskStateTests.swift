import AppKit
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

@MainActor @Suite struct TaskStateTests {
    private static let a = TaskKey(machine: MachineID(rawValue: "m"), number: 1)
    private static let b = TaskKey(machine: MachineID(rawValue: "m"), number: 2)

    @MainActor private final class Box {
        var text: Binding<String>?
    }

    private struct Probe: View {
        @TaskState var text = "初め"
        let box: Box

        var body: some View {
            box.text = $text
            return Text(text)
        }
    }

    /// 出すタスクを替えられる根。rootView の型を変えずに taskScope だけを替える
    private struct Scoped: View {
        let scope: TaskKey?
        let box: Box

        var body: some View {
            Probe(box: box).environment(\.taskScope, scope)
        }
    }

    private func host(_ scope: TaskKey?, box: Box) -> NSHostingView<Scoped> {
        let hosting = NSHostingView(rootView: Scoped(scope: scope, box: box))
        hosting.frame = CGRect(x: 0, y: 0, width: 200, height: 50)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func show(_ scope: TaskKey?, in hosting: NSHostingView<Scoped>, box: Box) {
        hosting.rootView = Scoped(scope: scope, box: box)
        hosting.layoutSubtreeIfNeeded()
    }

    @Test("同じタスクを出している間は、書いた値を持つ")
    func keepsWithinTask() {
        let box = Box()
        let hosting = host(Self.a, box: box)
        box.text?.wrappedValue = "下書き"
        hosting.layoutSubtreeIfNeeded()
        #expect(box.text?.wrappedValue == "下書き")
    }

    @Test("別のタスクに替わると初期値に戻り、戻ってきても前の値は出さない")
    func resetsOnTaskChange() {
        let box = Box()
        let hosting = host(Self.a, box: box)
        box.text?.wrappedValue = "A の下書き"
        show(Self.b, in: hosting, box: box)
        #expect(box.text?.wrappedValue == "初め")
        box.text?.wrappedValue = "B の下書き"
        show(Self.a, in: hosting, box: box)
        #expect(box.text?.wrappedValue == "初め")
    }

    @Test("タスクを渡されていなければ、普通の @State と同じく持ち続ける")
    func keepsWithoutScope() {
        let box = Box()
        let hosting = host(nil, box: box)
        box.text?.wrappedValue = "下書き"
        show(nil, in: hosting, box: box)
        #expect(box.text?.wrappedValue == "下書き")
    }
}
