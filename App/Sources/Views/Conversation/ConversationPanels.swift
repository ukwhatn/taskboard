import SwiftUI
import TaskboardKit

/// 会話の問いのカード。質問は `AskForm`、権限の確認は［許可］［拒否］（Claude の「今後は聞かない」候補があれば［常に許可］のメニューを添え、
/// Codex の選択肢があれば `ConversationDecisionPanel`）、計画は本文と［承認］［却下］、
/// コネクタの問いは `ElicitationPanel`
struct ConversationRequestPanel: View {
    let request: ConversationRequest
    let machine: MachineID
    let blocked: UserFacingError?
    /// コネクタの問い（url）の開く先の全文を受け取る
    let fetchURL: (String) async throws -> URL
    let answer: (ConversationAnswerRequest) async throws -> Void

    var body: some View {
        switch request.kind {
        case .question:
            AskForm(questions: request.waiting.questions ?? [], machine: machine) { answers in
                try await answer(ConversationAnswerRequest(requestID: request.id, answers: answers))
            }
        case .plan:
            ConversationPlanPanel(plan: request.plan ?? "", blocked: blocked) { allow in
                try await answer(ConversationAnswerRequest(requestID: request.id, allow: allow))
            }
        case .permission:
            let permission = request.waiting.permission ?? RequestWaiting.Permission(tool: request.toolName, summary: "")
            if let decisions = ConversationDecisionPanel.shown(request.decisions) {
                ConversationDecisionPanel(permission: permission, decisions: decisions, blocked: blocked) { decision in
                    try await answer(ConversationAnswerRequest(requestID: request.id, allow: decision.allows, decision: decision))
                }
            } else {
                PermissionPanel(
                    permission: permission, blocked: blocked, suggestions: request.suggestions ?? [],
                    decideRemembered: { suggestion in
                        try await answer(ConversationAnswerRequest(requestID: request.id, allow: true, suggestionID: suggestion.id))
                    }
                ) { allow in
                    try await answer(ConversationAnswerRequest(requestID: request.id, allow: allow))
                }
            }
        case .elicitation:
            if let elicitation = request.elicitation {
                ElicitationPanel(
                    elicitation: elicitation, blocked: blocked,
                    answer: { action, content in try await answer(ConversationAnswerRequest(requestID: request.id, action: action, content: content)) },
                    fetchURL: { try await fetchURL(request.id) })
            } else {
                UnsupportedRequestPanel()
            }
        case .unknown:
            UnsupportedRequestPanel()
        }
    }
}

/// iPhone で入力欄を打っている間の問いの帯。題だけを出し、［回答する］でキーボードを閉じて元のカードに戻す（カードが会話の欄を塞がないように）
struct ConversationRequestStrip: View {
    let request: ConversationRequest
    let open: () -> Void

    var body: some View {
        HStack(spacing: Space.row) {
            Label(title, systemImage: symbol)
                .textRole(.sectionTitle)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("回答する", action: open)
                .buttonStyle(.borderedProminent)
        }
        .attentionCard()
    }

    private var title: String {
        switch request.kind {
        case .question: String(localized: "質問\(request.waiting.questions?.count ?? 0)件")
        case .plan: String(localized: "計画の承認")
        case .permission: String(localized: "権限の確認")
        case .elicitation: String(localized: "コネクタからの質問")
        case .unknown: String(localized: "回答待ち")
        }
    }

    private var symbol: String {
        switch request.kind {
        case .question: "questionmark.bubble"
        case .plan: "list.bullet.clipboard"
        case .permission: "hand.raised"
        case .elicitation: "puzzlepiece.extension"
        case .unknown: "questionmark.bubble"
        }
    }
}

/// Codex の承認で、要求が出した答えだけを並べるカード。拒否の側を左に、許可を右の主なボタン（⌘Y）にする。
/// 拒否の理由の欄は置かない（codex に届かない）
struct ConversationDecisionPanel: View {
    let permission: RequestWaiting.Permission
    let decisions: [ConversationDecision]
    let blocked: UserFacingError?
    let decide: (ConversationDecision) async throws -> Void

