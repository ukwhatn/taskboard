// ui-copy:ignore-file
// このファイルの文は、daemon が会話に人の発言として入れ、agent が読む（docs/ui-copy.md の対象外）
import Foundation

/// taskboard が会話に人の発言として入れた知らせの種類。1 行目の印（`marker`）で見分ける。印の無い文は頭の文で見分ける
/// （印を付ける前の daemon が入れた知らせが会話の履歴に残る）。文を組む側は印と頭の文の両方をここから取る
public enum TaskboardNotice: String, Hashable, Sendable, CaseIterable {
    /// 委譲先の会話のターンの終わり・回答待ち（`ConversationNotices`）
    case delegate
    /// リンクした PR・issue の動き（`LinkNotices`）
    case link
    /// 質問の回答（`FeedbackText.forPrompt`）
    case answer
    /// 文書のレビュー（`FeedbackText.forPrompt`）
    case review
    /// 利用者が済ませた手作業（`FeedbackText.forPrompt`）
    case finished
    /// 概況の送る文面の承認（`FeedbackText.forPrompt`）
    case draft
    /// 利用枠が戻った後の続き
    case limitResume = "limit_resume"
    /// ネットワークの接続が戻った後の続き
    case networkResume = "network_resume"
    /// 決めた時刻に会話へ指示を送る予定（`WakeService`）。「作成時の指示:」の行の下に、予定を作ったときの指示
    case wake
    /// 監視した issue・PR の動き（`WatchNotices`）。1 行目の括弧に監視する対象の短い表記
    case watch
    /// 別のセッションが `session_prompt` で送った発言。送り主の項目と「本文:」の下に送った文
    case sessionPrompt = "session_prompt"
    /// Slack で頼まれた依頼（`SlackBridge`）。送り主の項目と「依頼:」の下に依頼した人の発言
    case slack

    /// 1 行目の印。daemon が組む通知（委譲先・リンク・監視・予定）はこれで始まる
    public static let mark = "[taskboard 通知] "
    public static let delegateTurnHead = mark + "委譲先の会話がターンを終えた"
    public static let delegateAskHead = mark + "委譲先の会話が回答を待っている"
    public static let linkPrefix = mark + "タスク #"
    public static let linkMarker = "のリンク先の PR・issue に動きがあった"
    public static let answerPrefix = "taskboard で質問に答えました（#"
    public static let reviewPrefix = "taskboard でレビューしました（#"
    public static let finishedPrefix = "taskboard で手作業を済ませました（#"
    public static let draftPrefix = "taskboard で送る文面を承認しました（#"
    public static let feedbackTooLong = "taskboard に回答・レビューが届いていますが、長くてここに入りません。feedback_list で取ってください。"
    public static let limitResumeText = "利用枠が戻ったので、止まったところから続けてください。"
    /// 会話に入れる利用枠の続き（印と `limitResumeText`）
    public static let limitResumePrompt = marked(.limitResume, limitResumeText)
    public static let networkResumeText = "ネットワークの接続が戻ったので、止まったところから続けてください。"
    /// 会話に入れるネットワークの続き（印と `networkResumeText`）
    public static let networkResumePrompt = marked(.networkResume, networkResumeText)
    public static let sessionPromptHead = mark + "別のセッションからの発言"
    /// 別のセッションが送った文の前の行
    public static let bodyHeading = "本文:"
    public static let slackHead = mark + "Slack から依頼が届いた"
    /// Slack の依頼の発言の前の行
    public static let slackRequestHeading = "依頼:"
    public static let wakePrefix = mark + "予定 #"
    public static let wakeMarker = "の時刻になった"
    public static let watchPrefix = mark + "監視 #"
    public static let watchMarker = "に動きがあった"

    /// 本文より前に置く項目。会話に入った文が、人の発言でも承認でもないことを示す
    public static let senderItem = "- 送り主: taskboard の自動の通知。人の発言でも承認でもない"
    /// GitHub の本文を載せない通知に入れる項目
    public static let githubBodyItem = "- 本文: 載せていない（外部の人が書いた文のため）。URL を開いて読む"
    /// 本文の前の行（委譲先の返事・予定と監視の作成時の指示）
    public static let replyHeading = "最後の返事:"
    public static let promptHeading = "作成時の指示:"

