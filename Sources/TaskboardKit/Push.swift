import Foundation

// MARK: - 通知の種類と中身（daemon の APNs とアプリのローカル通知で同じものを使う）

/// 通知の種類（47 §5「承認待ち・質問・CI 失敗・レビュー依頼・定期起動の失敗」）。通知の設定に並ぶ
public enum NotifyKind: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case approval, question, ciFailed, review, schedule

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .approval: String(localized: "応答待ち・承認待ち")
        case .question: String(localized: "質問・手作業の依頼")
        case .ciFailed: String(localized: "CIの失敗")
        case .review: String(localized: "レビュー")
        case .schedule: String(localized: "定期起動の失敗")
        }
    }

    public var detail: String? {
        switch self {
        case .review: String(localized: "レビュー依頼・修正依頼・承認済み")
        default: nil
        }
    }

    private static func of(_ kind: PRNotice.Kind) -> NotifyKind? {
        switch kind {
        case .ciFailed: .ciFailed
        case .approved, .changesRequested, .reviewRequested: .review
        case .ciPassed, .newReview: nil
        }
    }

    /// 受信箱の項目がどの種類か。どれにも当たらない項目（PR を取得できないなど）は種類で止めない
    public static func of(_ item: InboxItem) -> NotifyKind? {
        switch item.kind {
        case .conversationRequest: .approval
        case .question, .manualWork, .panelDraft, .docDraft: .question
        case .reviewRequest: .review
        case .pullRequest(let notice): of(notice.kind)
        case .pullRequestTurn(_, let reason): of(reason)
        case .scheduleRun: .schedule
        // 動いていないタスクは急ぎではないので、通知の設定にも並べず鳴らさない
        case .document, .prSync, .orchestratorReply, .stalled: nil
        }
    }
}

extension InboxItem.Kind {
    /// 種別の名前。受信箱の行の 1 行目と、通知の題に出す（docs/ui-copy.md の用語表）
    public var label: String {
        switch self {
        case .question: String(localized: "質問")
        case .reviewRequest: String(localized: "文書のレビュー依頼")
        case .manualWork: String(localized: "手作業の依頼")
        case .conversationRequest: String(localized: "応答待ち")
        case .document: String(localized: "文書")
        case .pullRequest(let notice): notice.kind.label
        case .pullRequestTurn(_, let reason): reason.label
        case .prSync: String(localized: "PRの取得の失敗")
        case .scheduleRun: String(localized: "定期起動")
        case .orchestratorReply: String(localized: "オーケストレーターの応答")
        case .stalled: String(localized: "更新のないタスク")
        case .panelDraft, .docDraft: String(localized: "送る文面")
        }
    }
}

extension PRNotice.Kind {
    public var label: String {
        switch self {
        case .ciFailed: String(localized: "CI失敗")
        case .ciPassed: String(localized: "CI成功")
        case .approved: String(localized: "承認済み")
        case .changesRequested: String(localized: "修正依頼")
        case .newReview: String(localized: "レビュー")
        case .reviewRequested: String(localized: "PRのレビュー依頼")
        }
    }
}

