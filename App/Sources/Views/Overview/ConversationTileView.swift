import SwiftUI
import TaskboardKit

/// 会話 1 本の表示に要る値（会話の値の外から集めるもの）。札と 1 行の view はこれと札の値で比べ、ほかの会話が変わっても描き直さない
struct TileDetail: Equatable {
    var machineName: String
    /// タスクのリンクの状態（実行中の札の PR と CI）
    var links: [LinkStatus] = []
    var sending = false
    var failure: UserFacingError?
    /// 書き込めないときの文（答えのボタンを止める）
    var blocked: UserFacingError?
    /// Space で広げた中身
    var expansion: TileExpansion?
}

/// ホームの会話の札（対応待ち・実行中）。上の行にタスクとマシン、題、状態と経過、問いの中身か最後の応答、答えのボタン。
/// 押すと会話を開く。札の上で答えられるのは権限の確認だけで（中身が 1 行で完結する）、質問・計画・依頼は会話を開いて答える
struct ConversationTileView: View, @MainActor Equatable {
    @Environment(AppModel.self) private var model
    let tile: ConversationTile
    let detail: TileDetail

    static func == (lhs: ConversationTileView, rhs: ConversationTileView) -> Bool {
        lhs.tile == rhs.tile && lhs.detail == rhs.detail
    }

    private var key: ConversationKey { tile.id }
    private var expanded: Bool { detail.expansion != nil }

