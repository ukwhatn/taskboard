import SwiftUI
import TaskboardKit

/// 会話の中の、ツールが読んだ・書いた 1 つのファイル（札とファイルの欄が指すもの）
struct ChatFileRef: Hashable, Identifiable {
    /// ツールの呼び出しの id（中身の口の `tool_id`）
    let toolID: String
    /// 呼び出したツール（Read・Write・Edit・Bash）。分からなければ nil
    let toolName: String?
    let file: ChatFile

    /// Bash は 1 回で複数のファイルを変えるので、パスまで含めて 1 つ
    var id: String { "\(toolID)|\(file.path ?? "")" }

    /// パスの末尾。画像の Read でパスが分からなければ「画像」
    var name: String {
        guard let path = file.path, !path.isEmpty else { return String(localized: "画像") }
        return (path as NSString).lastPathComponent
    }

    /// 末尾の手前のディレクトリ（札では薄く出す）。ホームは `~` にする
    var directory: String? {
        guard let path = file.path, path.contains("/") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
    }

    /// 変える前の全文を取れるか（diff の畳んだ行を開ける）。Bash の bashEditDiff には無い
    var hasOriginal: Bool { file.action == .edited && toolName != "Bash" }

    var symbol: String {
        switch file.action {
        case .read: "doc.text"
        case .created: "doc.badge.plus"
        case .edited: "pencil"
        case .image: "photo"
        }
    }

    /// 札と一覧の右に出す要約の読み上げ（記号の +・− を日本語にする）
    var summaryLabel: String {
        switch file.action {
        case .read: String(localized: "読み取り済み")
        case .created: String(localized: "ファイルを追加、\(file.added)行")
        case .edited: String(localized: "\(file.added)行追加、\(file.removed)行削除")
        case .image:
            [String(localized: "画像"), file.bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }].compactMap { $0 }
                .joined(separator: "、")
        }
    }

    /// 結果の行（`toolResult`）のファイル。画像の Read で結果にパスが無ければ、呼び出しの要約（file_path）を使う
    static func refs(call: ChatMessage?, result: ChatMessage?) -> [ChatFileRef] {
        guard let result, let toolID = result.toolID, let files = result.files else { return [] }
        return files.map { file in
            var file = file
            if file.path == nil, call?.toolName == "Read", let path = call?.text, path.hasPrefix("/") { file.path = path }
            return ChatFileRef(toolID: toolID, toolName: call?.toolName, file: file)
        }
    }
}

/// この会話で触ったファイルの一覧（ファイルの欄の上）。daemon に一覧の口は無く、`ChatFeed.messages` のファイルの情報だけから作る
enum ChatFileIndex {
    struct Entry: Hashable, Identifiable {
        let path: String
        /// 最後に触った 1 回
        var latest: ChatFileRef
        /// 最後に変えた 1 回（Write・Edit・Bash）
        var change: ChatFileRef?
        /// Write・Edit・Bash の累計
        var added = 0
        var removed = 0

        var id: String { path }
        /// 押したときに開くもの。変えたことがあれば最新の diff
        var shown: ChatFileRef { change ?? latest }
    }

