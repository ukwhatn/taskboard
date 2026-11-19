import Foundation

// MARK: - 使っていない worktree の一覧と削除（`GET /v1/worktrees`・`POST /v1/worktrees/remove`）

/// worktree を使っているセッション。終了していない会話（`pane` は前の版の daemon が送る種類）
public struct WorktreeUser: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pane
        case conversation
    }

    public var kind: Kind
    /// pane は pane ID、会話は会話の id
    public var id: String
    public var title: String?

    public init(kind: Kind, id: String, title: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
    }
}

/// 消せない理由 1 つ。`count` は個数があるもの（変更のあるファイル・コミットの数・使っているセッションの数）
public struct WorktreeBlocker: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// repo の本体の checkout（`git worktree list` の先頭）
        case main
        case locked
        /// 終了していない会話がその下で動いている
        case inUse
        /// 追跡しているファイルに未コミットの変更がある
        case uncommitted
        case untracked
        /// どの remote にも無いコミットがある
        case unpushed
        /// 比べ先に入っていないコミットがある
        case unmerged
        /// 比べ先が決まらない
        case noBase
        /// ブランチが無い（detached HEAD）
        case noBranch
        /// ディレクトリが無い
        case missing
        /// 新しい daemon が足した理由（古いアプリは文を持たない）
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var kind: Kind
    public var count: Int?

    public init(_ kind: Kind, count: Int? = nil) {
        self.kind = kind
        self.count = count
    }
}

public struct WorktreeInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }

    public var path: String
    /// repo の本体の checkout のパス
    public var repo: String
    public var branch: String?
    /// 未マージを比べるブランチ（`origin/develop` など。決まらなければ nil）
    public var base: String?
    public var users: [WorktreeUser]
    /// 空なら消せる
    public var blockers: [WorktreeBlocker]
    /// 前の版のアプリが必須の項目として読むので残す。daemon は常に false を入れる
    public var hasWorkspace: Bool

    public var removable: Bool { blockers.isEmpty }

    public init(
        path: String, repo: String, branch: String? = nil, base: String? = nil, users: [WorktreeUser] = [], blockers: [WorktreeBlocker] = [],
        hasWorkspace: Bool = false
    ) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.base = base
        self.users = users
        self.blockers = blockers
        self.hasWorkspace = hasWorkspace
    }
}

public struct WorktreeListResponse: Codable, Hashable, Sendable {
    public var worktrees: [WorktreeInfo]

    public init(worktrees: [WorktreeInfo]) {
        self.worktrees = worktrees
    }
}

public struct WorktreeRemoveRequest: Codable, Hashable, Sendable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

public struct WorktreeRemoveResult: Codable, Hashable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// worktree を消した（ブランチが残ったときは `branchDeleted` が false で `message` に git の文）
        case removed
        /// 消せない理由があったので何も消していない（`blockers`）
        case refused
        /// 消そうとして git が失敗した（`message` はその文）
        case failed
    }

    public var id: String { path }

    public var path: String
    public var outcome: Outcome
    public var blockers: [WorktreeBlocker]
    public var branch: String?
    public var branchDeleted: Bool
    public var message: String?

    public init(
        path: String, outcome: Outcome, blockers: [WorktreeBlocker] = [], branch: String? = nil, branchDeleted: Bool = false, message: String? = nil
    ) {
        self.path = path
        self.outcome = outcome
        self.blockers = blockers
        self.branch = branch
        self.branchDeleted = branchDeleted
        self.message = message
    }
}

public struct WorktreeRemoveResponse: Codable, Hashable, Sendable {
    public var results: [WorktreeRemoveResult]

    public init(results: [WorktreeRemoveResult]) {
        self.results = results
    }
}
