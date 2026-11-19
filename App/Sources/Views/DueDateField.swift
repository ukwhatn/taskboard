import SwiftUI

/// 期日の選択。よく使う日は横並びから 1 回で選び、ほかの日は「日付を指定」で日付の欄を出す。
/// 前はオンとオフの切り替えと年月日の欄の 2 段で、日付を入れるまでに手数がかかった。
/// 期日が同じなら描き直さない（Form の行を 2 つ出すので `Redraw` で包めない。包むと 1 行として扱われる）
struct DueDateField: View, Equatable {
    @Binding var due: Date?
    @Environment(\.today) private var today
    /// 今日・明日と同じ日を「日付を指定」で選んだときも、日付の欄を出したままにする
    @State private var choosingDate = false
    @State private var calendarShown = false
    private let shown: Date?

    init(due: Binding<Date?>) {
        _due = due
        shown = due.wrappedValue
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.shown == b.shown }

    enum Choice: Hashable {
        case none, today, tomorrow, date
    }

    var body: some View {
        LabeledSegmentedPicker("期日", selection: Binding(get: { choice }, set: select)) {
            Text("なし").tag(Choice.none)
            Text("今日").tag(Choice.today)
            Text("明日").tag(Choice.tomorrow)
            Text("日付を指定").tag(Choice.date)
        }
        if choice == .date {
            let date = Binding(get: { due ?? day(0) }, set: { due = $0 })
            #if os(macOS)
            // Mac の compact は年月日の欄と上下の矢印で、曜日も出ない。押すとカレンダーを出すボタンにする
            LabeledContent("日付") {
                Button(date.wrappedValue.formatted(.dateTime.month().day().weekday())) { calendarShown = true }
                    .popover(isPresented: $calendarShown, arrowEdge: .bottom) {
                        DatePicker("日付", selection: date, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(Space.card)
                    }
            }
            #else
            DatePicker("日付", selection: date, displayedComponents: .date)
                .datePickerStyle(.compact)
            #endif
        }
    }

    private var calendar: Calendar { .current }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today)) ?? today
    }

    private var choice: Choice {
        guard let due else { return choosingDate ? .date : .none }
        if choosingDate { return .date }
        if calendar.isDate(due, inSameDayAs: day(0)) { return .today }
        if calendar.isDate(due, inSameDayAs: day(1)) { return .tomorrow }
        return .date
    }

    private func select(_ choice: Choice) {
        choosingDate = choice == .date
        switch choice {
        case .none: due = nil
        case .today: due = day(0)
        case .tomorrow: due = day(1)
        case .date: if due == nil { due = day(0) }
        }
    }
}
