import SwiftUI
import TaskboardKit

/// 開いたタスクを、設定した開き方（サイドビュー・全面・中央モーダル）で中身の上に出す。
/// サイドビューを並べる幅が無いとき（iPad の縦など）は全面で出す
struct TaskPresentationHost<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: Content

    @AppStorage(AppPreferences.taskPanelWidthKey) private var panelWidth: Double = Self.defaultPanelWidth
    @State private var available: CGFloat = 0
    /// 窓の中の大きさ（中央モーダルの枠を決める）
    @State private var containerSize: CGSize = .zero
    @State private var dragStart: Double?

    /// サイドビューを開いても、ボードにこれだけは残す
    private static var minBoardWidth: CGFloat { 320 }
    /// サイドビューの最小の幅（詳細とセッションを上下に重ねた形が入る）
    private static var minPanelWidth: CGFloat { 420 }
    private static var defaultPanelWidth: Double { 640 }
    /// 中央モーダルの最大の大きさ
    private static var modalSize: CGSize { CGSize(width: 1680, height: 1120) }

    var body: some View {
        let key = model.selectedTask
        let mode = effectiveMode
        let covered = key != nil && mode == .full
        // ZStack で重ねると、上のパネルの中身が変わるたびに ZStack が自分の大きさを決め直し、後ろのボードを全部測り直した（モーダルでカーソルを動かすたびに）。
        // 重ねる面はどれも窓いっぱいなので、子に大きさを聞かない入れ物で重ねる
        FillContainer {
            HStack(spacing: 0) {
                // 全面で開いている間も中身は外さずに下に残す（外すと、閉じるたびにボードを作り直して 270 ms かかった）
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    // ボードの中はアニメーションさせない。させると、毎フレームで全カードの寸法を計り直す（パネルの開閉が 18 フレーム引っかかった）
                    .transaction { $0.animation = nil }
                    .allowsHitTesting(!covered)
                    .accessibilityHidden(covered)
                if let key, mode == .side {
                    resizeHandle
                    TaskPanel(key: key)
                        .frame(width: sideWidth)
                }
            }
            // 上のバーの題は下に残した中身の画面のもの（案件・受信箱など）のまま。タスクの題はパネルの見出しに出す
            if let key, mode == .full {
                TaskPanel(key: key)
            }
            if let key, mode == .modal {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { model.closeTask() }
                    .accessibilityLabel("閉じる")
                    .accessibilityAddTraits(.isButton)
                // 枠の大きさは窓の大きさから決めて固定する（中身から決めると、生成中の文や入力で中身が伸びるたびに枠ごと測り直す）
                let modal = modalFrame
                TaskPanel(key: key)
                    .frame(width: modal.width, height: modal.height)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .shadow(radius: 24, y: 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            available = $0.width
            containerSize = $0
        }
    }

    /// 中央モーダルの枠。窓から周りの余白を除いた大きさで、`modalSize` を超えない
    private var modalFrame: CGSize {
        CGSize(
            width: max(min(Self.modalSize.width, containerSize.width - Space.section * 2), 0),
            height: max(min(Self.modalSize.height, containerSize.height - Space.section * 2), 0))
    }

    /// サイドビューを並べる幅が無ければ全面
    private var effectiveMode: TaskPresentation {
        let mode = model.taskPresentation
        guard mode == .side, available > 0, available < Self.minBoardWidth + Self.minPanelWidth else { return mode }
        return .full
    }

    /// 文書を開いている間は、本文の最小の幅（`DocumentMetrics.bodyMinWidth`）まで広げる（ボードの残りの幅の範囲で）
    private var sideWidth: CGFloat {
        let upper = max(Self.minPanelWidth, available - Self.minBoardWidth)
        let lower = showsDocument ? max(Self.minPanelWidth, DocumentMetrics.bodyMinWidth) : Self.minPanelWidth
        return min(max(CGFloat(panelWidth), lower), upper)
    }

    private var showsDocument: Bool {
        guard let key = model.selectedTask, let doc = model.openDoc.flatMap({ model.fleet.document(for: $0) }) else { return false }
        return doc.machine == key.machine && doc.taskNumber == key.number
    }

    /// パネルの左端。ドラッグで幅を変え、ダブルクリックで既定の幅に戻す
    private var resizeHandle: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(.columnResize)
            #endif
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? Double(sideWidth)
                        dragStart = start
                        let upper = Double(max(Self.minPanelWidth, available - Self.minBoardWidth))
                        panelWidth = min(max(start - Double(value.translation.width), Double(Self.minPanelWidth)), upper)
                    }
                    .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { panelWidth = Self.defaultPanelWidth }
            .accessibilityLabel("タスクの幅")
            .accessibilityValue("\(Int(sideWidth))ポイント")
            .accessibilityAdjustableAction { direction in
                let step = 40.0
                let upper = Double(max(Self.minPanelWidth, available - Self.minBoardWidth))
                switch direction {
                case .increment: panelWidth = min(Double(sideWidth) + step, upper)
                case .decrement: panelWidth = max(Double(sideWidth) - step, Double(Self.minPanelWidth))
                @unknown default: break
                }
            }
    }
}
