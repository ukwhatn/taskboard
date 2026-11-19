import CoreGraphics

/// チャットの寸法。Claude Desktop の Code の画面（compact の密度）の値に合わせる。余白の段は `Space`、角丸は `Radius`
enum ChatMetrics {
    /// 人の発言の吹き出しの内側（左右・上下）と、幅の上限（列の幅の割合と pt の小さい方）
    static let bubblePadding = CGSize(width: 12, height: 8)
    static let bubbleShare: CGFloat = 0.85
    static let bubbleMaxWidth: CGFloat = 472
    /// アシスタントの本文を吹き出しの無い分だけ下げる量
    static let assistantInset: CGFloat = 4
    /// コードの塊の内側と、短いコードでも取る幅（［実行］［コピー］が文に重ならない）
    static let codePadding = CGSize(width: 12, height: 8)
    static let codeMinWidth: CGFloat = 318
    /// 開いたツールの行の中身の内側
    static let toolBodyPadding = CGSize(width: 10, height: 8)
    /// 発言の操作の帯の高さ。ホバーしていなくても取っておく（出し入れで下の行が動かない）
    static let actionBar: CGFloat = 24
    /// 帯のうち、次の行との間（`ChatFonts.itemGap`）に入れる分
    static let actionBarOverlap: CGFloat = 8
    /// 入力欄の上の待機中の発言のカードの見出しの高さ
    static let queueHeader: CGFloat = 40
    /// 入力欄の 1 行のときの高さ
    static let composerMinHeight: CGFloat = 44
    /// 入力欄の上に並べる、貼った画像の小さな見本
    static let thumbnail: CGFloat = 56
}
