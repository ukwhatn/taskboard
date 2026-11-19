import Foundation

/// タスクの開き方（Mac / iPad）。別ウィンドウはこれとは別に ⌘ クリックで開く
enum TaskPresentation: String, CaseIterable, Identifiable {
    case side, full, modal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .side: String(localized: "並べて表示")
        case .full: String(localized: "大きく表示")
        case .modal: String(localized: "中央に表示")
        }
    }
    var symbol: String {
        switch self {
        case .side: "rectangle.righthalf.inset.filled"
        case .full: "rectangle.inset.filled"
        case .modal: "rectangle.center.inset.filled"
        }
    }
}
