import Foundation
import TaskboardKit

/// 会話の作業ディレクトリのファイルの一覧と、`@` の候補の引き方。一覧は `@` を打ったときに作り（監視はしない）、
/// 作業ディレクトリごとに短い時間だけ控えて、打つたびに git を起こさない。同じ作業ディレクトリへの続けての要求は、走っている 1 本にまとめる。
/// git の repo なら `git ls-files`（追跡中と追跡していない・無視されていないもの）、そうでなければディレクトリを歩く。
/// 件数・出力の大きさ・時間に上限があり、達したらそこまでの分を返して打ち切ったことを知らせる。
/// 歩く・並べ替える重い処理は専用のキューで回し、actor と協調プールを握ったまま待たない（ほかの要求を待たせない）。
/// 引くのは作業ディレクトリの中だけで、リクエストが渡すのは打った文字だけ（パスは受けない）
actor WorkFileIndex {
    struct Limits: Sendable {
        /// 一覧に載せるファイルの数
        var files = 100_000
        /// git が返す出力の大きさ
        var gitOutput = 16 << 20
        /// 歩くときの深さ・ファイルの数・時間
        var walkDepth = 8
        var walkFiles = 20_000
        var walkTime: TimeInterval = 2
        /// 一覧を控える時間と、控える作業ディレクトリの数
        var lifetime: TimeInterval = 10
        var cached = 6
    }

    /// 歩くときに入らない名前（依存・ビルドの置き場）。git の repo は無視の設定に従うので使わない
    static let skippedNames: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".venv", "venv", "__pycache__", "Pods", ".next", ".gradle", "target"]

    /// 一覧と、上限で打ち切ったか
    struct Listing: Sendable {
        var entries: [WorkFileMatcher.Entry]
        var truncated: Bool
    }

    private struct Cached {
        var at: Date
        var listing: Listing
    }

    private static let queue = DispatchQueue(label: "taskboard.workfiles", qos: .userInitiated, attributes: .concurrent)

    /// 重い処理を専用のキューで回す（協調プールのスレッドを塞がない）
    private static func offload<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private let limits: Limits
    private let now: @Sendable () -> Date
    private var listings: [String: Cached] = [:]
    private var loading: [String: Task<Listing, Never>] = [:]

    init(limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.limits = limits
        self.now = now
    }

    /// `cwd` のファイルとフォルダから、`query` に合うものを `limit` 件まで。作業ディレクトリが無ければ空。`truncated` は一覧が上限で切れていたこと
    func search(cwd: String, query: String, limit: Int) async -> (files: [WorkFile], truncated: Bool) {
        let listing = await listing(cwd: cwd)
        // 並べ替えは 10 万件に及ぶので、actor の外で回す。一覧は控えなので、消えたものは返す前に外す（多めに引いて補う）
        let files = await Self.offload {
            var found: [WorkFile] = []
            let root = URL(fileURLWithPath: cwd, isDirectory: true)
            for file in WorkFileMatcher.rank(query, in: listing.entries, limit: limit * 3) {
                guard FileManager.default.fileExists(atPath: root.appending(path: file.path).path) else { continue }
                found.append(file)
                if found.count == limit { break }
            }
            return found
        }
        return (files, listing.truncated)
    }

    private func listing(cwd: String) async -> Listing {
        if let cached = listings[cwd], now().timeIntervalSince(cached.at) < limits.lifetime { return cached.listing }
        if let running = loading[cwd] { return await running.value }
        let limits = limits
        let task = Task.detached { await Self.list(cwd: cwd, limits: limits) }
        loading[cwd] = task
        let listing = await task.value
        loading[cwd] = nil
        listings[cwd] = Cached(at: now(), listing: listing)
        if listings.count > limits.cached, let oldest = listings.min(by: { $0.value.at < $1.value.at })?.key { listings[oldest] = nil }
        return listing
    }

    // MARK: 一覧の作り方

    static func list(cwd: String, limits: Limits) async -> Listing {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return Listing(entries: [], truncated: false) }
        let git = await gitPaths(cwd: cwd, limits: limits)
        return await offload {
            let (paths, truncated) = git ?? walk(cwd: cwd, limits: limits)
            return Listing(entries: entries(of: paths), truncated: truncated)
        }
    }

    /// ファイルのパスに、その親のフォルダを足した一覧
    static func entries(of paths: [String]) -> [WorkFileMatcher.Entry] {
        var folders = Set<String>()
        for path in paths {
            var slash = path.startIndex
            while let found = path[slash...].firstIndex(of: "/") {
                folders.insert(String(path[...found]))
                slash = path.index(after: found)
            }
        }
        return paths.map { WorkFileMatcher.Entry(WorkFile(path: $0, isDirectory: false)) }
            + folders.map { WorkFileMatcher.Entry(WorkFile(path: $0, isDirectory: true)) }
    }

    /// git の repo でなければ nil。作業ディレクトリが repo の中の 1 フォルダなら、その下だけ。出力・件数の上限で切れたら truncated
    private static func gitPaths(cwd: String, limits: Limits) async -> (paths: [String], truncated: Bool)? {
        guard let outcome = try? await GitCommand.run(cwd, ["ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z"], limit: limits.gitOutput),
            !outcome.timedOut, outcome.status == 0 || outcome.overflowed
        else { return nil }
        var data = outcome.stdout
        // 出力が上限で切れたら、最後の途中のパスを捨てる
        if outcome.overflowed, let last = data.lastIndex(of: 0) { data = data[...last] }
        var paths: [String] = []
        var truncated = outcome.overflowed
        for field in data.split(separator: 0, omittingEmptySubsequences: true) {
            if paths.count >= limits.files {
                truncated = true
                break
            }
            paths.append(String(decoding: field, as: UTF8.self))
        }
        return (paths, truncated)
    }

    /// 深さ・数・時間の上限まで歩く（どれかで切れたら truncated）。シンボリックリンクはたどらない
    private static func walk(cwd: String, limits: Limits) -> (paths: [String], truncated: Bool) {
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return ([], false) }
        let deadline = Date().addingTimeInterval(limits.walkTime)
        let prefix = root.standardizedFileURL.path + "/"
        var paths: [String] = []
        var truncated = false
        for case let url as URL in enumerator {
            if paths.count >= min(limits.walkFiles, limits.files) || Date() > deadline {
                truncated = true
                break
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true
            if isFolder, skippedNames.contains(url.lastPathComponent) || enumerator.level >= limits.walkDepth {
                enumerator.skipDescendants()
                if skippedNames.contains(url.lastPathComponent) { continue }
                truncated = true
            }
            if values?.isSymbolicLink == true { enumerator.skipDescendants() }
            guard !isFolder else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
        }
        return (paths, truncated)
    }
}
