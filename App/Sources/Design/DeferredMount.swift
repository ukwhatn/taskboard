import SwiftUI

/// 中身を、画面が出た回の後の runloop で組む。重い画面を 1 回で組むと主スレッドが 100 ms を超えて止まるので、部品ごとに回を分ける。
/// 待っている部品は `MountQueue` に並び、1 回に 1 つずつ組まれる（間に入力と描画が入る）。`lane` が `.first` の部品は `.later` より先に組む
struct DeferredMount<Content: View>: View {
    var lane = MountQueue.Lane.first
    @Environment(\.defersMount) private var defers
    @ViewBuilder let content: () -> Content
    @State private var shown = false

    var body: some View {
        if shown || !defers {
            content()
        } else {
            // 大きさ 0 にする（伸びる置き場は、縦に並べた隣の欄と高さを分け合い、組むまでの間その欄を縮める）
            Color.clear.frame(width: 0, height: 0).onAppear {
                MountQueue.enqueue(lane) { shown = true }
            }
        }
    }
}

@MainActor
enum MountQueue {
    enum Lane { case first, later }

    private static var first: [() -> Void] = []
    private static var later: [() -> Void] = []
    private static var idle: [() -> Void] = []
    private static var pumping = false

    static func enqueue(_ lane: Lane, _ reveal: @escaping () -> Void) {
        switch lane {
        case .first: first.append(reveal)
        case .later: later.append(reveal)
        }
        start()
    }

    /// 並んでいる部品を全部組み、描き終えた次の回に `action` を呼ぶ。同じ描画で現れた部品も数えるよう、次の回から見る
    static func afterQueued(_ action: @escaping () -> Void) {
        idle.append(action)
        start()
    }

    private static func start() {
        guard !pumping else { return }
        pumping = true
        DispatchQueue.main.async(execute: pump)
    }

    /// 1 つ組んだら次の回に回す（同じ回に続けて組むと、分けた意味が無くなる）
    private static func pump() {
        if !first.isEmpty {
            first.removeFirst()()
        } else if !later.isEmpty {
            later.removeFirst()()
        } else {
            let actions = idle
            idle = []
            actions.forEach { $0() }
        }
        if first.isEmpty, later.isEmpty, idle.isEmpty {
            pumping = false
        } else {
            DispatchQueue.main.async(execute: pump)
        }
    }
}
