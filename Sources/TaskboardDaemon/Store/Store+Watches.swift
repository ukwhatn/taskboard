import Foundation
import GRDB
import TaskboardKit

/// GitHub の issue・PR の見張り（`watch`）と、そこで起きた出来事（`watchEvent`）。取るのは `GitHubSync`、届けるのは `WatchNotices`
extension Store {
    static let watchMigration = "v25 watches"
    static let watchTagMigration = "v26 watch tags"

    static func registerWatchMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration(watchMigration) { db in
            try db.create(table: "watch") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("url", .text)
                // repo の見張り（`repo`）の owner/name・host・検索語
                t.column("repo", .text)
                t.column("host", .text)
                t.column("query", .text)
                // 届ける `LinkNotice.Kind` の JSON の配列。空なら全部
                t.column("events", .text).notNull().defaults(to: "[]")
                // 会話の記録を消しても見張りは残す（届けるときに終える）
                t.column("conversationId", .text)
                t.column("taskNumber", .integer).references("task", onDelete: .cascade)
                t.column("prompt", .text)
                t.column("once", .boolean).notNull().defaults(to: false)
                t.column("expiresAt", .datetime)
                // 前の様子（item は `LinkSnapshot` の JSON）
                t.column("snapshot", .text)
                t.column("fetchedAt", .datetime)
                t.column("error", .text)
                t.column("state", .text).notNull()
                t.column("ending", .text)
                t.column("createdBy", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "watch_state_url", on: "watch", columns: ["state", "url"])
            try db.create(table: "watchEvent") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("watchId", .integer).notNull().references("watch", onDelete: .cascade)
                t.column("kind", .text).notNull()
                t.column("notice", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("deliveredAt", .datetime)
            }
            try db.create(index: "watchEvent_watch", on: "watchEvent", columns: ["watchId", "deliveredAt", "createdAt"])
        }
        migrator.registerMigration(watchTagMigration) { db in
            try db.alter(table: "watch") { t in
                // `tagged` で見るタグの名前の型（glob）と、タグを見た様子（`TagWatch.State` の JSON）
                t.add(column: "tagPattern", .text)
                t.add(column: "tagState", .text)
            }
        }
    }

    struct WatchRow: Codable, FetchableRecord, MutablePersistableRecord {
        static let databaseTableName = "watch"
        var id: Int64?
        var kind: String
        var url: String?
        var repo: String?
        var host: String?
        var query: String?
        var events: String
        var tagPattern: String?
        var tagState: String?
        /// `command` の `CommandWatchSpec` の JSON
        var command: String?
        var conversationId: String?
        var taskNumber: Int?
        var prompt: String?
        var once: Bool
        var expiresAt: Date?
        var snapshot: String?
        var fetchedAt: Date?
        var error: String?
        var state: String
        var ending: String?
        var createdBy: String?
        var createdAt: Date
        var updatedAt: Date

        mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

        var stateValue: Watch.State { Watch.State(rawValue: state) ?? .ended }
        var eventKinds: [LinkNotice.Kind] { (try? JSONDecoder().decode([LinkNotice.Kind].self, from: Data(events.utf8))) ?? [] }
        var snapshotValue: LinkSnapshot? { snapshot.flatMap { try? JSONDecoder().decode(LinkSnapshot.self, from: Data($0.utf8)) } }

        var tagStateValue: TagWatch.State? { tagState.flatMap { try? JSONDecoder().decode(TagWatch.State.self, from: Data($0.utf8)) } }

        var commandSpec: CommandWatchSpec? { command.flatMap { try? JSONDecoder().decode(CommandWatchSpec.self, from: Data($0.utf8)) } }

        /// `tagged` を届けるか（PR の見張りで、選んだか型を決めた。`events` が空でも、どちらも無ければ届けない）
        var wantsTag: Bool { kind == Watch.Kind.item.rawValue && (eventKinds.contains(.tagged) || tagPattern != nil) }

        func accepts(_ kind: LinkNotice.Kind) -> Bool {
            if kind == .tagged { return wantsTag }
            let kinds = eventKinds
            return kinds.isEmpty || kinds.contains(kind)
        }

        /// マージ・クローズした issue・PR を見張り終えてよいか。タグを待つ見張りは、マージした PR がタグに入るまで終えない
        func isFinished(_ snapshot: LinkSnapshot?) -> Bool {
            guard let snapshot, snapshot.isFinished else { return false }
            guard wantsTag, tagStateValue?.tag == nil, case .pullRequest(let pr) = snapshot else { return true }
            return pr.state != .merged
        }

        /// 配る欄が同じか（`fetchedAt`・`snapshot`・見たタグは取るたびに変わるので配らない）
        func sameShown(as other: WatchRow) -> Bool {
            state == other.state && ending == other.ending && error == other.error && conversationId == other.conversationId
                && tagStateValue?.tag == other.tagStateValue?.tag
        }

        /// repo の見張りの `owner/name`（github.com 以外は host を前に付ける）
        var repoLabel: String? {
            repo.map { host == nil || host == "github.com" ? $0 : "\(host ?? "")/\($0)" }
        }

        mutating func end(_ ending: Watch.Ending) {
            state = Watch.State.ended.rawValue
            self.ending = ending.rawValue
        }
    }

    /// 届ける出来事 1 つ
    struct WatchEventRecord: Hashable, Sendable {
        var id: Int64
        var watchID: Int64
        var notice: LinkNotice
        var createdAt: Date
    }

    func watch(from row: WatchRow) -> Watch {
        Watch(
            watchID: row.id ?? 0, machine: machineID, kind: Watch.Kind(rawValue: row.kind) ?? .item, url: row.url,
            repo: row.repoLabel, query: row.query, command: row.commandSpec,
            events: row.eventKinds, tagPattern: row.tagPattern, tag: row.tagStateValue?.tag, conversationID: row.conversationId, taskNumber: row.taskNumber, prompt: row.prompt, once: row.once,
            expiresAt: row.expiresAt, state: row.stateValue, ending: row.ending.flatMap(Watch.Ending.init(rawValue:)), error: row.error,
            fetchedAt: row.fetchedAt, createdBy: row.createdBy, createdAt: row.createdAt, updatedAt: row.updatedAt)
    }

    public func watches() throws -> [Watch] {
        try database.read { db in try WatchRow.order(Column("id")).fetchAll(db).map(watch(from:)) }
    }

    func watchRow(id: Int64) throws -> WatchRow? {
        try database.read { db in try WatchRow.fetchOne(db, key: id) }
    }

    public func watch(id: Int64) throws -> Watch? {
        try watchRow(id: id).map(watch(from:))
    }

    /// issue・PR の URL を `https://<host>/<owner>/<repo>/pull|issues/<番号>` にそろえる。GitHub の issue・PR でなければ nil
    static func watchURL(_ raw: String) -> (url: String, kind: TaskLink.Kind)? {
        let kind = TaskLink.kind(of: raw)
        guard kind == .githubPR || kind == .githubIssue, let parsed = URL(string: raw), let host = parsed.host()?.lowercased() else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == (kind == .githubPR ? "pull" : "issues"), let number = Int(parts[3]), number > 0 else { return nil }
        return ("https://\(host)/\(parts[0])/\(parts[1])/\(parts[2])/\(number)", kind)
    }

    /// repo を `(host, owner/name)` にそろえる。`owner/name`・`host/owner/name`・repo の URL を受ける
    static func watchRepo(_ raw: String) -> (host: String, repo: String)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var host = "github.com"
        var parts: [String]
        if text.contains("://") {
            guard let parsed = URL(string: text), let given = parsed.host()?.lowercased() else { return nil }
            host = given
            parts = Array(parsed.pathComponents.filter { $0 != "/" }.prefix(2))
        } else {
            if text.hasSuffix("/") { text.removeLast() }
            parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3 {
                host = parts[0].lowercased()
                parts.removeFirst()
            }
        }
        if let last = parts.last, last.hasSuffix(".git") { parts[parts.count - 1] = String(last.dropLast(4)) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count == 2, !host.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) } }) else {
            return nil
        }
        return (host, parts.joined(separator: "/"))
    }

    /// 見張りを書く。見張るのは url か repo の 1 つ、届け先は会話かタスクのどちらか 1 つで、在ること。
    /// 対象・届け先・種類が同じ有効な見張りがあれば、それを返す
    public func createWatch(_ request: WatchCreateRequest, now: Date = Date()) throws -> (watch: Watch, existing: Bool) {
        let givenURL = request.url?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let givenRepo = request.repo?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard [givenURL != nil, givenRepo != nil, request.command != nil].filter(\.self).count == 1 else {
            throw StoreError.invalid("url・repo・command のどれか 1 つを渡す")
        }
        var target = (kind: Watch.Kind.item, url: String?.none, repo: String?.none, host: String?.none, query: String?.none)
        var command: String?
        let tagPattern = request.tagPattern?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let tagPattern {
            guard tagPattern.count <= TagWatch.patternLimit, !tagPattern.contains(where: \.isNewline) else {
                throw StoreError.invalid("tag_pattern は 1 行・\(TagWatch.patternLimit) 字まで")
            }
            guard givenURL.flatMap(Self.watchURL)?.kind == .githubPR else { throw StoreError.invalid("tag_pattern は PR の見張りだけ") }
            if !request.events.isEmpty, !request.events.contains(.tagged) {
                throw StoreError.invalid("tag_pattern は events に tagged を入れるか、events を省くときだけ")
            }
        }
        if let givenURL {
            guard let (url, kind) = Self.watchURL(givenURL) else {
                throw StoreError.invalid("url は GitHub の issue か PR の URL（https://github.com/<owner>/<repo>/pull/<番号> の形）")
            }
            if request.events.contains(.opened) { throw StoreError.invalid("opened は repo の見張りだけ（url の見張りでは起きない）") }
            if let devin = request.events.first(where: \.isDevin) { throw StoreError.invalid("\(devin.rawValue) は Devin のセッションのリンクの知らせ（見張りでは起きない）") }
            if kind == .githubIssue, let other = request.events.first(where: { !WatchCreateRequest.issueEvents.contains($0) }) {
                throw StoreError.invalid("\(other.rawValue) は issue では起きない（issue は closed・reopened・comment）")
            }
            if request.query?.trimmingCharacters(in: .whitespaces).isEmpty == false { throw StoreError.invalid("query は repo の見張りだけ") }
            target.url = url
        } else if let givenRepo {
            guard let (host, repo) = Self.watchRepo(givenRepo) else {
                throw StoreError.invalid("repo は owner/name（github.com 以外は host/owner/name）か repo の URL")
            }
            guard request.events.isEmpty else { throw StoreError.invalid("events は url の見張りだけ（repo の見張りは新しく出た issue・PR を知らせる）") }
            let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            if let query {
                guard query.count <= RepoWatchSearch.queryLimit, !query.contains(where: \.isNewline) else {
                    throw StoreError.invalid("query は 1 行・\(RepoWatchSearch.queryLimit) 字まで")
                }
                if let word = RepoWatchSearch.reservedQualifier(in: query) {
                    throw StoreError.invalid("query の \(word) は使えない（repo:・created:・sort: は taskboard が付ける）")
                }
            }
            target = (.repo, nil, repo, host, query)
        } else if let spec = request.command {
            guard request.events.isEmpty, tagPattern == nil, request.query?.trimmingCharacters(in: .whitespaces).isEmpty != false else {
                throw StoreError.invalid("events・tag_pattern・query は command の見張りでは使えない")
            }
            target.kind = .command
            command = String(decoding: try JSONEncoder.sorted.encode(try Self.validCommand(spec)), as: UTF8.self)
        }
        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt, prompt.count > Self.wakePromptLimit {
            throw StoreError.refused(.textTooLong, ["limit": "\(Self.wakePromptLimit)"], "prompt は \(Self.wakePromptLimit) 字まで")
        }
        if let expires = request.expiresAt, expires <= now { throw StoreError.invalid("expires_at が過ぎている") }
        guard (request.conversationID == nil) != (request.taskNumber == nil) else { throw StoreError.invalid("conversationID と taskNumber のどちらか 1 つを渡す") }
        let events = String(decoding: try JSONEncoder().encode(Array(Set(request.events)).sorted { $0.rawValue < $1.rawValue }), as: UTF8.self)
        let (id, existing): (Int64, Bool) = try database.write { db in
            if let number = request.taskNumber, try Row.fetchOne(db, sql: "SELECT 1 FROM task WHERE number = ?", arguments: [number]) == nil {
                throw StoreError.taskNotFound(number)
            }
            if let conversation = request.conversationID, try !ConversationRecord.exists(db, key: conversation) {
                throw StoreError.invalid("会話 \(conversation) が無い")
            }
            let same = try WatchRow.filter(
                Column("state") == Watch.State.active.rawValue && Column("kind") == target.kind.rawValue && Column("url") == target.url
                    && Column("repo") == target.repo && Column("host") == target.host && Column("query") == target.query && Column("events") == events
                    && Column("tagPattern") == tagPattern && Column("command") == command
                    && Column("conversationId") == request.conversationID && Column("taskNumber") == request.taskNumber
            ).fetchOne(db)
            if let same, let id = same.id { return (id, true) }
            if command != nil, try WatchRow.filter(Column("state") == Watch.State.active.rawValue && Column("kind") == Watch.Kind.command.rawValue).fetchCount(db)
                >= Self.commandWatchLimit
            {
                throw StoreError.invalid("有効な command の見張りは \(Self.commandWatchLimit) 件まで。要らないものを watch_cancel で取り消す")
            }
            var row = WatchRow(
                id: nil, kind: target.kind.rawValue, url: target.url, repo: target.repo, host: target.host, query: target.query, events: events,
                tagPattern: tagPattern, command: command, conversationId: request.conversationID, taskNumber: request.taskNumber,
                prompt: prompt?.isEmpty == false ? prompt : nil, once: request.once || request.command?.condition == .finishes, expiresAt: request.expiresAt.map(Self.storedDate), state: Watch.State.active.rawValue,
                createdBy: request.createdBy, createdAt: now, updatedAt: now)
            try row.insert(db)
            return (row.id ?? 0, false)
        }
        if !existing { changed(.watch(id)) }
        guard let created = try watch(id: id) else { throw StoreError.watchNotFound(id) }
        return (created, existing)
    }

    /// 見張りの届け先のタスク（会話宛てなら、その会話が今結ばれているタスク）
    func destinationTask(of watch: Watch) throws -> Int? {
        if let number = watch.taskNumber { return number }
        guard let id = watch.conversationID else { return nil }
        return try database.read { db in try Self.conversationTask(db, id: id) }
    }

    static func conversationTask(_ db: Database, id: String) throws -> Int? {
        try Int.fetchOne(db, sql: "SELECT taskNumber FROM conversation WHERE id = ?", arguments: [id])
    }

    /// `url` の有効な見張りのうち元の様子を取ったものを、届け先のタスクごとに。そのタスクのリンクの知らせのうち、見張りが受ける種類は見張りが届ける
    static func watchesCoveringLinks(_ db: Database, url: String) throws -> [Int: [WatchRow]] {
        var covering: [Int: [WatchRow]] = [:]
        for row in try activeItemWatches(db, url: url) where row.snapshot != nil {
            let task = try row.taskNumber ?? row.conversationId.flatMap { try conversationTask(db, id: $0) }
            if let task { covering[task, default: []].append(row) }
        }
        return covering
    }

    /// 有効な見張りの issue・PR の URL
    func activeWatchURLs() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db, sql: "SELECT DISTINCT url FROM watch WHERE state = ? AND kind = ? AND url IS NOT NULL ORDER BY url",
                arguments: [Watch.State.active.rawValue, Watch.Kind.item.rawValue])
        }
    }

    func watchSnapshot(id: Int64) throws -> LinkSnapshot? { try watchRow(id: id)?.snapshotValue }

    /// 取った様子を、`url` の有効な見張りの前の様子と比べ、届ける種類の出来事を足して新しい様子を書く（1 つの transaction）。
    /// 前の様子が無い見張り（作った直後）は元を記録するだけ。マージ・クローズして届けるものが無ければ終える（タグを待つ見張りはタグに入るまで）。
    /// 出来事を足した見張りの id を返す
    @discardableResult
    func recordWatchSnapshot(url: String, snapshot: LinkSnapshot, viewerLogin: String, at now: Date) throws -> [Int64] {
        let encoder = JSONEncoder()
        let (touched, shown): ([Int64], [Int64]) = try database.write { db in
            var touched: [Int64] = []
            var shown: [Int64] = []
            for var row in try Self.activeItemWatches(db, url: url) {
                guard let id = row.id else { continue }
                let before = row
                let merged = snapshot.merged(over: row.snapshotValue)
                if let old = row.snapshotValue {
                    let notices = LinkNotice.diff(url: url, old: old, new: merged, viewerLogin: viewerLogin).filter { row.accepts($0.kind) }
                    for notice in notices {
                        try db.execute(
                            sql: "INSERT INTO watchEvent (watchId, kind, notice, createdAt) VALUES (?, ?, ?, ?)",
                            arguments: [id, notice.kind.rawValue, String(decoding: try encoder.encode(notice), as: UTF8.self), now])
                    }
                    if !notices.isEmpty { touched.append(id) }
                } else if row.wantsTag, case .pullRequest(let pr) = merged, pr.state == .merged {
                    row.tagState = String(decoding: try encoder.encode(TagWatch.State(mergedBeforeWatch: true)), as: UTF8.self)
                }
                row.snapshot = String(decoding: try encoder.encode(merged), as: UTF8.self)
                row.fetchedAt = now
                row.error = nil
                if row.isFinished(merged), try !Self.hasUndeliveredWatchEvents(db, watch: id) { row.end(.finished) }
                if !row.sameShown(as: before) {
                    row.updatedAt = now
                    shown.append(id)
                }
                try row.update(db)
            }
            return (touched, shown)
        }
        changed(shown.map { .watch($0) })
        return touched
    }

    /// タグを待つ見張り 1 つ
    struct TagWaiting: Equatable {
        var id: Int64
        var url: String
        var mergeCommit: String
        var pattern: String?
        var state: TagWatch.State
    }

    /// マージした PR がまだタグに入っていない、有効な見張り（古い順。merge commit が分かったものだけ）
    func tagWaitingWatches() throws -> [TagWaiting] {
        let rows = try database.read { db in
            try WatchRow.filter(Column("state") == Watch.State.active.rawValue && Column("kind") == Watch.Kind.item.rawValue).order(Column("id")).fetchAll(db)
        }
        return rows.compactMap { row in
            guard let id = row.id, let url = row.url, row.wantsTag, case .pullRequest(let pr)? = row.snapshotValue, pr.state == .merged,
                let commit = pr.mergeCommit
            else { return nil }
            let state = row.tagStateValue ?? TagWatch.State()
            guard state.tag == nil else { return nil }
            return TagWaiting(id: id, url: url, mergeCommit: commit, pattern: row.tagPattern, state: state)
        }
    }

    /// タグを見た結果を書く（1 つの transaction）。`notice` があれば出来事を足す。入ったタグがあって届けるものが無い（前から入っていた）なら終える。
    /// 有効な見張りに出来事を足したら true
    @discardableResult
    func recordTagCheck(id: Int64, state: TagWatch.State, notice: LinkNotice?, at now: Date) throws -> Bool {
        let encoder = JSONEncoder()
        let (touched, shown): (Bool, Bool) = try database.write { db in
            guard var row = try WatchRow.fetchOne(db, key: id), row.stateValue == .active, row.kind == Watch.Kind.item.rawValue else { return (false, false) }
            let before = row
            if let notice {
                try db.execute(
                    sql: "INSERT INTO watchEvent (watchId, kind, notice, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [id, notice.kind.rawValue, String(decoding: try encoder.encode(notice), as: UTF8.self), now])
            }
            row.tagState = String(decoding: try encoder.encode(state), as: UTF8.self)
            row.error = nil
            if row.isFinished(row.snapshotValue), try !Self.hasUndeliveredWatchEvents(db, watch: id) { row.end(.finished) }
            let shown = !row.sameShown(as: before)
            if shown { row.updatedAt = now }
            try row.update(db)
            return (notice != nil, shown)
        }
        if shown { changed(.watch(id)) }
        return touched
    }

    /// 有効な repo の見張り（古い順）
    func activeRepoWatches() throws -> [WatchRow] {
        try database.read { db in
            try WatchRow.filter(Column("state") == Watch.State.active.rawValue && Column("kind") == Watch.Kind.repo.rawValue).order(Column("id")).fetchAll(db)
        }
    }

    /// repo の見張りの前の様子。作った直後は nil
    func repoWatchCursor(id: Int64) throws -> RepoWatchSearch.Cursor? {
        try watchRow(id: id)?.snapshot.flatMap { try? JSONDecoder().decode(RepoWatchSearch.Cursor.self, from: Data($0.utf8)) }
    }

    /// repo の見張りの取った結果を書く（新しく出たものの出来事と、次の様子。1 つの transaction）。有効な見張りに出来事を足したら true
    @discardableResult
    func recordRepoWatch(id: Int64, cursor: RepoWatchSearch.Cursor, notices: [LinkNotice], at now: Date) throws -> Bool {
        let encoder = JSONEncoder()
        let (touched, shown): (Bool, Bool) = try database.write { db in
            guard var row = try WatchRow.fetchOne(db, key: id), row.stateValue == .active, row.kind == Watch.Kind.repo.rawValue else { return (false, false) }
            let before = row
            for notice in notices {
                try db.execute(
                    sql: "INSERT INTO watchEvent (watchId, kind, notice, createdAt) VALUES (?, ?, ?, ?)",
                    arguments: [id, notice.kind.rawValue, String(decoding: try encoder.encode(notice), as: UTF8.self), now])
            }
            row.snapshot = String(decoding: try encoder.encode(cursor), as: UTF8.self)
            row.fetchedAt = now
            row.error = nil
            let shown = !row.sameShown(as: before)
            if shown { row.updatedAt = now }
            try row.update(db)
            return (!notices.isEmpty, shown)
        }
        if shown { changed(.watch(id)) }
        return touched
    }

    /// 見張りを取れなかった。有効なら理由を残す（取れたら消える）
    func noteWatchFailure(id: Int64, reason: String, at now: Date) throws {
        let shown: Bool = try database.write { db in
            guard var row = try WatchRow.fetchOne(db, key: id), row.stateValue == .active, row.error != reason else { return false }
            row.error = reason
            row.updatedAt = now
            try row.update(db)
            return true
        }
        if shown { changed(.watch(id)) }
    }

    /// `url` を取れなかった。有効な見張りに理由を残す（取れたら `recordWatchSnapshot` が消す）
    func noteWatchFetchFailure(url: String, reason: String, at now: Date) throws {
        let shown: [Int64] = try database.write { db in
            var shown: [Int64] = []
            for var row in try Self.activeItemWatches(db, url: url) where row.error != reason {
                row.error = reason
                row.updatedAt = now
                try row.update(db)
                if let id = row.id { shown.append(id) }
            }
            return shown
        }
        changed(shown.map { .watch($0) })
    }

    /// 届けていない出来事（古い順、全部）
    func undeliveredWatchEvents(watch id: Int64) throws -> [WatchEventRecord] {
        try database.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(
                db, sql: "SELECT id, watchId, notice, createdAt FROM watchEvent WHERE watchId = ? AND deliveredAt IS NULL ORDER BY createdAt, id",
                arguments: [id]
            ).map { row in
                WatchEventRecord(
                    id: row["id"], watchID: row["watchId"], notice: try decoder.decode(LinkNotice.self, from: Data((row["notice"] as String).utf8)),
                    createdAt: row["createdAt"])
            }
        }
    }

    /// 届けていない出来事のある有効な見張り
    func watchesWithUndeliveredEvents() throws -> [Int64] {
        try database.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT DISTINCT e.watchId FROM watchEvent e JOIN watch w ON w.id = e.watchId WHERE e.deliveredAt IS NULL AND w.state = ? ORDER BY e.watchId",
                arguments: [Watch.State.active.rawValue])
        }
    }

    /// 出来事を届けた。1 回だけの見張りと、マージ・クローズして届けるものが無くなった見張りは終える。書いた後の行を返す
    @discardableResult
    func markWatchEventsDelivered(watch id: Int64, ids: [Int64], at now: Date) throws -> WatchRow? {
        let (row, shown): (WatchRow?, Bool) = try database.write { db in
            if !ids.isEmpty {
                try db.execute(
                    sql: "UPDATE watchEvent SET deliveredAt = ? WHERE watchId = ? AND deliveredAt IS NULL AND id IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                    arguments: StatementArguments([now, id] as [any DatabaseValueConvertible] + ids))
            }
            guard var row = try WatchRow.fetchOne(db, key: id) else { return (nil, false) }
            guard row.stateValue == .active else { return (row, false) }
            if row.once {
                row.end(.delivered)
            } else if row.isFinished(row.snapshotValue), try !Self.hasUndeliveredWatchEvents(db, watch: id) {
                row.end(.finished)
            } else {
                return (row, false)
            }
            row.updatedAt = now
            try row.update(db)
            return (row, true)
        }
        if shown { changed(.watch(id)) }
        return row
    }

    /// 有効な見張りを終える（期限・届け先が無い）
    func endWatch(id: Int64, _ ending: Watch.Ending, at now: Date) throws {
        let ended: Bool = try database.write { db in
            guard var row = try WatchRow.fetchOne(db, key: id), row.stateValue == .active else { return false }
            row.end(ending)
            row.updatedAt = now
            try row.update(db)
            return true
        }
        if ended { changed(.watch(id)) }
    }

    /// 期限を過ぎた有効な見張りを終える
    func endExpiredWatches(at now: Date) throws {
        let ids = try database.read { db in
            try Int64.fetchAll(
                db, sql: "SELECT id FROM watch WHERE state = ? AND expiresAt IS NOT NULL AND expiresAt <= ?", arguments: [Watch.State.active.rawValue, now])
        }
        for id in ids { try endWatch(id: id, .expired, at: now) }
    }

    /// 取り消す。終えた見張りは取り消せない
    public func cancelWatch(id: Int64, now: Date = Date()) throws -> Watch {
        let row = try cancel(
            WatchRow.self, id: id, notFound: .watchNotFound(id), label: "見張り", live: Watch.State.active.rawValue, cancelled: Watch.State.cancelled.rawValue, now: now)
        changed(.watch(id))
        return watch(from: row)
    }

    /// 終えてから 7 日を過ぎた見張りと、届けてから 7 日を過ぎた出来事を消す
    func purgeFinishedWatches(at now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.finishedRowRetention)
        let ids = try database.write { db in
            let ids = try Self.purgeFinished(WatchRow.self, live: Watch.State.active.rawValue, before: cutoff, db)
            try db.execute(sql: "DELETE FROM watchEvent WHERE deliveredAt < ?", arguments: [cutoff])
            return ids
        }
        changed(ids.map { .watch($0) })
    }

    static func activeItemWatches(_ db: Database, url: String) throws -> [WatchRow] {
        try WatchRow.filter(Column("state") == Watch.State.active.rawValue && Column("kind") == Watch.Kind.item.rawValue && Column("url") == url)
            .order(Column("id")).fetchAll(db)
    }

    private static func hasUndeliveredWatchEvents(_ db: Database, watch id: Int64) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM watchEvent WHERE watchId = ? AND deliveredAt IS NULL)", arguments: [id]) ?? false
    }

    /// backup の確かめ：v24・v25 を通った DB に予定と見張りの表が無ければ断る
    static func verifyWakeAndWatchTables(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations") else { return }
        let applied = Set(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"))
        var tables: [String] = []
        if applied.contains(wakeMigration) { tables.append("wake") }
        if applied.contains(watchMigration) { tables += ["watch", "watchEvent"] }
        for table in tables where try !db.tableExists(table) {
            throw StoreError.missingTable(table)
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
