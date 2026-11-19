import CoreGraphics

/// Markdown の本文（チャット・PR・文書の `MarkdownView`）の間隔と角丸。画面の余白（`Space`）より詰めた値で、今の見た目のまま置く
enum MarkdownMetrics {
    /// ブロックの間（PR・文書。チャットは `ChatFonts.itemGap`）。チャットの生成中の書き終えた段落と書きかけの段落の間も、
    /// 塊の中と同じ値にする（生成が終わって発言の行に替わったときにずれない）
    static let blockSpacing: CGFloat = 8
    /// ブロックより詰める所: 見出しの上、区切り線の上下、リストの項目どうしと印の後ろ、コードの塊と出力の間、表の行どうし、塊の上の［実行］の余白
    static let tightSpacing: CGFloat = 4
    /// 引用の線と本文の間
    static let quoteSpacing: CGFloat = 8
    /// コードの塊と表の内側
    static let boxPadding: CGFloat = 8
    static let boxRadius: CGFloat = 6
    /// 表の列どうし
    static let tableColumnSpacing: CGFloat = 12
    /// 表のセルの幅の上限。長いセルはここで折り返し、列は表の中で横に送る
    static let tableCellMaxWidth: CGFloat = 320
    /// チャットの表のセル（セルごとに地を敷き、線を引かない）: セルどうし、セルの内側、角丸
    static let tableCellSpacing: CGFloat = 2
    static let tableCellPadding: CGFloat = 6
    static let tableCellRadius: CGFloat = 3
    /// チャットの行内のコードの地の、字からのはみ出し（左右・上下）。角丸は `Radius.chip`
    static let inlineCodeInset = CGSize(width: 2, height: 1)
    /// リストの印の幅（記号と番号）。項目の頭を揃える
    static let bulletWidth: CGFloat = 12
    static let numberWidth: CGFloat = 20
}