    @State private var sending = false
    @State private var failure: UserFacingError?

    /// 並べる順
    private static let order: [ConversationDecision] = [.cancel, .decline, .acceptForSession, .accept]

    /// 出す答え。この版が知っている答えが無ければ nil（［許可］［拒否］の 2 択にする）
    static func shown(_ decisions: [ConversationDecision]?) -> [ConversationDecision]? {
        let known = order.filter { decisions?.contains($0) == true }
        return known.isEmpty ? nil : known
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Label("権限の確認", systemImage: "hand.raised").textRole(.sectionTitle).foregroundStyle(.orange)
            ModPermissionSummary(permission: permission)
            if let failure { Text(failure.text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let blocked {
                Text(blocked.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // 4 つが横に入り切らない幅では縦に並べる
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.row) {
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .trailing, spacing: Space.inline) { buttons }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .attentionCard()
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(decisions, id: \.self) { decision in
            let button = Button(Self.label(decision)) { send(decision) }
                .disabled(sending || blocked != nil)
                .help(Self.help(decision) ?? Self.label(decision))
            if decision == primary {
                button.buttonStyle(.borderedProminent).keyboardShortcut("y", modifiers: .command)
            } else {
                button
            }
        }
    }

    /// 主なボタン（⌘Y）
    private var primary: ConversationDecision? { Self.primary(decisions) }

    /// 主な答え。許可が無ければ許可の側の右端。ホームの会話の ⌘Y もこれを送る
    static func primary(_ decisions: [ConversationDecision]) -> ConversationDecision? {
        decisions.contains(.accept) ? .accept : decisions.last { $0.allows }
    }

    static func label(_ decision: ConversationDecision) -> String {
        switch decision {
        case .accept: String(localized: "許可")
        case .acceptForSession: String(localized: "この会話の間は許可")
        case .decline: String(localized: "拒否")
        case .cancel: String(localized: "拒否して生成を停止")
        case .unknown: ""
        }
    }

    static func help(_ decision: ConversationDecision) -> String? {
        switch decision {
        case .accept: String(localized: "この確認を許可（⌘Y）")
        case .acceptForSession: String(localized: "同じコマンドは、この会話の間は確認せずに許可します")
        case .cancel: String(localized: "拒否して、生成を停止します")
        case .decline, .unknown: nil
        }
    }

    private func send(_ decision: ConversationDecision) {
        sending = true
        failure = nil
        Task {
            do {
                try await decide(decision)
            } catch {
                failure = UserFacingError(decision.allows ? "許可できませんでした" : "拒否できませんでした", error: error)
            }
            sending = false
        }
    }
}

/// この版が知らない種類の問い。答えずに捨てると CLI が待ったままになるので、アプリを更新するよう案内する
struct UnsupportedRequestPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            Label("未対応の質問", systemImage: "questionmark.circle").textRole(.sectionTitle).foregroundStyle(.orange)
            Text("このアプリが対応していない種類の質問です。アプリを更新してください。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .attentionCard()
    }
}

/// ExitPlanMode の計画。本文を読み、［承認］で計画のとおりに進め、［却下］で計画を立て直させる
struct ConversationPlanPanel: View {
    let plan: String
    let blocked: UserFacingError?
    let decide: (Bool) async throws -> Void

    var body: some View {
        DecisionCard(
            title: String(localized: "計画の承認"), symbol: "list.bullet.clipboard",
            deny: .init(label: String(localized: "却下"), failure: "却下できませんでした"),
            allow: .init(label: String(localized: "承認"), failure: "承認できませんでした"),
            blocked: blocked, decide: decide
        ) {
            ScrollView {
                MarkdownView(plan)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: ConversationMetrics.planHeight)
        }
    }
}
