import SwiftUI
import TaskboardKit

/// 会話の engine が、発言を書かずに続けていること。生成中の block の後ろ（会話の末尾）に出す
enum ConversationActivity: Hashable {
    case compacting(ConversationCompaction)
    /// 生成中なのに engine から何も届かない（daemon の見張り）。値は最後に届いた時刻
    case stalled(since: Date)
    /// API に届かず engine が送り直している
    case apiRetry(ConversationAPIRetry)

    /// 並びは、止まり（手を打てる）、送り直し、圧縮
    init?(_ conversation: Conversation?) {
        if let since = conversation?.stalledSince {
            self = .stalled(since: since)
        } else if let retry = conversation?.apiRetry {
            self = .apiRetry(retry)
        } else if let compaction = conversation?.compaction {
            self = .compacting(compaction)
        } else {
            return nil
        }
    }
}

/// 会話の末尾の、engine が今していることの行。回る印と経過の時間で、止まっていないことを示す
struct ConversationActivityRow: View {
    let activity: ConversationActivity
    let fonts: ChatFonts
    /// 止まったときの［生成を停止］。nil なら押せない（止めている途中・書き込めない接続先）
    var stopGenerating: (() -> Void)?

    var body: some View {
        switch activity {
        case .compacting(let compaction):
            LiveClock(every: 1) { now in
                HStack(spacing: Space.row) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("会話を圧縮しています…").font(fonts.subheadline).foregroundStyle(ChatPalette.secondaryText)
                    if let chars = compaction.outputChars {
                        Text("要約\(chars.formatted())字").font(fonts.caption).foregroundStyle(ChatPalette.mutedText)
                    }
                    Text(verbatim: Self.elapsed(from: compaction.startedAt, to: now)).font(fonts.caption).foregroundStyle(ChatPalette.mutedText)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
            .chatRowIndented(fonts: fonts)
            .accessibilityElement(children: .combine)
        case .apiRetry(let retry):
            LiveClock(every: 1) { now in
                HStack(spacing: Space.row) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(Self.retryTitle(kind: retry.kind, status: retry.status)).font(fonts.subheadline).foregroundStyle(ChatPalette.secondaryText)
                    Text(Self.retryProgress(retry)).font(fonts.caption).foregroundStyle(ChatPalette.mutedText).monospacedDigit()
                    Text(verbatim: Self.clockText(activity, now: now)).font(fonts.caption).foregroundStyle(ChatPalette.mutedText).monospacedDigit()
                    Spacer(minLength: 0)
                }
            }
            .chatRowIndented(fonts: fonts)
            .accessibilityElement(children: .combine)
        case .stalled(let since):
            LiveClock(every: 1) { now in
                HStack(spacing: Space.row) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange).font(fonts.caption).accessibilityHidden(true)
                    Text("応答が止まっています").font(fonts.subheadline).foregroundStyle(ChatPalette.secondaryText)
                    Text(verbatim: Self.elapsed(from: since, to: now)).font(fonts.caption).foregroundStyle(ChatPalette.mutedText).monospacedDigit()
                    Spacer(minLength: Space.row)
                    Button("生成を停止") { stopGenerating?() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(stopGenerating == nil)
                }
            }
            .chatRowIndented(fonts: fonts)
            .accessibilityElement(children: .contain)
        }
    }

    /// 「32秒」「1分12秒」。時計がずれて始まりより前になったら 0 秒
    nonisolated static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return Self.duration(seconds)
    }

    private nonisolated static func duration(_ seconds: Int) -> String {
        seconds < 60 ? String(localized: "\(seconds)秒") : String(localized: "\(seconds / 60)分\(seconds % 60)秒")
    }

    /// 行の右に出す時間。圧縮・止まりは始まりからの経過、送り直しは次に送るまでの残り（過ぎたら空）
    nonisolated static func clockText(_ activity: ConversationActivity, now: Date) -> String {
        switch activity {
        case .compacting(let compaction): elapsed(from: compaction.startedAt, to: now)
        case .stalled(let since): elapsed(from: since, to: now)
        case .apiRetry(let retry):
            // 切り上げる（0.4 秒前に「あと0秒」を出さない）
            retry.retryAt.timeIntervalSince(now) > 0 ? String(localized: "あと\(duration(Int(retry.retryAt.timeIntervalSince(now).rounded(.up))))") : ""
        }
    }

    /// 送り直しの理由。`kind` は CLI の種類の名前（知らない名前は理由なし）。HTTP の status は出さない
    nonisolated static func retryTitle(kind: String, status: Int?) -> String {
        switch kind {
        case "unknown": status == nil ? String(localized: "APIに接続できません。送り直しています…") : String(localized: "APIがエラーを返しました。送り直しています…")
        case "overloaded": String(localized: "APIが混み合っています。送り直しています…")
        case "rate_limit": String(localized: "利用枠の上限に達しています。送り直しています…")
        case "authentication_failed": String(localized: "認証できません。送り直しています…")
        case "server_error": String(localized: "APIがエラーを返しました。送り直しています…")
        case "cloud_credential_error": String(localized: "クラウドの認証情報を取得できません。送り直しています…")
        default: String(localized: "送り直しています…")
        }
    }

    /// 「3/10回目」。上限を CLI が載せない版は「3回目」
    nonisolated static func retryProgress(_ retry: ConversationAPIRetry) -> String {
        if let maxRetries = retry.maxRetries { return String(localized: "\(retry.attempt)/\(maxRetries)回目") }
        return String(localized: "\(retry.attempt)回目")
    }
}