    // 前の版の daemon が入れた通知の頭。会話の履歴に残るので見分け続ける
    static let legacyDelegatePrefix = "taskboard: 委譲先の会話 "
    static let legacyLinkPrefix = "taskboard: タスク #"
    static let legacyLinkMarker = "にリンクした PR・issue に動きがありました"
    static let legacyWakePrefix = "taskboard: 予定 #"
    static let legacyWakeMarker = "の時刻になったので起こした"
    static let legacyWatchPrefix = "taskboard: 見張り #"
    static let legacyWatchMarker = "に動きがありました"

    /// 1 行目の印。種類と、空白を含まない値の組（`key=value`）を運ぶ。HTML のコメントなので Markdown では見えない
    public static func marker(_ kind: TaskboardNotice, _ attributes: KeyValuePairs<String, String> = [:]) -> String {
        let pairs = attributes.map { ($0.key, $0.value.filter { !$0.isWhitespace && $0 != ">" }) }.filter { !$0.1.isEmpty }.map { " \($0)=\($1)" }.joined()
        return "<!-- taskboard: \(kind.rawValue)\(pairs) -->"
    }

    /// 印を付けた文（印の行、改行、残り）
    public static func marked(_ kind: TaskboardNotice, _ text: String) -> String {
        marker(kind) + "\n" + text
    }

    /// 1 行目が印なら、種類の名前と値の組。種類の名前は知らないもの（新しい daemon の種類）でも返す
    public static func parseMarker(_ text: String) -> (kind: String, attributes: [String: String])? {
        let line = text.prefix { $0 != "\n" }
        guard let match = line.wholeMatch(of: #/<!-- taskboard: ([a-z_]+)((?: [A-Za-z_]+=[^\s>]*)*) -->/#) else { return nil }
        var attributes: [String: String] = [:]
        for pair in match.2.split(separator: " ") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            attributes[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
        }
        return (String(match.1), attributes)
    }

    /// 1 行目の印を外した文。印が無ければそのまま
    public static func stripMarker(_ text: String) -> String {
        guard parseMarker(text) != nil else { return text }
        return String(text.drop { $0 != "\n" }.dropFirst())
    }

    public init?(text: String) {
        if let marker = Self.parseMarker(text) {
            guard let kind = TaskboardNotice(rawValue: marker.kind) else { return nil }
            self = kind
            return
        }
        let firstLine = text.prefix { $0 != "\n" }
        if firstLine == Self.delegateTurnHead || firstLine == Self.delegateAskHead || text.hasPrefix(Self.legacyDelegatePrefix) {
            self = .delegate
        } else if Self.matches(firstLine, prefix: Self.linkPrefix, marker: Self.linkMarker)
            || Self.matches(firstLine, prefix: Self.legacyLinkPrefix, marker: Self.legacyLinkMarker)
        {
            self = .link
        } else if text.hasPrefix(Self.answerPrefix) || text == Self.feedbackTooLong {
            self = .answer
        } else if text.hasPrefix(Self.reviewPrefix) {
            self = .review
        } else if text.hasPrefix(Self.finishedPrefix) {
            self = .finished
        } else if text == Self.limitResumeText {
            self = .limitResume
        } else if Self.matches(firstLine, prefix: Self.wakePrefix, marker: Self.wakeMarker)
            || Self.matches(firstLine, prefix: Self.legacyWakePrefix, marker: Self.legacyWakeMarker)
        {
            self = .wake
        } else if Self.matches(firstLine, prefix: Self.watchPrefix, marker: Self.watchMarker)
            || Self.matches(firstLine, prefix: Self.legacyWatchPrefix, marker: Self.legacyWatchMarker)
        {
            self = .watch
        } else {
            return nil
        }
    }

    private static func matches(_ firstLine: Substring, prefix: String, marker: String) -> Bool {
        firstLine.hasPrefix(prefix) && firstLine.contains(marker)
    }
}

extension ChatMessage {
    /// taskboard が人の発言として入れた知らせ（画面で人の吹き出しと別の見た目にする）。人の発言でなければ nil
    public var taskboardNotice: TaskboardNotice? {
        isHumanPrompt ? TaskboardNotice(text: text) : nil
    }
}
