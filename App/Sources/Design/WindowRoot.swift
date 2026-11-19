import SwiftUI
import TaskboardKit

/// 窓の印。窓の根（`WindowRoot`）が窓ごとに 1 つ作り、環境の `\.window` で配る。失敗と確認はこの印ごとに持つ
struct WindowID: Hashable, Sendable {
    private let raw = UUID()
    /// 窓の根を通らない呼び出し（テスト・最初の窓が前に出る前）の出し先
    static let unattached = WindowID()
}

extension EnvironmentValues {
    @Entry var window = WindowID.unattached
}

/// 確認のダイアログで確かめている操作。対象の ID だけを持ち、出す前と実行する前に今もあるかを照らす（`AppModel.ask`・`confirm`）
enum Confirmation: Hashable {
    case restartOrchestrator(MachineID)
    case endTaskSessions(TaskKey)
}

/// 窓の根。モデルと保存先を配り、窓の印を作り、開いたときと前に出たときに `AppModel.activeWindow` にする。確認のダイアログはここに置き、出した窓に出す。
/// 窓を閉じたら、その窓の失敗と確認を捨てる
struct WindowRoot: ViewModifier {
    let model: AppModel
    @State private var id = WindowID()
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .modifier(TaskEndAllDialog())
            .modifier(OrchestratorRestartDialog())
            .environment(\.window, id)
            .environment(model)
            .defaultAppStorage(AppDefaults.store)
            .externalLinks()
            .preferredColorScheme(model.appearanceOverride)
            .onAppear { model.activate(id) }
            .onChange(of: appearsActive) { _, active in
                if active { model.activate(id) }
            }
            .onDisappear { model.closeWindow(id) }
    }
}
