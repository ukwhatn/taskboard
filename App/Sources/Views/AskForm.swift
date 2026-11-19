import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// 文書に付いた質問。全問に答えると送信できる
struct AskForm: View {
    @Environment(AppModel.self) private var model
    let questions: [AskQuestion]
    let machine: MachineID
    /// 文書の質問は daemon に回答を保存する。チャットの AskUserQuestion（mod が知らせた問い）は Claude Code に答えを渡す
    let submit: Submit

    enum Submit {
        case ask(Ask)
        case custom(([AskAnswer]) async throws -> Void)
    }

    init(ask: Ask) {
        questions = ask.questions
        machine = ask.machine
        submit = .ask(ask)
    }

    init(questions: [AskQuestion], machine: MachineID, submit: @escaping ([AskAnswer]) async throws -> Void) {
        self.questions = questions
        self.machine = machine
        self.submit = .custom(submit)
    }

    @State private var selected: [String: Set<String>] = [:]
    @State private var freeText: [String: String] = [:]
    @State private var sending = false
    @State private var sent = false
    @State private var failure: UserFacingError?
    @State private var focused: [String: String] = [:]
    @State private var width: CGFloat = 0

    private var answers: [AskAnswer] {
        questions.map { q in
            let text = freeText[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return AskAnswer(questionID: q.id, selected: q.options.map(\.label).filter { selected[q.id]?.contains($0) == true }, freeText: text.isEmpty ? nil : text)
        }
    }

    var body: some View {
        let unanswered = questions.filter { q in answers.first { $0.questionID == q.id }?.isAnswered != true }
        let blocked = model.writeBlock(machine, "送信できません")
        VStack(alignment: .leading, spacing: Space.block) {
            Label(String(localized: "質問\(questions.count)件"), systemImage: "questionmark.bubble").textRole(.sectionTitle).foregroundStyle(.orange)
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: Space.row) {
                    if let header = question.header, !header.isEmpty {
                        Chip(text: header)
                    }
                    Text(question.question).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                    if let preview = previewOption(question) {
                        if width >= AskFormMetrics.sideBySideWidth {
                            HStack(alignment: .top, spacing: Space.block) {
                                options(question).frame(maxWidth: .infinity, alignment: .leading)
                                AskOptionPreview(option: preview).frame(maxWidth: .infinity)
                            }
                        } else {
                            options(question)
                            AskOptionPreview(option: preview)
                        }
                    } else if !question.options.isEmpty {
                        options(question)
                    }
                    let text = Binding(get: { freeText[question.id] ?? "" }, set: { freeText[question.id] = $0 })
                    if question.isSecret {
                        SecureField(String(localized: "自由記述"), text: text).textFieldStyle(.roundedBorder).font(.callout)
                    } else {
                        MultilineTextField(
                            label: String(localized: "自由記述"), placeholder: String(localized: "自由記述"), text: text, lines: 1...4, font: .callout, style: .roundedBorder)
                    }
                }
            }
            if let failure { FailureText(failure) }
            HStack(alignment: .firstTextBaseline) {
                if !unanswered.isEmpty {
                    Text("すべての質問に答えると送信できます。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let blocked {
                    Text(blocked.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.row)
                if case .ask(let ask) = submit {
                    Button("質問を閉じる") { close(ask) }
                        .disabled(sending || sent || blocked != nil)
                        .help("答えずに閉じる（チャットで話して済んだとき）")
                }
                let canSend = !sending && !sent && unanswered.isEmpty && blocked == nil
                Button(sending ? "送信しています…" : "回答を送信") { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                    .help("回答を送信（⌘↩）")
                    .commandReturn(enabled: canSend) { send() }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .attentionCard()
        .preference(key: DocumentPendingInputKey.self, value: !sent && hasInput)
    }

    private func options(_ question: AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            ForEach(question.options, id: \.label) { option in
                let isOn = selected[question.id]?.contains(option.label) == true
                Button {
                    toggle(question, option.label)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Image(systemName: question.multiSelect ? (isOn ? "checkmark.square.fill" : "square") : (isOn ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(isOn ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                                Text(option.displayLabel).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if option.isRecommended { Chip(text: String(localized: "推奨"), tint: .accentColor) }
                            }
                            if let description = option.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: HitTarget.size)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .onHover { inside in
                    if inside, option.preview != nil { focused[question.id] = option.label }
                }
            }
        }
    }

    /// 見本を出す選択肢: 最後に押したかポインタを載せた選択肢、選んでいる選択肢、推奨、見本を持つ最初の選択肢の順
    private func previewOption(_ question: AskQuestion) -> AskOption? {
        let withPreview = question.options.filter { $0.preview != nil }
        guard !withPreview.isEmpty else { return nil }
        if let label = focused[question.id], let option = withPreview.first(where: { $0.label == label }) { return option }
        if let option = withPreview.first(where: { selected[question.id]?.contains($0.label) == true }) { return option }
        return withPreview.first(where: \.isRecommended) ?? withPreview[0]
    }

    /// 選んだ選択肢か書いた自由記述がある（Esc で文書を閉じて消さない）
    private var hasInput: Bool {
        selected.values.contains { !$0.isEmpty } || freeText.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func toggle(_ question: AskQuestion, _ label: String) {
        focused[question.id] = label
        var set = selected[question.id] ?? []
        if question.multiSelect {
            if set.remove(label) == nil { set.insert(label) }
        } else {
            set = set.contains(label) ? [] : [label]
        }
        selected[question.id] = set
    }

    private func close(_ ask: Ask) {
        sending = true
        failure = nil
        Task {
            do {
                try await model.cancelAsk(ask)
                sent = true
            } catch {
                failure = UserFacingError("質問を閉じられませんでした", error: error)
            }
            sending = false
        }
    }

    private func send() {
        sending = true
        failure = nil
        Task {
            do {
                switch submit {
                case .ask(let ask): try await model.answer(ask, answers)
                case .custom(let send): try await send(answers)
                }
                sent = true
            } catch {
                failure = UserFacingError("回答を送信できませんでした", error: error)
            }
            sending = false
        }
    }
}

/// 回答済みの質問（読むだけ）
struct AnsweredAsks: View {
    let asks: [Ask]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            Text("回答済みの質問").textRole(.sectionTitle)
            ForEach(asks) { ask in
                ForEach(ask.questions) { q in
                    let answer = ask.answers?.first { $0.questionID == q.id }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(q.question).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let selected = answer?.selected, !selected.isEmpty {
                            Text(selected.joined(separator: "、")).font(.callout)
                        }
                        if let text = answer?.freeText, !text.isEmpty {
                            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if ask.deliveredAt == nil {
                    Text("セッションへの送信待ち").textRole(.caption)
                }
            }
        }
    }
}
