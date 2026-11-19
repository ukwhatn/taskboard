import Foundation

/// `POST /v1/dictation/polish` の本文。音声入力で文字にした文と、校正に使う会話の文脈
public struct DictationPolishRequest: Codable, Hashable, Sendable {
    public static let textLimit = 4000
    public static let recentLimit = 12
    public static let recentLength = 600

    public var text: String
    public var taskTitle: String?
    public var taskNumber: Int?
    /// 会話の最近の発言（古い順）
    public var recent: [String]
    /// 会話に出た語（`DictationVocabulary.phrases`）
    public var vocabulary: [String]

    public init(text: String, taskTitle: String? = nil, taskNumber: Int? = nil, recent: [String] = [], vocabulary: [String] = []) {
        self.text = text
        self.taskTitle = taskTitle
        self.taskNumber = taskNumber
        self.recent = recent
        self.vocabulary = vocabulary
    }

    /// 会話の発言から組む。人とアシスタントの文だけを、新しいものから `recentLimit` 件まで、1 件 `recentLength` 字までにして古い順に並べる
    public init(text: String, taskTitle: String?, taskNumber: Int?, messages: [ChatMessage]) {
        let recent = messages.reversed().lazy.filter { $0.kind == .text && !$0.isThinking && !$0.text.isEmpty }.prefix(Self.recentLimit)
            .map { String($0.text.prefix(Self.recentLength)) }
        self.init(
            text: text, taskTitle: taskTitle, taskNumber: taskNumber, recent: Array(recent.reversed()),
            vocabulary: DictationVocabulary.phrases(taskTitle: taskTitle, taskNumber: taskNumber, messages: messages))
    }

    /// 上限を超えていれば理由。daemon が受けたときに確かめる
    public var violation: String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "textが空" }
        if text.count > Self.textLimit { return "textは\(Self.textLimit)字まで" }
        if recent.count > Self.recentLimit || recent.contains(where: { $0.count > Self.recentLength }) {
            return "recentは\(Self.recentLimit)件・1件\(Self.recentLength)字まで"
        }
        if vocabulary.count > DictationVocabulary.limit { return "vocabularyは\(DictationVocabulary.limit)語まで" }
        return nil
    }
}

public struct DictationPolishResponse: Codable, Hashable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

/// 音声入力の校正を daemon に頼める供給元。本番は `DaemonClient`（fixtures は持たないので校正しない）
public protocol DictationSource: Sendable {
    func polishDictation(_ body: DictationPolishRequest) async throws -> DictationPolishResponse
}

extension DaemonClient: DictationSource {
    public func polishDictation(_ body: DictationPolishRequest) async throws -> DictationPolishResponse {
        try await send("POST", "/v1/dictation/polish", body)
    }
}