/// 受信箱の項目から作る通知の中身。題・補足・本文と、押したときの行き先（受信箱の行と同じ所）
public struct InboxNotification: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var body: String
    /// 押したとき、受信箱にこの行が残っていれば行を押したのと同じ所へ移る（アプリの `AppModel.openNotification`）
    public var itemID: String
    /// 行が消えていたときの行き先
    public var url: URL
    /// 通知の束ね（タスクごと。タスクの無い項目はマシンごと）
    public var threadID: String
    /// 同じ通知を端末の上で 1 つにまとめる鍵（APNs の `apns-collapse-id` の元）。同じ PR を 2 台が持つことがあるので、PR はマシンを含めない
    public var collapseKey: String
    /// 権限の確認の応答待ちなら、その確認。通知に「許可」「拒否」を付ける
    public var permission: PermissionPrompt?
    /// host の会話の権限の確認に、通知から選べる「今後は聞かない」候補があれば、その候補。通知に［常に許可］を付ける
    public var alwaysAllow: PermissionSuggestion?
    /// ターンの完了の通知（`TurnWatch`）。設定が「アプリを使っていないときだけ」なら、前面の端末で出さない
    public var turn = false

    /// 鳴らす項目なら中身、鳴らさない項目は nil。鳴らすのは通知の設定に並ぶ種類（`NotifyKind`）に当たる項目だけ。
    /// 定期起動は、失敗した回だけを鳴らす（成功した回も同じ種類に当たるので、ここでは外す）。
    /// 会話の問いは、本文の 2 行目に権限の確認の中身か AskUserQuestion の最初の問いを出す
    public static func make(_ item: InboxItem, machineName: String) -> InboxNotification? {
        guard NotifyKind.of(item) != nil else { return nil }
        if case .scheduleRun(_, let run) = item.kind, run.outcome != .failed { return nil }
        var prompt: PermissionPrompt?
        var always: PermissionSuggestion?
        var question: String?
        if case .conversationRequest(_, let request) = item.kind {
            prompt = request.waiting.permissionPrompt
            if prompt != nil { always = request.alwaysSuggestion }
            question = request.waiting.questions?.first?.question
        }
        let collapseKey: String
        switch item.kind {
        case .pullRequest, .pullRequestTurn: collapseKey = item.localID
        default: collapseKey = item.id
        }
        return InboxNotification(
            title: item.kind.label,
            subtitle: [machineName.isEmpty ? nil : machineName, item.taskKey.map { "#\($0.number)" }].compactMap { $0 }.joined(separator: "・"),
            body: [
                item.title, prompt.map { [$0.tool, $0.summary].filter { !$0.isEmpty }.joined(separator: "：") } ?? question,
                always.map { String(localized: "常に許可：\($0.subject)（\($0.scope.phrase)）") },
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
            itemID: item.id, url: url(for: item), threadID: item.taskKey?.description ?? item.machine.rawValue, collapseKey: collapseKey,
            permission: prompt, alwaysAllow: always)
    }

    /// 行が消えていたときの行き先。質問と文書はその文書、会話の問いはその会話、PR はその PR、定期起動の実行は会話 → タスク、他はタスク
    public static func url(for item: InboxItem) -> URL {
        link(for: item).url
    }

    static func link(for item: InboxItem) -> TaskboardLink {
        switch item.kind {
        case .question(let ask): .task(TaskKey(machine: ask.machine, number: ask.taskNumber), doc: ask.docID)
        case .document(let doc), .docDraft(let doc, _): .task(TaskKey(machine: doc.machine, number: doc.taskNumber), doc: doc.docID)
        case .conversationRequest(let conversation, _): .conversation(conversation.key)
        case .pullRequest(let notice): .pullRequest(url: notice.url)
        case .pullRequestTurn(let pr, _): .pullRequest(url: pr.url)
        case .prSync: .unassigned(item.machine)
        case .scheduleRun(let schedule, let run): .scheduleRun(schedule, run, in: nil)
        case .orchestratorReply: .orchestrator(item.machine)
        case .reviewRequest, .manualWork, .stalled, .panelDraft: item.taskKey.map { .task($0) } ?? .boards
        }
    }
}

// MARK: - APNs の登録（iPhone・iPad のアプリ → daemon）

/// APNs の環境。開発の署名で入れたアプリのトークンは sandbox
public enum PushEnvironment: String, Codable, Hashable, Sendable, CaseIterable {
    case sandbox, production
}

