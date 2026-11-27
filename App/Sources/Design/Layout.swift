import SwiftUI
import TaskboardKit

// 画面の作りの部品（docs/ui-system.md）。余白、幅、揃え、折り返しはここで決め、画面のコードは部品を組むだけにする

/// 余白の役割。数値を画面のコードに書かず、ここから選ぶ
enum Space {
    /// アイコンと文字、チップどうし
    static let inline: CGFloat = 6
    /// 行の中の要素、詰めた行どうし、列の中のカードどうし
    static let row: CGFloat = 8
    /// 見出しと中身、塊どうし、ボードの列どうし
    static let block: CGFloat = 12
    /// 節どうし
    static let section: CGFloat = 24
    /// カードと帯の内側
    static let card: CGFloat = 12
}

/// 角丸
enum Radius {
    /// 行内のコード
    static let chip: CGFloat = 4
    static let control: CGFloat = 6
    /// チャットのコードの塊・開いたツールの行・ホバーの帯
    static let box: CGFloat = 8
    /// カード・吹き出し
    static let card: CGFloat = 10
    /// チャットの入力欄
    static let composer: CGFloat = 12
}

/// 読む画面の最大幅（1 行 35〜45 文字）
enum ReadableWidth {
    /// 文書、PR の本文
    static let text: CGFloat = 760
    /// チャットの会話と入力欄（Claude Desktop の既定と同じ）。コードの塊とツールの出力は、列の中で横に送る
    static let chat: CGFloat = 768
    /// 設定と入力
    static let form: CGFloat = 640
}

/// ボードの寸法
enum BoardMetrics {
    /// 列の幅。カードの題が 3 行に収まり、14 インチの画面に 5 列が並ぶ
    static let columnWidth: CGFloat = 260
    /// 畳んだ列の帯の幅。列の名前が長ければ省略する
    static let foldedWidth: CGFloat = 120
    /// 全体のボードで 1 列に出すカードの数。残りは「さらにN件」で開く（1 列が長いと下の案件が遠くなる）
    static let cardLimit = 8
}

/// タスクのパネルの寸法
/// ホームの会話の形（`ConversationBoard`）
enum ConversationBoardMetrics {
    /// 横に並べる会話の最小の幅（列のカードと同じ）
    static let tileMinWidth: CGFloat = BoardMetrics.columnWidth
    /// 並べ方（`ConversationBoardLayout`）を決めるときの高さの見積もり（段の間を含む）。snapshot で測った高い方の札（対応待ちは選択肢 2 つの質問と
    /// 書き込めない接続先の文、実行中は最後の応答の 2 行と下の段）に段の間を足した値。小さく見積もると札が窓からはみ出す
    static let waitingTileHeight: Double = 200
    static let runningTileHeight: Double = 140
    /// 1 行で出す会話の高さ（行の間を含む）
    static let lineHeight: Double = 28
    /// 実行中を案件で分けたとき、案件ごとに出す新しい会話の数
    static let perBoard = 2
    /// 計画の承認待ちで、頭に出す計画の行の数
    static let planLines = 3
    /// Space で広げたときに出す発言の数と、そのために取得する発言の数（ツールの行を除いて残す）
    static let expandedMessages = 6
    static let expandedFetch = 30
    /// 広げた中身の高さの上限
    static let expandedMaxHeight: CGFloat = 320
}

/// 質問の選択肢の見本（`AskForm`）
enum AskFormMetrics {
    /// 見本の箱の高さの上限（HTML は WKWebView なので、この高さで固定する）
    static let previewHeight: CGFloat = 280
    /// この幅以上なら、見本を選択肢の横に置く
    static let sideBySideWidth: CGFloat = 640
}

enum TaskPanelMetrics {
    /// 右側（`TaskSideArea`）の既定の幅。メモと作業項目の題が 1 行に 20 文字ほど入る。境目を動かすと、この下限から中央のセッションの最小の幅までの間で変えられる
    static let details: ClosedRange<CGFloat> = 320...440
    /// 右の欄に取る割合
    static let detailsShare: CGFloat = 0.36
    /// 中央のセッションに要る幅（端末で 60 桁ほど）。右の欄と並べて入らなければ上下に重ねる
    static let sessionMinWidth: CGFloat = 480
    /// 上下に重ねたとき、右の欄に取る高さの上限の割合（残りはセッション）
    static let stackedDetailsShare: CGFloat = 0.4

