import SwiftUI

/// チャットの右に並べるファイルの欄の寸法。チャットと並べて入らない幅（`sideBySide` が偽）ではシートで出す
enum ChatFileMetrics {
    /// 欄の幅。diff の行が 60 桁ほど入る
    static let pane: ClosedRange<CGFloat> = 360...620
    /// 欄に取る割合
    static let paneShare: CGFloat = 0.45
    /// 欄の隣のチャットに要る幅（入力欄と札が 1 行に入る）
    static let chatMinWidth: CGFloat = 420
    /// 欄の上のファイルの一覧の高さの上限（それより多ければ一覧の中で送る）
    static let listMaxHeight: CGFloat = 168

    static func sideBySide(width: CGFloat) -> Bool { width >= pane.lowerBound + chatMinWidth }

    static func paneWidth(in width: CGFloat) -> CGFloat {
        min(max(width * paneShare, pane.lowerBound), pane.upperBound)
    }
}

extension ChatFileMetrics {
    /// Mac でシートに出すときの最小の大きさ（diff の行と、上の一覧が 4 行ほど入る）
    static let sheet = CGSize(width: 560, height: 520)
    /// シートの普段の大きさ。読む幅（`ReadableWidth.text`）に合わせ、高さは中身に合わせて画面いっぱいまで伸ばさない
    static let sheetIdeal = CGSize(width: ReadableWidth.text, height: 720)
    /// シートを広げられる上限
    static let sheetMax = CGSize(width: 1_100, height: 1_000)
}

/// チャットでファイルを開いているか。親（タスクのパネル）が読んで、詳細を畳んで欄の場所を空ける
struct ChatFileOpenKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