    /// 最後に触った順（新しいものが先）。パスの分からないもの（呼び出しの見えない画像）は入れない
    static func entries(in messages: [ChatMessage]) -> [Entry] {
        let calls = Dictionary(messages.filter { $0.kind == .toolUse && $0.toolID != nil }.map { ($0.toolID!, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [String: Entry] = [:]
        var touched: [String: Int] = [:]
        for (index, message) in messages.enumerated() where message.kind == .toolResult && message.files != nil {
            for ref in ChatFileRef.refs(call: message.toolID.flatMap { calls[$0] }, result: message) {
                guard let path = ref.file.path else { continue }
                var entry = entries[path] ?? Entry(path: path, latest: ref)
                entry.latest = ref
                if ref.file.action == .created || ref.file.action == .edited {
                    entry.change = ref
                    entry.added += ref.file.added
                    entry.removed += ref.file.removed
                }
                entries[path] = entry
                touched[path] = index
            }
        }
        return entries.values.sorted { (touched[$0.path] ?? 0, $0.path) > (touched[$1.path] ?? 0, $1.path) }
    }
}

/// ファイルの欄に出す中身を、会話ごとに最近の `limit` 件まで持つ（`ChatFeed.files`）。
/// 中身は transcript に記録された時点のもので変わらないので、取れたものは取り直さない
@MainActor
@Observable
final class ChatFileStore {
    enum Load: Equatable {
        case loading
        case loaded(ChatFileContent)
        case failed(UserFacingError)
    }

    struct Key: Hashable {
        let id: String
        let part: ChatFile.Part
    }

    static let limit = 20

    private(set) var entries: [Key: Load] = [:]
    @ObservationIgnored private var order: [Key] = []

    func state(_ ref: ChatFileRef, _ part: ChatFile.Part = .content) -> Load? {
        entries[Key(id: ref.id, part: part)]
    }

    /// 中身を取る口
    typealias Fetch = @Sendable (_ toolID: String, _ file: ChatFile, _ part: ChatFile.Part) async throws -> ChatFileContent

    /// 取れていれば何もしない。`fetch` が無ければ（表示用のデータ）`fixtures` から引く
    func load(_ ref: ChatFileRef, part: ChatFile.Part = .content, fetch: Fetch?, fixtures: [String: ChatFileContent] = [:]) async {
        var content: Content?
        if let fetch { content = { try await fetch(ref.toolID, ref.file, part) } }
        await load(Key(id: ref.id, part: part), fixture: Self.fixture(ref, part: part, in: fixtures), event: "ファイルを表示できませんでした", fetch: content)
    }

    /// snapshot test と表示用のデータで、取った後の形を置く
    func preset(_ ref: ChatFileRef, part: ChatFile.Part = .content, _ load: Load) {
        set(Key(id: ref.id, part: part), load)
    }

    // MARK: 人の発言の画像

    /// 人の発言の画像を取る口。行の uuid と、行の中の画像
    typealias ImageFetch = @Sendable (_ lineID: String, _ image: ChatImage) async throws -> Data

    /// 吹き出しに並べる縮小版（`ChatSentImageRef.id` が鍵）。中身と一緒に追い出す
    private(set) var thumbnails: [String: CGImage] = [:]

    func state(_ ref: ChatSentImageRef) -> Load? {
        entries[Key(id: ref.id, part: .content)]
    }

    /// 縮小版は主スレッドの外で作る（貼った画像は数 MB ある）。fixtures の鍵は `ChatSentImageRef.id`
    func load(_ ref: ChatSentImageRef, fetch: ImageFetch?, fixtures: [String: ChatFileContent] = [:]) async {
        var content: Content?
        if let fetch { content = { .image(try await fetch(ref.lineID, ref.image)) } }
        await load(Key(id: ref.id, part: .content), fixture: fixtures[ref.id], event: "画像を表示できませんでした", fetch: content)
        if case .loaded(.image(let data)) = state(ref), thumbnails[ref.id] == nil {
            thumbnails[ref.id] = await Task.detached { ChatSentImageRef.thumbnail(data) }.value
        }
    }

    func preset(_ ref: ChatSentImageRef, _ load: Load) {
        set(Key(id: ref.id, part: .content), load)
        if case .loaded(.image(let data)) = load { thumbnails[ref.id] = ChatSentImageRef.thumbnail(data) }
    }

    private typealias Content = @Sendable () async throws -> ChatFileContent

    private func load(_ key: Key, fixture: ChatFileContent?, event: LocalizedStringResource, fetch: Content?) async {
        if let current = entries[key] {
            guard case .failed = current else { return }
        }
        set(key, .loading)
        do {
            let content: ChatFileContent
            if let fetch {
                content = try await fetch()
            } else if let fixture {
                content = fixture
            } else {
                throw AppModel.ActionError.notWritable(.readOnly)
            }
            set(key, .loaded(content))
        } catch {
            if let failure = UserFacingError(event, error: error) {
                set(key, .failed(failure))
            } else {
                entries[key] = nil
            }
        }
    }

    /// fixtures の `chatFiles` の鍵: `{tool_id}`、Bash の 2 つめ以降は `{tool_id}|{path}`、変える前の全文は後ろに `#original`
    static func fixture(_ ref: ChatFileRef, part: ChatFile.Part, in fixtures: [String: ChatFileContent]) -> ChatFileContent? {
        let suffix = part == .original ? "#original" : ""
        return fixtures["\(ref.toolID)|\(ref.file.path ?? "")\(suffix)"] ?? fixtures["\(ref.toolID)\(suffix)"]
    }

    private func set(_ key: Key, _ load: Load) {
        entries[key] = load
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.limit {
            let evicted = order.removeFirst()
            entries[evicted] = nil
            thumbnails[evicted.id] = nil
        }
    }
}

/// ファイルの欄が読む口
extension ConversationFeed {
    func loadFile(_ ref: ChatFileRef, part: ChatFile.Part = .content, fixtures: [String: ChatFileContent]) async {
        await files.load(ref, part: part, fetch: fileFetch, fixtures: fixtures)
    }

    /// 中身を取る口。nil なら表示用のデータ（`FixtureExtras.chatFiles` から引く）
    var fileFetch: ChatFileStore.Fetch? {
        guard let source else { return nil }
        let id = key.id
        return { toolID, file, part in try await source.conversationFile(id, toolID: toolID, file: file, part: part) }
    }

    /// 人の発言の画像を取る口。nil なら表示用のデータ
    var imageFetch: ChatFileStore.ImageFetch? {
        guard let source else { return nil }
        let id = key.id
        return { lineID, image in try await source.conversationImage(id, lineID: lineID, image: image) }
    }

    /// Edit・Write の変える前の全文を取れるか（codex の会話は transcript が無く、札の diff だけを持つ）
    func keepsOriginals(in model: AppModel) -> Bool { model.fleet.conversation(for: key)?.engine != .codex }
}