    /// セッションと右の欄を左右に並べられるか
    static func sideBySide(width: CGFloat) -> Bool { width >= details.lowerBound + sessionMinWidth }

    /// 並べられないとき、右の欄を下に重ねずに会話と入れ替えるか。iPad は縦の画面で重ねると会話が 150pt ほどしか残らない。
    /// Mac は窓を広げれば並ぶので重ねたまま
    static var swapsWhenStacked: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// 右側の幅。`preferred` は境目を動かして残した幅（無ければ割合で決める）
    static func detailsWidth(in width: CGFloat, preferred: CGFloat? = nil) -> CGFloat {
        guard let preferred else { return min(max(width * detailsShare, details.lowerBound), details.upperBound) }
        return min(max(preferred, details.lowerBound), max(width - sessionMinWidth, details.lowerBound))
    }

    /// 右の欄を並べたままではチャットの隣にファイルの欄（`ChatFileMetrics`）が入らず、右の欄を畳めば入る幅か。
    /// そのときはファイルを開いている間だけ右の欄を畳み、シートに落とさない
    static func makesRoomForFile(width: CGFloat) -> Bool {
        sideBySide(width: width) && !ChatFileMetrics.sideBySide(width: width - detailsWidth(in: width)) && ChatFileMetrics.sideBySide(width: width)
    }

    /// 文書を開いたときの置き方。会話と文書にそれぞれ `sessionMinWidth` を取れれば並べる（右の欄を出したままで入らず、畳めば入るなら畳む）。
    /// `preferredDetails` は境目を動かして残した右の欄の幅
    static func docPlacement(width: CGFloat, sidePaneShown: Bool, preferredDetails: CGFloat? = nil) -> DocPlacement {
        let pair = sessionMinWidth * 2
        guard width >= pair else { return .alone }
        let fitsWithSidePane = sideBySide(width: width) && width - detailsWidth(in: width, preferred: preferredDetails) >= pair
        return .beside(foldsSidePane: sidePaneShown && !fitsWithSidePane)
    }
}

/// タスクのパネルで文書を開いたときの置き方（`TaskPanelMetrics.docPlacement`）
enum DocPlacement: Equatable {
    /// 会話の右に並べる。`foldsSidePane` なら、並べている間だけ右の欄を畳む
    case beside(foldsSidePane: Bool)
    /// 会話を隠して文書だけを出す
    case alone
}

/// 会話が登録した部品（`OverviewPanelParts`）の寸法
enum OverviewMetrics {
    /// 計器の札の最小の幅（並べる数は幅で決まる）
    static let gaugeMinWidth: CGFloat = 140
    /// 計器と計画のバーの太さ
    static let barHeight: CGFloat = 4
    /// グラフの高さ
    static let chartHeight: CGFloat = 160
    /// 自由の部品（HTML）の高さ。中身の高さに合わせ、この間に収める
    static let htmlHeight: ClosedRange<CGFloat> = 40...640
    /// 済んだ行の濃さ（計画の済んだ項目、表の done の行）
    static let doneOpacity: Double = 0.6
}

/// 画面のキーボードの寸法
enum KeyboardMetrics {
    /// これより高ければ画面のキーボードを出しているとみなす。外付けのキーボードの iPad は、候補とショートカットの帯（70pt ほど）だけが出る
    static let softKeyboardMinHeight: CGFloat = 150
}

/// タスクの見出しの寸法
enum TaskHeaderMetrics {
    /// チップの並びに出す、足すリンクの URL の欄の幅（GitHub の PR の URL が 1 行に入る）
    static let linkField: ClosedRange<CGFloat> = 280...520
    /// 完了したリンクをこの数までは畳まずに並べる（PR が 1 本だけの完了したタスクで、その PR まで隠さない）
    static let settledLinksShown = 3
}

/// タスク画面の右側の欄の格子（`TaskSideArea`）の寸法
enum SidePanelMetrics {
    /// 欄どうしの境目の線
    static let divider: CGFloat = 1
    /// 境目をつかめる幅
    static let handle: CGFloat = 8
    /// 欄の最小の高さ（頭と中身の 3 行ほど）
    static let minHeight: CGFloat = 120
    /// 2 列にするときの 1 列の最小の幅（右側の既定の下限と同じ）
    static let minColumnWidth: CGFloat = 300
}

