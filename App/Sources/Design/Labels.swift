import SwiftUI
import TaskboardKit

// MARK: - 補足の並び

/// 「・」で区切った補足の並び。入らなければ次の行へ送る。「・」は行頭に来ないよう、前の項目の後ろに付ける（行頭禁則）。
/// `date` を渡すと、最後に「3分前」を足す（時間の経過で描き直す）
struct MetaLine: View {
    let items: [String]
    var date: Date?

    var body: some View {
        FlowRow(spacing: 0, lineSpacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                // 区切りの「・」は読み上げに入れない（行をまとめて読むと「応答待ち・、Mac Studio」になった）
                Text(index < items.count - 1 || date != nil ? item + "・" : item).lineLimit(1)
                    .accessibilityLabel(item)
            }
            if let date {
                RelativeTime(date: date).lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - 時刻

/// 「3分前」。30 秒ごとに描き直す
struct RelativeTime: View {
    let date: Date
    @Environment(\.today) private var today
    @Environment(\.liveClock) private var live

    var body: some View {
        if live {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.text(date, now: context.date))
            }
        } else {
            Text(Self.text(date, now: today))
        }
    }

    static func text(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "今"
        case ..<3600: return "\(Int(seconds / 60))分前"
        case ..<86400: return "\(Int(seconds / 3600))時間前"
        default: return "\(Int(seconds / 86400))日前"
        }
    }
}

// MARK: - マシンの名前

/// マシンの名前。接続先に付けた名前を引く（同じ Mac は「このMac」）。daemon のコンピュータ名は出さない
struct MachineName: View {
    @Environment(AppModel.self) private var model
    let machine: MachineID

    var body: some View {
        Text(model.machineName(machine))
    }
}
