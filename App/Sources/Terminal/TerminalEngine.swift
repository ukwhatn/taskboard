import Foundation
import SwiftUI

/// 端末エミュレータの差し替え口。daemon から届いたバイト列を描き、キー入力とサイズ変更を返す。
/// 第 1 実装は libghostty（`GhosttyTerminalEngine`）。
@MainActor
protocol TerminalEngine: AnyObject {
    /// 利用者の入力（エミュレータがエンコードしたバイト列）。
    var onInput: ((Data) -> Void)? { get set }
    /// 描画領域から決まった格子のサイズ。
    var onResize: ((_ cols: Int, _ rows: Int) -> Void)? { get set }
    /// `cellSize` が変わった（初回の描画・拡縮）
    var onCellSizeChange: (() -> Void)? { get set }
    /// 今の格子。まだ描画されていなければ nil。
    var gridSize: (cols: Int, rows: Int)? { get }
    /// 1 セルの大きさ（pt）と、格子の外側の余白（pt、片側）。まだ描画されていなければ nil
    var cellSize: CGSize? { get }
    var padding: CGSize { get }

    func feed(_ data: Data)
    /// 画面に見えている文字（確認用）。
    func viewportText() -> String?
    /// 確認用。利用者の貼り付けと同じ経路で文字を入れる（bracketed paste の扱いもエミュレータに任せる）
    func paste(_ text: String)
    func requestFocus()
    /// 端末からフォーカスを外す（ボードへ戻る）
    func resignFocus()
    func setFontSize(_ points: Double)
    /// 画面から外すときに呼ぶ
    func invalidate()
    func makeView() -> AnyView
}