/// 設定の［利用状況］のグラフ（`UsageDashboard`）
enum UsageChartMetrics {
    /// 時間を横に取るグラフの高さ
    static let height: CGFloat = 140
    /// 利用枠のグラフ（窓ごとに 1 つ並べるので低くする）
    static let windowHeight: CGFloat = 100
    /// スキルの横棒の 1 行の高さ
    static let barRow: CGFloat = 22
    /// 線の太さ（dataviz の目安の 2pt）と、散布の点の面積（一辺 8pt ほど）
    static let line: CGFloat = 2
    static let point: CGFloat = 64
    /// 自前で組んだ凡例の点の直径
    static let legendDot: CGFloat = 8
}

/// 作業項目の依存の線（`WorkItemGraphView`）の寸法
enum WorkItemGraphMetrics {
    /// 線の太さ
    static let line: CGFloat = 1.5
    /// 筋どうしの間。筋が多いと `gutterLimit` に収まるまで詰める
    static let laneSpacing: CGFloat = 6
    /// 項目にいちばん近い筋と、状態の印の間
    static let laneInset: CGFloat = 6
    /// 線の角の丸み
    static let corner: CGFloat = 4
    /// 線の先の矢じりの長さ
    static let arrow: CGFloat = 4
    /// 行の左に取る溝の幅の上限。題の幅を削りすぎないため
    static let gutterLimit: CGFloat = 40

    /// 筋の数に要る溝の幅。線が無ければ 0
    static func gutter(slots: Int) -> CGFloat {
        slots == 0 ? 0 : min(laneInset + CGFloat(slots) * laneSpacing, gutterLimit)
    }

    /// 筋どうしの間（溝に収まるよう詰めた値）
    static func spacing(slots: Int) -> CGFloat {
        slots <= 1 ? laneSpacing : min(laneSpacing, (gutter(slots: slots) - laneInset) / CGFloat(slots))
    }
}

/// 押せる範囲の最小の大きさ
enum HitTarget {
    #if os(iOS)
    static let size: CGFloat = 44
    #else
    static let size: CGFloat = 24
    #endif
}

/// macOS の窓の最小の大きさ。窓の根に `windowMinimum(_:)` で置く。
/// 置かないと最小の大きさが中身から決まり、主ウィンドウは 300×200 まで縮んだ。中身の最小の高さで窓が伸びるのは、
/// 根ではなく中身の側で止める（`TaskPanel` の根の `minHeight: 0`。NavigationSplitView が列の最小の高さを自分の最小にするため）
enum WindowMetrics {
    /// 主ウィンドウ。サイドバーと、上下に重ねたタスクのパネルが入る
    static let main = CGSize(width: 720, height: 480)
    /// タスクの別ウィンドウ。サイドビューの最小の幅と揃える
    static let task = CGSize(width: 420, height: 480)
    /// 文書の別ウィンドウ。本文の最小の幅
    static let document = CGSize(width: DocumentMetrics.bodyMinWidth, height: 480)
    /// 主ウィンドウの詳細の列（サイドバーの右）。サイドビューの最小の幅。高さは窓の最小に任せる
    static let detailColumn = CGSize(width: 420, height: 0)
    /// サイドバーの最小と、開いたときの幅。iPad は指で押す行が高く、字下げした題が「#…」だけになったので広く取る
    /// （iPad mini の縦 744pt でも詳細の列の最小が残る幅）
    #if os(iOS)
    static let sidebar: (min: CGFloat, ideal: CGFloat) = (280, 320)
    #else
    static let sidebar: (min: CGFloat, ideal: CGFloat) = (200, 260)
    #endif
    /// 設定の窓（⌘,）の最小と、開いたときの大きさ
    static let settings = CGSize(width: 760, height: 520)
    static let settingsIdeal = CGSize(width: 860, height: 640)
}

/// macOS のシートの大きさ。幅は `SheetScaffold` の `width` で渡し、ここには高さと、`SheetScaffold` に載せないシートの大きさを置く
enum SheetMetrics {
    /// 外観の選び方。一覧の面は中身の高さを小さく答えるので、選べる行数が出る最小の高さを取る
    static let themeMinHeight: CGFloat = 480
    /// 承認の確認の最小と、開いたときの大きさ
    static let approval = CGSize(width: 620, height: 520)
    static let approvalIdeal = CGSize(width: 720, height: 640)
    /// オーケストレーターへのメッセージの高さ
    static let orchestratorHeight: ClosedRange<CGFloat> = 300...620
    /// ショートカットの一覧の高さと、開いたときの高さ
    static let shortcutsHeight: ClosedRange<CGFloat> = 420...720
    static let shortcutsIdealHeight: CGFloat = 600
    /// コマンドパレット
    static let palette = CGSize(width: 640, height: 440)
}

