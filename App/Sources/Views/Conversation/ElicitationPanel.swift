import SwiftUI
import TaskboardKit

/// コネクタ（MCP の server）の問い。form は欄に入れて［送信］、url は開く先を見せてから［開く］、入力欄にできない形は［断る］［取り消す］
struct ElicitationPanel: View {
    let elicitation: Elicitation
    let blocked: UserFacingError?
    /// 答えを送る（`action` と、form を受けるときの `content`）
    let answer: (ElicitationAction, [String: ElicitationValue]?) async throws -> Void
    /// url の問いの開く先の全文を daemon から受け取る
    let fetchURL: () async throws -> URL

    @State private var texts: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var fieldErrors: [String: String] = [:]
    @State private var sending = false
    @State private var failure: UserFacingError?

    init(
        elicitation: Elicitation, blocked: UserFacingError?,
        answer: @escaping (ElicitationAction, [String: ElicitationValue]?) async throws -> Void, fetchURL: @escaping () async throws -> URL
    ) {
        self.elicitation = elicitation
        self.blocked = blocked
        self.answer = answer
        self.fetchURL = fetchURL
        var texts: [String: String] = [:]
        var flags: [String: Bool] = [:]
        for field in elicitation.form?.fields ?? [] {
            switch field.defaultValue {
            case .string(let text): texts[field.key] = text
            case .number(let number): texts[field.key] = ElicitationCopy.number(number)
            case .bool(let flag): flags[field.key] = flag
            case nil: break
            }
        }
        _texts = State(initialValue: texts)
        _flags = State(initialValue: flags)
    }

