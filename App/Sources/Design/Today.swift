import SwiftUI

extension EnvironmentValues {
    /// 期日・最後の動きの日数計算に使う「今日」。snapshot test が固定するために環境値にしている。
    @Entry var today: Date = Date()
}
