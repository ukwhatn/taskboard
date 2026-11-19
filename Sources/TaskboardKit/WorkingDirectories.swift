import Foundation

/// `GET /v1/workdirs`。そのマシンのブックマークと、最近使った作業ディレクトリ（タスクに結んだ会話の cwd）
public struct WorkingDirectories: Codable, Hashable, Sendable {
    public var bookmarks: [WorkdirBookmark]
    public var recent: [String]

    public init(bookmarks: [WorkdirBookmark], recent: [String]) {
        self.bookmarks = bookmarks
        self.recent = recent
    }

    /// 候補の並び（ブックマークが先、最近使ったものはブックマークと重ならない分）
    public var candidates: [String] {
        let marked = bookmarks.map(\.path)
        return marked + recent.filter { !marked.contains($0) }
    }

    public func isBookmarked(_ path: String) -> Bool { bookmarks.contains { $0.path == path } }

    /// 作業ディレクトリの欄に打っている間の候補。打った文字を含む候補（`candidates`）が先、続けて `completions`（`GET /v1/workdirs/complete` の答え）
    public func suggestions(for typed: String, completions: [String]) -> [String] {
        guard !typed.isEmpty else { return [] }
        let known = candidates.filter { $0 != typed && $0.localizedCaseInsensitiveContains(typed) }
        return Array((known + completions.filter { $0 != typed && !known.contains($0) }).prefix(20))
    }
}

/// `POST /v1/workdirs/bookmarks`。`path` はそのマシンのパス（`~` は daemon が展開する）
public struct WorkdirBookmark: Codable, Hashable, Identifiable, Sendable {
    public var id: Int64
    public var path: String
    public var createdAt: Date

    public init(id: Int64, path: String, createdAt: Date) {
        self.id = id
        self.path = path
        self.createdAt = createdAt
    }
}

public struct WorkdirBookmarkRequest: Codable, Hashable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}