extension EnvironmentValues {
    /// ページの左右の余白。Mac と iPad は 20、iPhone は 16（`PageInsetReader` が size class から決める）
    @Entry var pageInset: CGFloat = 20
    /// 時間の経過で描き直すか。snapshot test が「今」を `today` に固定するときに切る
    @Entry var liveClock = true
    /// 重い部品を後の回で組むか（`DeferredMount`）。snapshot test は 1 回で組んだ形を撮るので切る
    @Entry var defersMount = true
    /// チャットでファイルを開くと、親（タスクのパネル）が右の欄を畳んでチャットの隣に欄を出せるか。true の間はシートに落とさない（`TaskPanelMetrics.makesRoomForFile`）
    @Entry var chatFileRoom = false
}

/// size class からページの左右の余白を決めて、中に配る。画面の根に 1 回置く
struct PageInsetReader: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.pageInset, sizeClass == .compact ? 16 : 20)
        #else
        content.environment(\.pageInset, 20)
        #endif
    }
}

/// タスクの画面とタスクなしの画面の、セッションの欄と右の欄の並べ方。子は［セッションの欄、境目（`SplitDivider`）、右の欄］か、右の欄を隠したときは［セッションの欄］だけ。
/// 左右なら右の欄は `sideWidth`。上下なら右の欄は、残りの半分と `stackedMaxHeight` の低い方までで中身の高さ（VStack が伸びる 2 つの欄を分けるのと同じ）。セッションの欄は残り。
/// 自分の大きさは提案のままで、セッションの欄には決めた大きさを 1 回だけ渡す。HStack・VStack で並べると、伸び方を調べるためにセッションの欄を幅 0 や無限で何度も測り、
/// 入れ子の stack の数だけ掛け算で増えた（長い会話を中央に開いていると、入力欄と文の測り直しで主スレッドが数秒から 20 秒止まった）
/// `swap` を渡すと上下に重ねず入れ替える。右の欄は帯だけを下に置き、欄を出すときは全体に広げてセッションの欄を枠の下の外へ送る
/// （作り直さずに隠す。作り直すと会話の購読と端末の接続が張り直される）
struct SessionSplit: Layout {
    let sideBySide: Bool
    let sideWidth: CGFloat
    /// 上下のときの右の欄の高さの上限。nil なら残りの半分まで
    let stackedMaxHeight: CGFloat?
    var swap: SessionSwap?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let main = subviews.first else { return }
        guard subviews.count == 3 else {
            main.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let divider = subviews[1]
        let side = subviews[2]
        if sideBySide {
            let line = divider.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width
            let width = min(sideWidth, bounds.width)
            let mainWidth = max(bounds.width - width - line, 0)
            main.place(at: bounds.origin, proposal: ProposedViewSize(width: mainWidth, height: bounds.height))
            divider.place(at: CGPoint(x: bounds.minX + mainWidth, y: bounds.minY), proposal: ProposedViewSize(width: line, height: bounds.height))
            side.place(at: CGPoint(x: bounds.maxX - width, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
        } else if let swap {
            let line = divider.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            let bar = min(side.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height, bounds.height)
            let mainHeight = max(bounds.height - bar - line, 0)
            let mainY = swap == .details ? bounds.maxY : bounds.minY
            main.place(at: CGPoint(x: bounds.minX, y: mainY), proposal: ProposedViewSize(width: bounds.width, height: mainHeight))
            if swap == .details {
                divider.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), proposal: ProposedViewSize(width: bounds.width, height: line))
                side.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            } else {
                divider.place(at: CGPoint(x: bounds.minX, y: bounds.minY + mainHeight), proposal: ProposedViewSize(width: bounds.width, height: line))
                side.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - bar), proposal: ProposedViewSize(width: bounds.width, height: bar))
            }
        } else {
            let line = divider.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            let cap = min(max(bounds.height - line, 0) / 2, stackedMaxHeight ?? .infinity)
            let height = min(side.sizeThatFits(ProposedViewSize(width: bounds.width, height: cap)).height, cap)
            let mainHeight = max(bounds.height - height - line, 0)
            main.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: mainHeight))
            divider.place(at: CGPoint(x: bounds.minX, y: bounds.minY + mainHeight), proposal: ProposedViewSize(width: bounds.width, height: line))
            side.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - height), proposal: ProposedViewSize(width: bounds.width, height: height))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// `SessionSplit` で入れ替えるときに出している方。`conversation` は会話と下の帯、`details` は右の欄を全体に
