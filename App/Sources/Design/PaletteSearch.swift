import Foundation

/// ⌘K のパレットに並ぶ 1 行。実行する中身は `CommandPalette` が id から引く
struct PaletteEntry: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case command, task, pullRequest, board, conversation

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String = ""
    /// 題に出ない検索語（英語名など）
    var keywords: [String] = []
    /// 紐づく URL（タスクのリンク・PR）。「/」を含む語のとき前方一致で引く
    var urls: [String] = []
    /// 右に出すショートカット（「⌘N」など）
    var shortcut: String?
    /// 選んだときの行き先（コマンドの行は無し）
    var destination: Destination?
}

enum PaletteSearch {
    static let limit = 50

    /// 空の欄ではコマンドだけ。語は空白で区切り、すべてを含む行を、強い一致から並べる:
    /// タスクの番号か紐づく URL の先頭 → 題の先頭（コマンドは検索語の先頭も）→ 題に全部 → 副題や keywords まで含めて全部。同じ強さなら種類、元の順
    static func rank(_ entries: [PaletteEntry], query: String) -> [PaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return Array(entries.filter { $0.kind == .command }.prefix(limit)) }
        let tokens = trimmed.split(separator: " ").map(String.init)
        let number = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let isNumber = !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
        let url = trimmed.contains("/") && !trimmed.contains(" ") ? withoutScheme(trimmed) : nil

        let scored = entries.enumerated().compactMap { index, entry -> (score: Int, entry: PaletteEntry, index: Int)? in
            let title = entry.title.lowercased()
            if isNumber, entry.kind == .task, title.hasPrefix("#\(number) ") { return (0, entry, index) }
            if let url, entry.urls.contains(where: { matches(url, withoutScheme($0.lowercased())) }) { return (0, entry, index) }
            // コマンドは英語の検索語（「board」で「案件を作る」）でも、題の先頭と同じ強さにする。題にたまたま含むタスクより上に出すため
            if title.hasPrefix(trimmed) || (entry.kind == .command && entry.keywords.contains { $0.lowercased().hasPrefix(trimmed) }) { return (1, entry, index) }
            if tokens.allSatisfy(title.contains) { return (2, entry, index) }
            let all = ([title, entry.subtitle.lowercased()] + entry.keywords.map { $0.lowercased() }).joined(separator: " ")
            if tokens.allSatisfy(all.contains) { return (3, entry, index) }
            return nil
        }
        return scored
            .sorted { ($0.score, $0.entry.kind.rawValue, $0.index) < ($1.score, $1.entry.kind.rawValue, $1.index) }
            .prefix(limit)
            .map(\.entry)
    }

    private static func withoutScheme(_ url: String) -> Substring {
        for scheme in ["https://", "http://"] where url.hasPrefix(scheme) { return url.dropFirst(scheme.count) }
        return Substring(url)
    }

    /// 検索語が URL の先頭か、URL より深い所（/files・#discussion・?query）を指していれば一致。/pull/43 で /pull/4360 は引かない
    private static func matches(_ query: Substring, _ url: Substring) -> Bool {
        if url.hasPrefix(query) { return true }
        guard query.hasPrefix(url), let next = query.dropFirst(url.count).first else { return false }
        return url.hasSuffix("/") || "/#?".contains(next)
    }
}
