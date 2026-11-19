import SwiftUI
import TaskboardKit

/// タスクの再開の予定（［状態］）。時刻の早い順に、時刻・仕掛けたときの文・届け先の会話と、届けられていない理由。操作は置かない（取り消すのは MCP）
struct TaskWakeList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let wakes: [Wake]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            ForEach(wakes) { wake in
                WakeRow(wake: wake, conversation: wake.conversationID.flatMap { model.conversationTitle(machine: wake.machine, id: $0) }, now: today)
            }
        }
    }
}

struct WakeRow: View {
    let wake: Wake
    /// 届け先の会話のタイトル（会話宛てか、daemon が会話を選んだとき）
    let conversation: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(wake, now: now)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: wake.prompt).lineLimit(2).textRole(.secondary)
            if let conversation { MetaLine(items: [RowNote.conversation(conversation)]) }
            if let note = Self.note(wake) { RowNote(note: note) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func title(_ wake: Wake, now: Date) -> String {
        let time = ScheduleText.time(wake.at, now: now)
        return wake.state == .failed ? String(localized: "\(time)に再開できませんでした") : String(localized: "\(time)に再開")
    }

    /// 失敗した原因か、試し直している様子。事象は題が言うので、ここには書かない
    static func note(_ wake: Wake) -> RowNote.Content? {
        guard let problem = wake.problem else { return nil }
        if wake.state == .failed {
            return failureCause(problem).map { RowNote.Content(text: $0, symbol: "xmark.circle.fill", color: .red) }
        }
        return retryNote(problem).map { RowNote.Content(text: $0, symbol: "clock.arrow.circlepath", color: .secondary) }
    }

    /// 失敗した原因。分からないとき（起動や再開がうまくいかなかった・前の版の記録）は nil
    static func failureCause(_ problem: WakeProblem) -> String? {
        switch problem {
        case .conversationMissing: String(localized: "届け先の会話がありません。")
        case .taskMissing: String(localized: "届け先のタスクがありません。")
        case .terminalUnavailable, .gaveUp(.terminalUnavailable): String(localized: "この接続先ではターミナルで起動できません。")
        case .gaveUp(.busy): String(localized: "24時間、会話の生成か質問への回答が終わりませんでした。")
        case .gaveUp(.paneNotReady): String(localized: "24時間、タスクのセッションが応答待ちになりませんでした。")
        case .gaveUp(.resuming): String(localized: "24時間たっても、終了したセッションが再開しませんでした。")
        case .gaveUp(.unconfirmed): String(localized: "24時間、届いたかを確認できませんでした。")
        default: nil
        }
    }

    /// 時刻を過ぎても届けられず、試し直している様子
    static func retryNote(_ problem: WakeProblem) -> String? {
        switch problem {
        case .busy: String(localized: "会話の生成か質問への回答が終わるのを待っています。")
        case .paneNotReady: String(localized: "タスクのセッションが応答待ちになるのを待っています。")
        case .resuming: String(localized: "終了したセッションを再開しています。")
        case .unconfirmed: String(localized: "届いたかを確認できなかったので、もう一度送ります。")
        case .resumeFailed: String(localized: "会話を再開できませんでした。時間をおいてやり直します。")
        case .startFailed: String(localized: "会話を起動できませんでした。時間をおいてやり直します。")
        case .terminalFailed: String(localized: "ターミナルで起動できませんでした。時間をおいてやり直します。")
        case .terminalUnavailable: String(localized: "この接続先ではターミナルで起動できません。")
        default: nil
        }
    }
}

/// タスクの監視（［状態］）。作った順に、監視する対象・条件・届け先の会話と、取得の失敗かタグに入ったこと。操作は置かない
struct TaskWatchList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.today) private var today
    let watches: [Watch]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            ForEach(watches) { watch in
                WatchRow(watch: watch, conversation: watch.conversationID.flatMap { model.conversationTitle(machine: watch.machine, id: $0) }, now: today)
            }
        }
    }
}