/// `PUT /v1/devices/current/push`（端末の token だけ）。アプリを閉じていても届くように、APNs のトークンと通知の設定を daemon に預ける。
/// 同じ端末からもう一度送ると置き換える。daemon は端末の行（`device`）に持ち、端末を止めると一緒に消える
public struct PushRegistration: Codable, Hashable, Sendable {
    /// APNs の端末のトークン（hex）
    public var token: String
    public var environment: PushEnvironment
    /// `apns-topic`（アプリの bundle ID）
    public var topic: String
    /// 鳴らす種類。空なら送らない（1 台だけ表示で隠したマシン、通知を切った端末）
    public var kinds: [NotifyKind]
    /// ターンの完了の通知。nil は送らない（この欄を知らない版のアプリ）。古い daemon は読み飛ばす
    public var turns: TurnNotify?
    public var sound: Bool
    /// アプリがこの接続先に付けた名前。通知の補足に出す（daemon のコンピュータ名を出さない）
    public var machineName: String
    /// アプリの接続先の id。通知に載せて返し、押したときにどの接続先で応答するかを決める
    public var connection: String

    public init(
        token: String, environment: PushEnvironment, topic: String, kinds: [NotifyKind], turns: TurnNotify? = nil, sound: Bool, machineName: String,
        connection: String
    ) {
        self.token = token
        self.environment = environment
        self.topic = topic
        self.kinds = kinds
        self.turns = turns
        self.sound = sound
        self.machineName = machineName
        self.connection = connection
    }

    public static let machineNameLimit = 64
    public static let connectionLimit = 64
    public static let topicLimit = 255

    /// APNs の端末のトークンは 32〜100 バイト（hex で 64〜200 字）
    public static func isValidToken(_ token: String) -> Bool {
        (64...200).contains(token.count) && token.count.isMultiple(of: 2) && token.allSatisfy(\.isHexDigit)
    }
}

public struct PushRegistrationResponse: Codable, Hashable, Sendable {
    /// daemon に APNs の鍵があり、この端末に送る。false ならアプリはその接続先のローカル通知を止めない
    public var delivering: Bool
    /// ターンの完了（`PushRegistration.turns`）も送る daemon か。nil は送らない版。アプリはそのマシンのターンの完了をローカル通知で出し続ける
    public var turns: Bool?

    public init(delivering: Bool, turns: Bool? = nil) {
        self.delivering = delivering
        self.turns = turns
    }
}

/// APNs の通知に載せる値の名前（`aps` の外）と、通知の種類（category）・操作の id
public enum PushPayload {
    /// `InboxItem.id`。押したときに受信箱の行を開く
    public static let item = "item"
    /// 行が消えていたときの行き先（`InboxNotification.url`）
    public static let url = "url"
    /// 登録で受け取ったアプリの接続先の id
    public static let connection = "connection"
    public static let machine = "machine"
    /// 通知を出したときの確認（`PermissionPrompt.hash`）
    public static let promptHash = "promptHash"
    /// 答えを待っている host の会話と、その問いの id（「許可」「拒否」は `POST /v1/conversations/{id}/answers` で答える）
    public static let conversation = "conversation"
    public static let request = "request"

    /// 権限の確認の通知。「許可」「拒否」が付く
    public static let permissionCategory = "taskboard.permission"
    /// 権限の確認の通知に「今後は聞かない」候補（`suggestion`）があるとき。「許可」「拒否」に［常に許可］が付く
    public static let permissionAlwaysCategory = "taskboard.permission.always"
    public static let allowAction = "taskboard.allow"
    public static let denyAction = "taskboard.deny"
    public static let alwaysAllowAction = "taskboard.allow.always"
    /// ［常に許可］で選ぶ候補の id（`PermissionSuggestion.id`）
    public static let suggestion = "suggestion"
    /// ターンの完了の通知の印（値は "1"）。届いた端末が、前面のときに出すかを設定で決める
    public static let turn = "turn"
}

/// `POST /v1/push/test`（daemon の token だけ）。登録のある端末ごとの結果
public struct PushTestResult: Codable, Hashable, Sendable {
    public var deviceID: String
    public var deviceName: String
    /// APNs が返した HTTP status。送る前に止まったら nil
    public var status: Int?
    /// APNs の `reason`、または送れなかった理由（ログ・CLI 向けの文）
    public var reason: String?

    public init(deviceID: String, deviceName: String, status: Int?, reason: String?) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.status = status
        self.reason = reason
    }
}
