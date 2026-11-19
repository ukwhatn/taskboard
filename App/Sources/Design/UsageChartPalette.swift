import SwiftUI

/// 利用状況のグラフの系列の色。決まった順に割り当て、使い回さない。
/// ライトはウィンドウの地 #ECECEC、ダークは #1E1E1E で、色覚の型ごとの隣どうしの差と明度の帯を確かめた値。
/// ライトは地との差が小さい色があるので、グラフには凡例か表を必ず添える
enum UsageChartPalette {
    static let series: [Color] = [
        Color(light: 0x2A78D6, dark: 0x3987E5),
        Color(light: 0xEB6834, dark: 0xD95926),
        Color(light: 0x1BAF7A, dark: 0x199E70),
        Color(light: 0xEDA100, dark: 0xC98500),
    ]

    /// 先頭から `count` 色。色の数を超えた系列は最後の色を使う（Mac が 5 台より多いとき。凡例で見分ける）
    static func colors(_ count: Int) -> [Color] {
        (0..<count).map { series[min($0, series.count - 1)] }
    }
}
