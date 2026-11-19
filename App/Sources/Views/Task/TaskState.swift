import SwiftUI
import TaskboardKit

extension EnvironmentValues {
    /// `TaskState` が値を結ぶタスク。タスクのパネルが中身に渡す
    @Entry var taskScope: TaskKey?
}

/// 出しているタスクが替わると初期値に戻る @State。タスクのパネルは別のタスクを開いても作り直さない（作り直すと中の部品を全部作り直し、
/// 切り替えが 40 ms ほど遅れた）ので、下書き・選択・確認の相手のように、そのタスクを出している間だけ持つ値はこれで持つ。
/// どのタスクかは環境の `taskScope` で決まり、渡されていなければ普通の @State と同じ
@propertyWrapper
struct TaskState<Value>: DynamicProperty {
    @Environment(\.taskScope) private var scope
    @State private var slot: Slot

    private struct Slot {
        let initial: Value
        var task: TaskKey?
        var value: Value

        subscript(scoped scope: TaskKey?) -> Value {
            get { task == scope ? value : initial }
            set {
                task = scope
                value = newValue
            }
        }
    }

    init(wrappedValue: Value) {
        _slot = State(initialValue: Slot(initial: wrappedValue, task: nil, value: wrappedValue))
    }

    var wrappedValue: Value {
        get { slot[scoped: scope] }
        nonmutating set { slot[scoped: scope] = newValue }
    }

    var projectedValue: Binding<Value> {
        $slot[dynamicMember: \Slot.[scoped: scope]]
    }
}
