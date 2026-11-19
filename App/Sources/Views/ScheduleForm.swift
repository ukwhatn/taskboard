import SwiftUI
import TaskboardKit

struct ScheduleForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.today) private var today
    @State var draft: ScheduleDraft
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        let adding = draft.existing == nil
        SheetScaffold(title: adding ? String(localized: "定期起動の追加") : String(localized: "定期起動の編集"), error: error, width: 560, onCancel: { dismiss() }) {
            Section {
                LabeledTextField(label: String(localized: "名前"), text: $draft.name)
                if adding {
                    MachinePicker(label: String(localized: "Mac"), selection: $draft.launch.machine, machines: model.writableMachines)
                } else {
                    LabeledContent("Mac") { MachineName(machine: draft.launch.machine) }
                }
            }
            Section {
                Picker("繰り返し", selection: $draft.repeatKind) {
                    ForEach(ScheduleDraft.Repeat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                repeatFields
                if let next = draft.rule.next(after: today, anchor: today) {
                    LabeledContent("次回") { Text(verbatim: ScheduleText.time(next, now: today)) }
                }
            } header: {
                Text("繰り返し")
            } footer: {
                if draft.repeatKind == .cron {
                    Text("「分 時 日 月 曜日」の順に、半角の空白で区切って入力してください。")
                } else if draft.repeatKind == .interval {
                    Text("\(ScheduleRule.minimumIntervalMinutes)分以上で入力してください。")
                }
            }
            LaunchFields(draft: $draft.launch, header: String(localized: "起動するセッション"), showsMachine: false)
            Section {
                Picker("紐づけるタスク", selection: $draft.destination) {
                    ForEach(ScheduleDraft.Destination.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                destinationFields
            } header: {
                Text("紐づけるタスク")
            } footer: {
                if draft.destination == .newTask {
                    Text(adding ? "定期起動の名前でタスクを1件追加します。各回のセッションはそのタスクに紐づきます。" : "保存すると、定期起動の名前でタスクを1件追加して紐づけ直します。")
                }
            }
            Section {
                LabeledSegmentedPicker(String(localized: "前回の実行が終わっていないとき"), selection: $draft.overlap) {
                    Text("スキップ").tag(ScheduleOverlap.skip)
                    Text("並行して起動").tag(ScheduleOverlap.parallel)
                }
            }
        } actions: {
            Button(adding ? "追加" : "保存") { save() }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
        }
        .commandReturn(enabled: !saving) { save() }
        .onAppear(perform: fillDefaults)
        .onChange(of: draft.launch.machine) { _, _ in fillDefaults() }
    }

    @ViewBuilder
    private var repeatFields: some View {
        switch draft.repeatKind {
        case .daily, .weekdays, .weekly:
            if draft.repeatKind == .weekly {
                LabeledContent("曜日") {
                    HStack(spacing: Space.inline) {
                        ForEach(ScheduleDraft.weekdayOrder, id: \.self) { day in
                            Toggle(isOn: weekdayBinding(day)) {
                                Text(Self.weekdayShort[day])
                            }
                            .toggleStyle(.button)
                            .accessibilityLabel(Self.weekdayLong[day])
                        }
                    }
                }
            }
            DatePicker("時刻", selection: timeBinding, displayedComponents: .hourAndMinute)
        case .interval:
            LabeledContent("間隔") {
                HStack(spacing: Space.row) {
                    TextField("間隔", value: $draft.intervalValue, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Picker("単位", selection: $draft.intervalUnit) {
                        ForEach(ScheduleDraft.IntervalUnit.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Text("おき")
                }
            }
        case .cron:
            LabeledTextField(label: String(localized: "cron式"), text: $draft.cron, monospaced: true)
        }
    }

    static let weekdayShort = [
        String(localized: "日"), String(localized: "月"), String(localized: "火"), String(localized: "水"),
        String(localized: "木"), String(localized: "金"), String(localized: "土"),
    ]
    static let weekdayLong = [
        String(localized: "日曜日"), String(localized: "月曜日"), String(localized: "火曜日"), String(localized: "水曜日"),
        String(localized: "木曜日"), String(localized: "金曜日"), String(localized: "土曜日"),
    ]

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { draft.weekdays.contains(day) },
            set: { on in if on { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } })
    }

    /// 時と分を時刻の入力に。日付の部分は使わない
    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: today) ?? today },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? draft.hour
                draft.minute = parts.minute ?? draft.minute
            })
    }

    @ViewBuilder
    private var destinationFields: some View {
        let state = model.fleet.machineState(for: draft.launch.machine)
        let boards = model.orderedBoards(on: draft.launch.machine)
        switch draft.destination {
        case .newTask:
            Picker("案件", selection: $draft.boardID) {
                ForEach(boards) { Text(verbatim: $0.name).tag($0.id) }
            }
            Picker("列", selection: $draft.columnID) {
                ForEach(boards.first { $0.id == draft.boardID }?.orderedColumns ?? [], id: \.id) { Text(verbatim: $0.label).tag($0.id) }
            }
        case .existing:
            Picker("タスク", selection: $draft.taskNumber) {
                Text("未選択").tag(Int?.none)
                ForEach((state?.tasks.values.sorted { $0.number > $1.number } ?? []).prefix(200)) { task in
                    Text(verbatim: "#\(task.number) \(task.title)").tag(Int?.some(task.number))
                }
            }
        case .none:
            EmptyView()
        }
    }

    private func fillDefaults() {
        let boards = model.orderedBoards(on: draft.launch.machine)
        if !boards.contains(where: { $0.id == draft.boardID }), let board = boards.first {
            draft.boardID = board.id
            draft.columnID = board.defaultColumn?.id ?? board.orderedColumns.first?.id ?? ""
        }
    }

    private func save() {
        if let message = draft.validate() {
            error = message
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await model.saveSchedule(draft)
                dismiss()
            } catch {
                let event: LocalizedStringResource = draft.existing == nil ? "定期起動を追加できませんでした" : "定期起動を保存できませんでした"
                self.error = UserFacingError(event, error: error)?.text
                saving = false
            }
        }
    }
}