    var body: some View {
        #if DEBUG
        let _ = DebugCounters.hit("ConversationTileView")
        #endif
        VStack(alignment: .leading, spacing: Space.inline) {
            TileContextLine(tile: tile, machineName: detail.machineName)
            Text(tile.conversation.displayTitle).font(.callout.weight(.medium)).lineLimit(2)
            TileStatusLine(tile: tile)
            content
            if let expansion = detail.expansion { TileExpansionView(expansion: expansion) }
            if let failure = detail.failure {
                FailureText(failure)
            } else if let blocked = detail.blocked, answerable {
                Text(blocked.text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay { TileCursorRing(key: key, cornerRadius: Radius.card) }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onTapGesture { model.openTile(key) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("会話を開く")) { model.openTile(key) }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        if tile.group == .waiting {
            shape.fill(Color.orange.opacity(0.07)).overlay(shape.strokeBorder(Color.orange.opacity(0.35)))
        } else {
            shape.fill(.fill.quaternary)
        }
    }

    /// 札の上で答えられる（権限の確認だけ。書き込めないときの文を出す）
    private var answerable: Bool {
        guard case .request(let request) = tile.state else { return false }
        return request.kind == .permission
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        switch tile.state {
        case .request(let request):
            switch request.kind {
            case .permission:
                TilePermissionSummary(permission: request.waiting.permission ?? RequestWaiting.Permission(tool: request.toolName, summary: ""), expanded: expanded)
            case .question:
                let questions = request.waiting.questions ?? []
                if let first = questions.first {
                    Text(first.question).font(.callout).lineLimit(expanded ? nil : 3)
                }
                if questions.count > 1 {
                    Text("質問1/\(questions.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            case .plan:
                TilePlanText(plan: request.plan ?? "", expanded: expanded)
            case .elicitation:
                Text(request.elicitation?.message ?? "").font(.callout).lineLimit(3)
            case .unknown:
                EmptyView()
            }
        case .problem:
            EmptyView()
        case .starting, .running, .unread, .idle:
            if let reply = tile.conversation.lastReply?.headline, !reply.isEmpty, !expanded {
                Text(reply).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            TileMetaRow(conversation: tile.conversation, task: tile.task, links: detail.links)
        }
    }

    // MARK: ボタン

    @ViewBuilder
    private var actions: some View {
        let disabled = detail.sending || detail.blocked != nil
        switch tile.state {
        case .request(let request):
            switch request.kind {
            case .permission:
                if let decisions = ConversationDecisionPanel.shown(request.decisions) {
                    TileButtons {
                        ForEach(decisions, id: \.self) { decision in
                            let button = Button(ConversationDecisionPanel.label(decision)) {
                                model.answerTile(
                                    key, ConversationAnswerRequest(requestID: request.id, allow: decision.allows, decision: decision),
                                    failure: decision.allows ? "許可できませんでした" : "拒否できませんでした")
                            }
                            .disabled(disabled)
                            if decision == ConversationDecisionPanel.primary(decisions) { button.buttonStyle(.borderedProminent) } else { button }
                        }
                    }
                } else {
                    TileButtons {
                        Button("拒否") { model.answerTile(key, ConversationAnswerRequest(requestID: request.id, allow: false), failure: "拒否できませんでした") }
                            .disabled(disabled)
                        let suggestions = PermissionSuggestion.shown(request.suggestions ?? [])
                        if !suggestions.isEmpty {
                            Menu("常に許可") {
                                ForEach(suggestions, id: \.id) { suggestion in
                                    Button(suggestion.menuLabel) {
                                        model.answerTile(
                                            key, ConversationAnswerRequest(requestID: request.id, allow: true, suggestionID: suggestion.id), failure: "許可できませんでした")
                                    }
                                }
                            }
                            .menuIndicator(.visible)
                            .fixedSize()
                            .disabled(disabled)
                        }
                        Button("許可") { model.answerTile(key, AppModel.allowAnswer(request), failure: "許可できませんでした") }
                            .buttonStyle(.borderedProminent)
                            .disabled(disabled)
                    }
                }
            case .question, .plan, .elicitation, .unknown:
                TileButtons {
                    Button("会話を開く") { model.openTile(key) }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .problem(let problem):
            TileButtons {
                Button("会話を開く") { model.openTile(key) }
                if problem.stoppable {
                    Button("生成を停止") { model.interruptTile(key) }
                        .disabled(disabled)
                }
            }
        case .starting, .running, .unread, .idle:
            EmptyView()
        }
    }
}

extension ConversationProblem {
    /// 生成が続いていて、止められる（応答の止まり・送り直し）
    var stoppable: Bool {
        switch self {
        case .stalled, .apiRetry: true
        case .usageLimit, .network, .exited: false
        }
    }

    /// 状態の語（サイドバーの行の印・札の 1 行の形）
    var label: String {
        switch self {
        case .stalled: String(localized: "応答なし")
        case .apiRetry: String(localized: "送り直し中")
        case .usageLimit: String(localized: "利用枠の回復待ち")
        case .network: String(localized: "接続待ち")
        case .exited: String(localized: "異常終了")
        }
    }

    /// 会話の画面（`ConversationActivityRow`・利用枠とネットワークの帯・止まった会話の帯）と同じ文
    func text(now: Date) -> String {
        switch self {
        case .stalled: String(localized: "応答が止まっています")
        case .apiRetry(let retry): ConversationActivityRow.retryTitle(kind: retry.kind, status: retry.status) + " " + ConversationActivityRow.retryProgress(retry)
        case .usageLimit(let resumeAt, let paused):
            paused
                ? String(localized: "利用枠が残り少ないため、\(resumeAt.formatted(date: .omitted, time: .shortened))まで待ちます。")
                : String(localized: "利用枠の上限に達しました。\(resumeAt.formatted(date: .omitted, time: .shortened))に続きを送ります。")
        case .network: String(localized: "APIに接続できませんでした。ネットワークの接続が戻ったら続きを送ります。")
        case .exited:
            UserFacingError("会話が途中で動かなくなりました", remedy: String(localized: "送信すると、起動し直します")).text
        }
    }
}

extension ConversationTile {
    /// 状態の印の種類（サイドバーの行の印と同じ表）
    var sidebarStatus: SidebarStatus {
        switch state {
        case .request, .problem: .waiting
        case .running: .running
        case .starting: .starting
        case .unread: .unread
        case .idle: .idle
        }
    }

    /// 状態の語。問いは種類ごと（サイドバーのタスクの行と同じ語）
    var stateLabel: String {
        switch state {
        case .request(let request):
            switch request.kind {
            case .permission: String(localized: "応答待ち")
            case .plan: String(localized: "計画の承認待ち")
            case .question, .elicitation, .unknown: String(localized: "回答待ち")
            }
        case .problem(let problem): problem.label
        case .starting: String(localized: "起動中")
        case .running: String(localized: "実行中")
        case .unread: String(localized: "未読")
        case .idle: String(localized: "待機")
        }
    }
}

/// 経過（「6分」「2時間」「3日」）。秒は出さず、1 分ごとに描き直す
struct TileElapsed: View {
    let since: Date

    var body: some View {
        LiveClock(every: 60) { now in
            Text(Self.text(since, now: now)).monospacedDigit()
        }
    }

    static func text(_ since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        switch minutes {
        case ..<60: return String(localized: "\(minutes)分")
        case ..<(24 * 60): return String(localized: "\(minutes / 60)時間")
        default: return String(localized: "\(minutes / (24 * 60))日")
        }
    }
}

/// 札の上の行: タスクの番号と題、マシンの名前
private struct TileContextLine: View {
    let tile: ConversationTile
    let machineName: String

    var body: some View {
        HStack(spacing: Space.inline) {
            if let task = tile.task {
                Text("#\(task.number) \(task.title)").lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Text(machineName).lineLimit(1).layoutPriority(1)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// 状態の行: 印、状態の語、経過、実行中ならツールの名前。止まりの異常は会話の画面と同じ文
private struct TileStatusLine: View {
    let tile: ConversationTile

    var body: some View {
        let appearance = StatusAppearance.of(tile.sidebarStatus)
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            StatusGlyph(appearance: appearance).accessibilityHidden(true)
            if case .problem(let problem) = tile.state {
                LiveClock(every: 60) { now in
                    Text(problem.text(now: now)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.orange)
            } else {
                Text(tile.stateLabel).foregroundStyle(appearance.color)
            }
            if let since = tile.since {
                TileElapsed(since: since).foregroundStyle(.secondary)
            }
            if tile.state == .running {
                TileToolName(key: tile.id)
            }
        }
        .font(.caption)
    }
}

/// 使っているツールの名前。表示されている間だけ読み、ツールが替わっても描き直すのはこの view だけ
private struct TileToolName: View {
    @Environment(AppModel.self) private var model
    let key: ConversationKey

    var body: some View {
        if let name = model.fleet.toolName(of: key) {
            Text(name).lineLimit(1).foregroundStyle(.secondary)
        }
    }
}

/// 権限の確認の中身（ツール・説明・コマンド）。広げるまでコマンドは 2 行まで
private struct TilePermissionSummary: View {
    let permission: RequestWaiting.Permission
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                Text(permission.tool).font(.caption.weight(.medium))
                if let detail = permission.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(expanded ? nil : 1)
                }
            }
            Text(permission.summary)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(expanded ? nil : 2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 計画の頭の数行と「…ほかN行」。広げると全文
private struct TilePlanText: View {
    let plan: String
    let expanded: Bool

    var body: some View {
        let lines = plan.split(separator: "\n", omittingEmptySubsequences: true)
        let shown = expanded ? lines.count : min(lines.count, ConversationBoardMetrics.planLines)
        VStack(alignment: .leading, spacing: 2) {
            Text(lines.prefix(shown).joined(separator: "\n")).font(.callout).fixedSize(horizontal: false, vertical: true)
            if lines.count > shown {
                Text("…ほか\(lines.count - shown)行").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 実行中の札の下の段: ToDo の進み、PR と CI、差分、コンテキスト
private struct TileMetaRow: View {
    let conversation: Conversation
    let task: BoardTask?
    let links: [LinkStatus]

    var body: some View {
        let plan = conversation.plan ?? []
        let statuses = Dictionary(links.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let shownLinks = task.map { TaskLink.ordered($0.links, statuses: statuses).active.prefix(2) } ?? []
        let diff = conversation.diff.flatMap { $0.isRepo && $0.files > 0 ? $0 : nil }
        if !plan.isEmpty || !shownLinks.isEmpty || diff != nil || conversation.contextPercent != nil {
            FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                if !plan.isEmpty {
                    let done = plan.filter { $0.status == .completed }.count
                    Text("ToDo\(done)/\(plan.count)").monospacedDigit()
                        .accessibilityLabel("ToDo\(plan.count)件中\(done)件完了")
                }
                ForEach(Array(shownLinks)) { link in
                    LinkChip(link: link, status: statuses[link.url])
                }
                if let diff { DiffCounts(insertions: diff.insertions, deletions: diff.deletions) }
                if let percent = conversation.contextPercent {
                    Text("コンテキスト\(UsageText.percent(Double(percent)))").monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// Space で広げた最後の発言
struct TileExpansionView: View {
    let expansion: TileExpansion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.inline) {
            Divider()
            if let failure = expansion.failure {
                FailureText(failure)
            } else if let messages = expansion.messages {
                if messages.isEmpty {
                    Text("メッセージはありません").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(messages, id: \.id) { message in
                    HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                        Image(systemName: message.role == .user ? "person" : "sparkle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(message.text)
                            .font(.callout)
                            .foregroundStyle(message.role == .user ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(spacing: Space.inline) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 札の下の帯のボタン。右に寄せ、入りきらない幅では縦に並べる
private struct TileButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.row) {
                Spacer(minLength: 0)
                content
            }
            VStack(alignment: .trailing, spacing: Space.inline) { content }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// キーで選んでいる会話の枠（列の形のカードの選択と同じ破線）。選択を読むのはこの view だけ
struct TileCursorRing: View {
    @Environment(AppModel.self) private var model
    let key: ConversationKey
    let cornerRadius: CGFloat

    var body: some View {
        if model.cursorTile == key {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.tint.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                .accessibilityHidden(true)
        }
    }
}
