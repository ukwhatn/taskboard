import Foundation

/// 着手済みのタスクが動いていないこと。カードの札・受信箱・MCP が同じ判定を使う
public struct TaskStall: Hashable, Sendable {
    /// 最後に動いた時刻（タスクと作業項目の新しい方）。受信箱の項目の revision にする
    public var since: Date
    /// 動いていない日数（日付の差で数える）
    public var days: Int

    public init(since: Date, days: Int) {
        self.since = since
        self.days = days
    }

    /// 週末をまたいだだけで出ないよう 3 日から
    public static let thresholdDays = 3

    /// カードの札と受信箱の補足の文
    public var label: String { String(localized: "\(days)日更新なし") }
}

extension BoardTask {
    /// 動いていなければその様子、動いていれば nil。
    /// 見るのは着手済み（セッションが結ばれているか、作業項目がある）のタスクだけで、残りの作業項目が全部待ちのタスクは除く。まとめて起票しただけのタスクは待つのが普通で、
    /// 札を付けると自分の番の印が埋もれる。常設は期限の無い仕事、終端（`terminal`）は終わった仕事なので数えない
    public func stall(workItems: [WorkItem], terminal: Bool, now: Date, calendar: Calendar = .current) -> TaskStall? {
        guard !terminal, columnID != BoardColumn.standingID, !sessions.isEmpty || !workItems.isEmpty else { return nil }
        // 残りの作業項目が全部待ちなら、待ちの理由はもう待ち理由の行と受信箱に出ているので重ねない
        let remaining = workItems.filter { $0.state != .done && $0.state != .drop }
        if !remaining.isEmpty, remaining.allSatisfy({ $0.state == .wait }) { return nil }
        // 作業項目の更新は daemon でタスクの時刻も進めるが、アプリの state が作業項目だけを受け取った間もずれないように両方を見る
        let since = workItems.map(\.updatedAt).reduce(updatedAt, max)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: since), to: calendar.startOfDay(for: now)).day ?? 0
        guard days >= TaskStall.thresholdDays else { return nil }
        return TaskStall(since: since, days: days)
    }
}

extension MachineState {
    /// タスクの列が終端か。案件の列の種類で決め、案件が見つからなければ既定の完了・見送りの id で決める
    public func isTerminal(_ task: BoardTask) -> Bool {
        boards[task.boardID]?.columns.first { $0.id == task.columnID }.map { $0.kind == .terminal }
            ?? BoardColumn.standard.contains { $0.id == task.columnID && $0.kind == .terminal }
    }
}
