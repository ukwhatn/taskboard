import Foundation
import TaskboardKit

/// 利用枠の上限で止まった会話に、戻ったら daemon が続きを送るか。Claude Code の設定の `autoContinueAtUsageLimit` を読む
/// （stream-json の CLI は自分で待たないので、TUI で効く設定を daemon が代わりに守る）。読むのはこの鍵だけで、ほかの設定（秘密を含む）は読まない
enum UsageLimitSetting {
    static let key = "autoContinueAtUsageLimit"

    /// 会話の `--settings` のファイル → CLI に渡す環境の `CLAUDE_CONFIG_DIR`（無ければ `~/.claude`）の settings.json の順に、鍵がある最初のもの。
    /// どちらにも無ければ送る（CLI 2.1.303 も鍵が無ければ続ける側に倒す）
    static func continues(record: ConversationRecord, environment: [String: String], home: String) -> Bool {
        for url in files(record: record, environment: environment, home: home) {
            if let value = read(url) { return value }
        }
        return true
    }

    static func files(record: ConversationRecord, environment: [String: String], home: String) -> [URL] {
        var urls: [URL] = []
        let args = record.extraArguments
        if let index = args.firstIndex(of: "--settings"), args.indices.contains(index + 1) { urls.append(URL(fileURLWithPath: args[index + 1])) }
        urls.append(ClaudeConfigDirectory.url(environment: environment, home: URL(fileURLWithPath: home, isDirectory: true)).appending(path: "settings.json"))
        return urls
    }

    /// 設定のファイルの大きさの上限。超えたら読まない（daemon の actor の中で同じ流れで読むため、フォルダ・FIFO・大きいファイルで止まらない）
    static let maxBytes = 1 << 20

    static func read(_ url: URL) -> Bool? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
            let size = values.fileSize, size <= maxBytes,
            let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? Bool
    }
}

/// 利用枠の上限の前に区切るか（`MachineSettings.UsagePause`）。ターンの終わりに会話が最後に受けた窓で決める
enum UsagePauseRule {
    /// prompt cache の TTL。戻るまでこれより長ければ、待つ前に圧縮する（待つ間にキャッシュが切れ、戻った後の発言で全部を書き直すため）
    static let cacheTTL: TimeInterval = 3600

    /// 閾値以上の窓のうち、戻るのが遅い方の戻る時刻。区切らないなら nil（戻る時刻が過ぎた・分からない窓は数えない）
    static func resetsAt(windows: [String: UsageWindow], pause: MachineSettings.UsagePause, now: Date) -> Date? {
        let thresholds = ["five_hour": pause.fiveHourPercent, "seven_day": pause.sevenDayPercent]
        return thresholds.compactMap { kind, percent -> Date? in
            guard let window = windows[kind], window.usedPercent >= Double(percent), let resets = window.resetsAt, resets > now else { return nil }
            return resets
        }.max()
    }

    static func compacts(resetsAt: Date, now: Date) -> Bool { resetsAt.timeIntervalSince(now) > cacheTTL }
}