    private var answerable: Bool { elicitation.allowedActions.contains(.accept) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Label("コネクタからの質問", systemImage: "puzzlepiece.extension").textRole(.sectionTitle).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: Space.inline) {
                Text(verbatim: elicitation.serverName).font(.caption).foregroundStyle(.secondary)
                if let title = elicitation.title, !title.isEmpty { Text(verbatim: title).font(.headline).fixedSize(horizontal: false, vertical: true) }
                Text(verbatim: elicitation.message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            content
            if let failure { Text(failure.text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(alignment: .firstTextBaseline) {
                if let blocked {
                    Text(blocked.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.row)
                Button("取り消す") { send(.cancel) }.disabled(sending || blocked != nil)
                Button("断る") { send(.decline) }.disabled(sending || blocked != nil)
                if answerable {
                    switch elicitation.mode {
                    case .url:
                        Button("開く") { open() }.buttonStyle(.borderedProminent).disabled(sending || blocked != nil)
                    default:
                        Button("送信") { submit() }.buttonStyle(.borderedProminent).disabled(sending || blocked != nil)
                    }
                }
            }
        }
        .padding(Space.card)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    @ViewBuilder
    private var content: some View {
        switch elicitation.mode {
        case .url:
            if let link = elicitation.link {
                LabeledContent("開く先") {
                    Text(verbatim: link.origin).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("このアドレスはアプリで開けません。断ってください。").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .form where answerable:
            ForEach(elicitation.form?.fields ?? []) { field in
                fieldView(field)
            }
        default:
            Text("この質問はアプリで入力できません。断ってください。").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: Elicitation.Field) -> some View {
        let label = ElicitationCopy.label(field)
        VStack(alignment: .leading, spacing: Space.inline) {
            switch field.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { flags[field.key] ?? false }, set: { flags[field.key] = $0 })) {
                    Text(verbatim: label)
                }
            case .choice:
                Picker(selection: Binding(get: { texts[field.key] ?? "" }, set: { texts[field.key] = $0 })) {
                    if !field.required || texts[field.key] == nil { Text("選択してください").tag("") }
                    ForEach(field.options ?? [], id: \.value) { option in
                        Text(verbatim: option.title ?? option.value).tag(option.value)
                    }
                } label: {
                    Text(verbatim: label)
                }
            default:
                Text(verbatim: label).font(.callout)
                TextField(
                    text: Binding(get: { texts[field.key] ?? "" }, set: { texts[field.key] = $0 }),
                    // 見本の無い欄も空にする（nil だと macOS はラベルを入れる）
                    prompt: Text(verbatim: ElicitationCopy.sample(field) ?? "")
                ) {
                    Text(verbatim: label)
                }
                .labelsHidden()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(ElicitationCopy.keyboard(field))
                #endif
                .onSubmit(submit)
            }
            if let description = field.description, !description.isEmpty {
                Text(verbatim: description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let condition = ElicitationCopy.condition(field) {
                Text(condition).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = fieldErrors[field.key] {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 欄の文字を答えの値にする。数の欄に数でない文字があれば、その欄の誤りにする
    private func collect() -> [String: ElicitationValue]? {
        var content: [String: ElicitationValue] = [:]
        var errors: [String: String] = [:]
        for field in elicitation.form?.fields ?? [] {
            switch field.kind {
            case .boolean:
                content[field.key] = .bool(flags[field.key] ?? false)
            case .number, .integer:
                let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                if let number = Double(text) { content[field.key] = .number(number) } else { errors[field.key] = ElicitationCopy.numberRequest(field) }
            default:
                let text = texts[field.key] ?? ""
                if !text.isEmpty { content[field.key] = .string(text) }
            }
        }
        fieldErrors = errors
        return errors.isEmpty ? content : nil
    }

    private func submit() {
        guard answerable, !sending, blocked == nil, let content = collect() else { return }
        do {
            try elicitation.check(.accept, content: content)
        } catch {
            if let key = error.fieldKey, let field = elicitation.form?.fields.first(where: { $0.key == key }) {
                fieldErrors[key] = ElicitationCopy.message(error, field: field)
            } else {
                failure = UserFacingError("送信できませんでした", cause: nil)
            }
            return
        }
        send(.accept, content: content)
    }

    /// 開く先の全文を受け取り、確かめてからブラウザで開き、開いたことを知らせる
    private func open() {
        sending = true
        failure = nil
        Task {
            do {
                let url = try await fetchURL()
                guard let checked = OAuthLinks.openable(url.absoluteString), Elicitation.Link(openable: checked) == elicitation.link else {
                    failure = UserFacingError("開けませんでした", cause: String(localized: "開く先が質問に出ていたアドレスと違います。"))
                    sending = false
                    return
                }
                ExternalLinks.openInBrowser(checked)
                try await answer(.accept, nil)
            } catch {
                failure = UserFacingError("開けませんでした", error: error)
            }
            sending = false
        }
    }

    private func send(_ action: ElicitationAction, content: [String: ElicitationValue]? = nil) {
        sending = true
        failure = nil
        Task {
            do {
                try await answer(action, content)
            } catch {
                failure = UserFacingError("送信できませんでした", error: error)
            }
            sending = false
        }
    }
}

/// コネクタの問いの欄に出す文（入力の条件と誤り）
enum ElicitationCopy {
    static func label(_ field: Elicitation.Field) -> String {
        let name = field.title.flatMap { $0.isEmpty ? nil : $0 } ?? field.key
        return field.required ? String(localized: "\(name)（必須）") : name
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// 入力する前から見せる条件。無ければ nil
    static func condition(_ field: Elicitation.Field) -> String? {
        switch field.kind {
        case .text:
            switch (field.minLength, field.maxLength) {
            case let (min?, max?): String(localized: "\(min)〜\(max)文字で入力してください。")
            case let (min?, nil): String(localized: "\(min)文字以上で入力してください。")
            case let (nil, max?): String(localized: "\(max)文字以内で入力してください。")
            case (nil, nil): nil
            }
        case .number, .integer:
            switch (field.minimum.map(number), field.maximum.map(number)) {
            case let (min?, max?): field.kind == .integer ? String(localized: "\(min)〜\(max)の整数を入力してください。") : String(localized: "\(min)〜\(max)の数を入力してください。")
            case let (min?, nil): field.kind == .integer ? String(localized: "\(min)以上の整数を入力してください。") : String(localized: "\(min)以上の数を入力してください。")
            case let (nil, max?): field.kind == .integer ? String(localized: "\(max)以下の整数を入力してください。") : String(localized: "\(max)以下の数を入力してください。")
            case (nil, nil): field.kind == .integer ? String(localized: "整数を入力してください。") : nil
            }
        default:
            nil
        }
    }

    /// 書式の見本（プレースホルダー）
    static func sample(_ field: Elicitation.Field) -> String? {
        switch field.format {
        case .email?: "name@example.com"
        case .uri?: "https://"
        case .date?: "2026-10-20"
        case .dateTime?: "2026-10-20T09:30:00+09:00"
        case .unknown?, nil: nil
        }
    }

    static func numberRequest(_ field: Elicitation.Field) -> String {
        condition(field) ?? String(localized: "数を入力してください。")
    }

    static func message(_ error: ElicitationAnswerError, field: Elicitation.Field) -> String {
        switch error {
        case .missing: String(localized: "入力してください。")
        case .wrongType: numberRequest(field)
        case .outOfRange: condition(field) ?? String(localized: "10KB以内で入力してください。")
        case .notAnOption: String(localized: "選択肢から選んでください。")
        case .badFormat:
            switch field.format {
            case .email?: String(localized: "メールアドレスの形式で入力してください。")
            case .uri?: String(localized: "https://のようなアドレスの形式で入力してください。")
            case .date?: String(localized: "2026-10-20の形式で入力してください。")
            default: String(localized: "2026-10-20T09:30:00+09:00の形式で入力してください。")
            }
        case .unknownField, .actionNotAllowed, .contentNotAllowed: String(localized: "入力してください。")
        }
    }

    #if os(iOS)
    static func keyboard(_ field: Elicitation.Field) -> UIKeyboardType {
        switch (field.kind, field.format) {
        case (.integer, _): .numberPad
        case (.number, _): .decimalPad
        case (_, .email?): .emailAddress
        case (_, .uri?): .URL
        default: .default
        }
    }
    #endif
}

extension ElicitationAnswerError {
    /// 欄の誤りなら欄の名前
    var fieldKey: String? {
        switch self {
        case .missing(let key), .unknownField(let key), .wrongType(let key), .outOfRange(let key), .badFormat(let key), .notAnOption(let key): key
        case .actionNotAllowed, .contentNotAllowed: nil
        }
    }
}
