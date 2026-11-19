import Foundation

/// アプリの中の行き先の URL（`taskboard://…`）。通知・アプリの遷移・debug の口が、組み立てと読み取りをここで揃える。
/// 前の版の daemon が送る `inbox`・`sessions`・`session`・`schedules`・`prs` も読み、今の行き先に寄せる（通知はほかの Mac の daemon から届く）
public enum TaskboardLink: Hashable, Sendable {
    /// PR。結んだタスクがあればその画面の PR の欄、無ければ PR を取ったマシンの「タスクなし」
    case pullRequest(url: String)
    /// オーケストレーターの画面。マシンが無ければ見ている画面のマシン
    case orchestrator(MachineID?)
    case conversation(ConversationKey)
    /// すべての案件
    case boards
    case board(machine: MachineID, id: String)
    /// タスクを開く。doc があればその文書も開く
    case task(TaskKey, doc: Int64? = nil)
    /// マシンの「タスクなし」
    case unassigned(MachineID)

    public init?(url: URL) {
        guard url.scheme == "taskboard" else { return nil }
        let parts = [url.host()].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        func machine(_ index: Int) -> MachineID? { parts.count > index ? MachineID(rawValue: parts[index]) : nil }
        switch parts.first {
        case "pr", "prs":
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            self = target.map { .pullRequest(url: $0) } ?? .boards
        // shortcut: 端末のセッション（`session/<machine>/<pane>`）は H3 で無くなった。全部の Mac の daemon を入れ替えたら外す
        case "inbox", "sessions", "session", "schedules": self = .boards
        case "orchestrator": self = .orchestrator(machine(1))
        case "unassigned":
            guard let machine = machine(1) else { return nil }
            self = .unassigned(machine)
        case "conversation":
            guard let machine = machine(1), parts.count >= 3 else { return nil }
            self = .conversation(ConversationKey(machine: machine, id: parts[2]))
        case "boards": self = .boards
        case "board":
            guard let machine = machine(1), parts.count >= 3 else { return nil }
            self = .board(machine: machine, id: parts[2])
        case "task":
            guard let machine = machine(1), parts.count >= 3, let number = Int(parts[2]) else { return nil }
            let doc = parts.count >= 5 && parts[3] == "doc" ? Int64(parts[4]) : nil
            self = .task(TaskKey(machine: machine, number: number), doc: doc)
        default: return nil
        }
    }

    public var url: URL {
        switch self {
        case .pullRequest(let url):
            var components = URLComponents(string: "taskboard://pr")!
            // `&`・`=`・`+` は query の区切りなので、値の中では符号化する（そのままだと読み戻せない）
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+?")
            components.percentEncodedQuery = "url=" + (url.addingPercentEncoding(withAllowedCharacters: allowed) ?? url)
            return components.url!
        case .orchestrator(let machine): return Self.make("orchestrator", machine?.rawValue)
        case .conversation(let key): return Self.make("conversation", key.machine.rawValue, key.id)
        case .boards: return Self.make("boards")
        case .board(let machine, let id): return Self.make("board", machine.rawValue, id)
        case .task(let key, let doc): return Self.make("task", key.machine.rawValue, String(key.number), doc.map { "doc/\($0)" })
        case .unassigned(let machine): return Self.make("unassigned", machine.rawValue)
        }
    }

    private static func make(_ head: String, _ rest: String?...) -> URL {
        URL(string: (["taskboard://" + head] + rest.compactMap { $0 }).joined(separator: "/"))!
    }

    /// 定期起動の実行の行き先。会話 → タスク → マシンの「タスクなし」の順に、記録にあるものを選ぶ。
    /// `state` があれば今ある会話だけを選ぶ（通知は state を持たないので、記録だけで選ぶ）
    public static func scheduleRun(_ schedule: Schedule, _ run: ScheduleRun, in state: MachineState?) -> TaskboardLink {
        if let id = run.conversationID {
            let key = ConversationKey(machine: schedule.machine, id: id)
            if state == nil || state?.conversations[key] != nil { return .conversation(key) }
        }
        if let number = schedule.taskNumber { return .task(TaskKey(machine: schedule.machine, number: number)) }
        return .unassigned(schedule.machine)
    }
}
