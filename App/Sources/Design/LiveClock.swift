import SwiftUI

/// 「今」を渡して中身を描き、時間の経過で描き直す（相対時刻・残り時間・「N分前の値」）。
/// `RelativeTime` が 1 つの文字列を描くのに対し、こちらは複数の値を同じ「今」で組むとき（利用枠の表、`badge` の中の文字）に使う。
/// snapshot test が `liveClock` を切っていれば `today` で 1 回だけ描く
struct LiveClock<Content: View>: View {
    var every: TimeInterval = 30
    @ViewBuilder let content: (Date) -> Content
    @Environment(\.today) private var today
    @Environment(\.liveClock) private var live

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: every)) { context in
                content(context.date)
            }
        } else {
            content(today)
        }
    }
}