enum SessionSwap: Equatable {
    case conversation, details
}

/// 同じ幅の 2 つの欄を境目を挟んで並べる（タスク画面で 2 つ並べたとき）。子は左の欄・境目・右の欄の順で、左の欄だけなら全体に置く。
/// HStack で並べると、揃えを聞くたびに両方の会話の欄の中身を奥まで辿り、並べたままスクロールする間に主スレッドが 100 ms を超えて止まっていた。
/// `parksLeading` なら右の欄を全体に広げ、左の欄は枠の下の外へ送る（作り直さずに隠す。並べられない幅で文書だけを出すとき）
struct EvenSplit: Layout {
    var parksLeading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let leading = subviews.first else { return }
        guard subviews.count == 3 else {
            leading.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        if parksLeading {
            leading.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), proposal: ProposedViewSize(bounds.size))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), proposal: ProposedViewSize(width: 0, height: bounds.height))
            subviews[2].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let line = subviews[1].sizeThatFits(ProposedViewSize(width: nil, height: bounds.height)).width
        let width = max((bounds.width - line) / 2, 0)
        leading.place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + width, y: bounds.minY), proposal: ProposedViewSize(width: line, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX - width, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// `SessionSplit` の境目。`Divider` は外側の stack の向きで縦横が決まるので、1 本だけの stack に入れて向きを決める
struct SplitDivider: View {
    let vertical: Bool

    var body: some View {
        if vertical {
            HStack(spacing: 0) { Divider() }
        } else {
            VStack(spacing: 0) { Divider() }
        }
    }
}

/// 置かれた枠いっぱいに広がり、中身に大きさを聞かない入れ物。2 方向にスクロールする面を入れる。
/// 面は大きさを聞かれると中身を全部測って答えるので、外側の stack が伸び縮みを調べるたびに全案件の帯を測り直していた（パネルの開閉で主スレッドの 2 割）
struct FillContainer: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    // 既定の実装は中身を置いて揃えの位置を探すので、外側の stack が揃えを聞くたびに中身を全部測っていた
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// 置かれた幅を自分の幅にし、高さは中身に合わせる入れ物。中身が置かれた幅に入らなくても、外へは広がらない。
/// 中身の形を自分の幅で選ぶ帯は、中身が押し広げた幅を測ると入ると判定し続け、親の stack ごと画面の外へ広げていた（iPhone の会話の上の帯）
struct FillWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(proposal)
        guard let width = proposal.width, width.isFinite else { return size }
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// 最小の大きさを決めた値で返し、中身には大きさを聞かない入れ物（窓の根と、NavigationSplitView の詳細の列の根）。大きさは提案と最小の大きいほうで、中身はその大きさで置く。
/// AppKit は窓と分割の列の最小の大きさを、制約を更新するたびに hosting view の中身から求める。`.frame(minWidth:)` や素の中身だと中身を全部測り直し、
/// 生成中の会話を開いている間、25 秒のうち 1.4 秒をそれに使っていた
struct MinimumFrame: Layout {
    let minimum: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? minimum.width, minimum.width), height: max(proposal.height ?? minimum.height, minimum.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// 中身の幅に縮み、上限より長い中身には上限の幅を渡して省略させる入れ物。
/// `.frame(maxWidth:)` は提案が上限より広いと上限まで広がるので、短い中身の後ろに空きができ、隣の欄を狭める
struct CappedWidth: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? limit, limit), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// 中身の高さに縮み、上限か提案より高い中身にはその低い方の高さを渡す入れ物。中身を縦の ScrollView にすると、収まらない分だけ送れる。
/// `.frame(maxHeight:)` だと ScrollView が上限まで伸び、短い中身の下に空きができる
struct CappedHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, limit, proposal.height ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

// MARK: - 文字の役割

/// 文字の役割。書体、色、行数、省略を決める。長さの変わる文字は、折り返すか省略するかのどちらか
enum TextRole {
    /// 画面の題。2 行まで折り返す
    case pageTitle
    /// 節の見出し。1 行で省略
    case sectionTitle
    /// カードや行の題。3 行まで折り返す
    case title
    /// 本文。折り返して全文を出す
    case body
    /// 補足の文。折り返して全文を出す
    case secondary
    /// 行の補足（時刻、件数、マシン）。1 行で省略
    case caption
    /// パスと識別子。1 行で中を省略
    case mono
}

private struct TextRoleModifier: ViewModifier {
    let role: TextRole

    func body(content: Content) -> some View {
        switch role {
        case .pageTitle:
            content.font(.title2.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case .sectionTitle:
            content.font(.headline).lineLimit(1).truncationMode(.tail)
        case .title:
            content.font(.body.weight(.semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        case .body:
            content.font(.body).fixedSize(horizontal: false, vertical: true)
        case .secondary:
            content.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .caption:
            content.font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        case .mono:
            content.font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

extension View {
    func textRole(_ role: TextRole) -> some View { modifier(TextRoleModifier(role: role)) }

    /// 押せる範囲を最小の大きさまで広げる（見た目は変えない）
    func hitTarget() -> some View {
        frame(minWidth: HitTarget.size, minHeight: HitTarget.size).contentShape(Rectangle())
    }

    /// 画面の根に置き、ページの左右の余白を配る
    func pageInsets() -> some View { modifier(PageInsetReader()) }

    /// 幅を中身に合わせ、上限を超える分は省略させる（`CappedWidth`）
    func cappedWidth(_ limit: CGFloat) -> some View { CappedWidth(limit: limit) { self } }

    /// 高さを中身に合わせ、上限か提案を超える分は中身に任せる（`CappedHeight`）
    func cappedHeight(_ limit: CGFloat) -> some View { CappedHeight(limit: limit) { self } }

    /// macOS の窓の根に置き、窓の最小の大きさを決める（`WindowMetrics`）。iOS では何もしない
    @ViewBuilder
    func windowMinimum(_ size: CGSize) -> some View {
        #if os(macOS)
        MinimumFrame(minimum: size) { self }
        #else
        self
        #endif
    }

    /// 左端だけで中身を切る（上・下・右は切らない）。macOS 26 のサイドバーは中身の上に浮き、スクロールの面がその下まで広がるので、
    /// 横に送った中身がサイドバーの下に透ける。上のバーの下に回る中身はそのままにする（`.clipped()` だと上も切れる）
    func clipLeadingEdge() -> some View { clipShape(LeadingEdgeClip()) }

    /// 横にスクロールする面の中で、左端（`pageInset` の内側）に留める（全体のボードのマシンと案件の見出し）。
    /// スクロールの位置を状態に持たず描くときに動かすので、送っても見出しの外は描き直さない。
    /// 幅は中身で決める（面の幅に合わせると、2 方向のスクロールの面の大きさと循環して、面が小さくずれて置かれた）
    func stickyLeading() -> some View { modifier(StickyLeading()) }

    /// 読める幅の列に入れて中央に置く（文書・PR・チャットの本文と、その上下の欄の左端を揃える）
    func readableColumn(_ width: CGFloat = ReadableWidth.text) -> some View {
        frame(maxWidth: width, alignment: .leading).frame(maxWidth: .infinity)
    }

    /// 選べる札（タスクの帯と上の札のセッション・会話）。選んでいる札は色の地と枠
    func pillStyle(selected: Bool) -> some View {
        font(.callout)
            .lineLimit(1)
            .padding(.horizontal, Space.block)
            .padding(.vertical, Space.inline)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1))
            .hitTarget()
    }

    /// 人の答えを待つカード（質問・権限・計画の承認）。橙の地と枠
    func attentionCard() -> some View {
        padding(Space.card)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    /// チップの形（Capsule の背景と内側の余白）
    func chipStyle(tint: Color = .secondary) -> some View {
        font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct LeadingEdgeClip: Shape {
    /// 上・下・右に十分に広く取る（ウィンドウより大きければよい）
    private static let reach: CGFloat = 100_000

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - Self.reach, width: rect.width + Self.reach, height: rect.height + Self.reach * 2))
    }
}

private struct StickyLeading: ViewModifier {
    @Environment(\.pageInset) private var inset

    func body(content: Content) -> some View {
        let inset = inset
        content.visualEffect { content, proxy in
            // 面の左端から `pageInset` の位置に留める。中身は横の余白を padding で持つ（OverviewBoard）
            content.offset(x: max(0, inset - proxy.frame(in: .scrollView(axis: .horizontal)).minX))
        }
    }
}