struct WatchRow: View {
    let watch: Watch
    let conversation: String?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: Self.title(watch)).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let prompt = watch.prompt { Text(verbatim: prompt).lineLimit(2).textRole(.secondary) }
            let meta = Self.meta(watch, conversation: conversation, now: now)
            if !meta.isEmpty { MetaLine(items: meta) }
            if let note = Self.note(watch) { RowNote(note: note) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 監視する対象。issue・PR は「repo#番号」、repo は「owner/nameの新しいPR・issue」、コマンドはその 1 行目
    static func title(_ watch: Watch) -> String {
        if let command = watch.command { return String(command.command.prefix { !$0.isNewline }) }
        // url は daemon が GitHub の issue・PR と確かめてある。`TaskLink.kind(of:)` は GHES の host を知らないと GitHub と見ない
        if let url = watch.url { return TaskLink(id: 0, url: url, kind: url.contains("/pull/") ? .githubPR : .githubIssue, addedAt: .distantPast).shortLabel }
        return String(localized: "\(watch.repo ?? "")の新しいPR・issue")
    }

    static func meta(_ watch: Watch, conversation: String?, now: Date) -> [String] {
        var items = conversation.map { [RowNote.conversation($0)] } ?? []
        if let command = watch.command {
            items.append(condition(command))
            if command.condition != .finishes { items.append(interval(command.intervalSeconds ?? CommandWatchSpec.defaultInterval)) }
        }
        if let query = watch.query { items.append(String(localized: "検索条件：\(query)")) }
        if watch.tag == nil {
            if let pattern = watch.tagPattern {
                items.append(String(localized: "タグ「\(pattern)」待ち"))
            } else if watch.events.contains(.tagged) {
                items.append(String(localized: "タグ待ち"))
            }
        }
        // `finishes` は daemon が once にするが、「終わったら」で 1 回と分かる
        if watch.once, watch.command?.condition != .finishes { items.append(String(localized: "1回だけ")) }
        if let expires = watch.expiresAt { items.append(String(localized: "\(ScheduleText.time(expires, now: now))まで")) }
        return items
    }

    static func note(_ watch: Watch) -> RowNote.Content? {
        if let tag = watch.tag { return RowNote.Content(text: String(localized: "タグ「\(tag)」に入りました"), symbol: "checkmark.circle.fill", color: .green) }
        guard watch.state == .active, watch.error != nil else { return nil }
        // daemon の取得の失敗の文は agent とログ向けなので出さない（`Watch.error`）
        let text = watch.kind == .command ? String(localized: "コマンドを起動できませんでした。自動でやり直します。") : String(localized: "取得できませんでした。自動でやり直します。")
        return RowNote.Content(text: text, symbol: "exclamationmark.triangle.fill", color: .orange)
    }

    static func condition(_ command: CommandWatchSpec) -> String {
        switch command.condition {
        case .succeeds: String(localized: "成功したら")
        case .fails: String(localized: "失敗したら")
        case .matches: String(localized: "出力が「\(command.pattern ?? "")」に合ったら")
        case .changes: String(localized: "出力が変わったら")
        case .finishes: String(localized: "終わったら")
        }
    }

    static func interval(_ seconds: Int) -> String {
        if seconds % 3_600 == 0 { return String(localized: "\(seconds / 3_600)時間ごと") }
        if seconds % 60 == 0 { return String(localized: "\(seconds / 60)分ごと") }
        return String(localized: "\(seconds)秒ごと")
    }
}

/// 行の下の、印と 1〜2 文（予定の失敗の原因と試し直している様子・監視の取得の失敗・タグに入ったこと）。意味は文で伝え、印の色は添えるだけ
struct RowNote: View {
    struct Content: Equatable {
        var text: String
        var symbol: String
        var color: Color
    }

    let note: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
            Image(systemName: note.symbol).imageScale(.small).foregroundStyle(note.color).accessibilityHidden(true)
            Text(verbatim: note.text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    /// 届け先の会話（仕掛けたときの文と見分けるため、題を「」で囲む）
    static func conversation(_ title: String) -> String {
        String(localized: "会話「\(title)」")
    }
}

extension AppModel {
    /// 会話のタイトル（会話が state に無ければ nil）
    func conversationTitle(machine: MachineID, id: String) -> String? {
        fleet.conversation(for: ConversationKey(machine: machine, id: id))?.displayTitle
    }
}
