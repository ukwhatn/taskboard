import Foundation

/// 通知の行に出す文（docs/ui-copy.md の用語表）。通知の本文は agent に向けた文なので、見出しは種類と文から読み取った番号・題で組む
extension TaskboardNotice {
    public var label: String {
        switch self {
        case .delegate: String(localized: "委譲先の報告")
        case .sessionPrompt: String(localized: "セッションからの連絡")
        case .slack: String(localized: "Slackからの依頼")
        case .link, .watch: String(localized: "PR・issueの更新")
        case .answer: String(localized: "質問の回答")
        case .review: String(localized: "文書のレビュー")
        case .finished: String(localized: "手作業の完了")
        case .draft: String(localized: "送る文面の承認")
        case .limitResume: String(localized: "利用枠の回復")
        case .networkResume: String(localized: "ネットワークの回復")
        case .wake: String(localized: "再開の予定")
        }
    }

    /// 種類の名前に続ける 1 行。番号や題を読み取れない形の文なら nil（種類の名前だけを出す）。前の版の daemon が入れた文の頭も読む
    public func summary(of marked: String) -> String? {
        let text = Self.stripMarker(marked)
        let firstLine = String(text.prefix { $0 != "\n" })
        switch self {
        case .sessionPrompt:
            // 送り主の呼び名と、送った文の頭の 1 行
            let name = Self.item("送り主", in: text).map { Self.senderName($0) }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let body = lines.firstIndex { $0 == Self.bodyHeading[...] }.flatMap { index in
                lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            let head = body.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }
            let parts = [name, head].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "　")
        case .slack:
            // 送り主の呼び名と、依頼の頭の 1 行
            let name = Self.item("送り主", in: text).map { String($0.prefix { $0 != "（" }) }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let body = lines.firstIndex { $0 == Self.slackRequestHeading[...] }.flatMap { index in
                lines.dropFirst(index + 1).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            let parts = [name, body.map { String($0.trimmingCharacters(in: .whitespaces).prefix(80)) }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: "　")
        case .delegate:
            if firstLine == Self.delegateTurnHead || firstLine == Self.delegateAskHead {
                let name = Self.delegateName(Self.item("会話", in: text) ?? "")
                return firstLine == Self.delegateTurnHead
                    ? String(localized: "\(name)が応答を終えました") : String(localized: "\(name)が質問しています")
            }
            let rest = firstLine.dropFirst(Self.legacyDelegatePrefix.count)
            if let range = rest.range(of: "がターンを終えました") {
                return String(localized: "\(Self.delegateName(rest[..<range.lowerBound]))が応答を終えました")
            }
            if let range = rest.range(of: "が問いを待っています") {
                return String(localized: "\(Self.delegateName(rest[..<range.lowerBound]))が質問しています")
            }
            return nil
        case .link:
            guard let number = Self.number(in: firstLine, after: Self.linkPrefix) ?? Self.number(in: firstLine, after: Self.legacyLinkPrefix) else { return nil }
            return String(localized: "タスク#\(number)にリンクしたPR・issueが更新されました")
        case .answer:
            if text == Self.feedbackTooLong { return String(localized: "回答とレビューが長いため、セッションが別に取得します") }
            return Self.number(in: firstLine, after: Self.answerPrefix).map { String(localized: "タスク#\($0)") }
        case .review:
            return Self.number(in: firstLine, after: Self.reviewPrefix).map { String(localized: "タスク#\($0)") }
        case .finished:
            return Self.number(in: firstLine, after: Self.finishedPrefix).map { String(localized: "タスク#\($0)") }
        case .draft:
            return Self.number(in: firstLine, after: Self.draftPrefix).map { String(localized: "タスク#\($0)") }
        case .limitResume, .networkResume:
            return String(localized: "続きを送信しました")
        case .wake:
            // 予定を作ったセッションが書いた指示の頭の 1 行を出す。前の版は 2 行目がその指示
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let prompt: Substring?
            if firstLine.hasPrefix(Self.wakePrefix) {
                prompt = lines.firstIndex { $0 == Self.promptHeading[...] }.flatMap { lines.dropFirst($0 + 1).first }
            } else {
                prompt = lines.count > 1 ? lines[1] : nil
            }
            guard let line = prompt?.trimmingCharacters(in: .whitespaces), !line.isEmpty else { return nil }
            return String(line.prefix(80))
        case .watch:
            // 「[taskboard 通知] 監視 #3（o/r#12）に動きがあった」の括弧の中。前の版の「taskboard: 見張り #3（…）に動きがありました…」も同じ
            guard firstLine.hasPrefix(Self.watchPrefix) || firstLine.hasPrefix(Self.legacyWatchPrefix),
                let open = firstLine.firstIndex(of: "（"), let close = firstLine[open...].firstIndex(of: "）")
            else { return nil }
            let target = firstLine[firstLine.index(after: open)..<close]
            return target.isEmpty ? nil : String(localized: "監視中の\(String(target))が更新されました")
        }
    }

    /// 「- <名前>: 値」の項目の値。本文（最初の「<名前>:」の行）より前だけを見る
    private static func item(_ name: String, in text: String) -> Substring? {
        let head = "- \(name): "
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix(head) { return line.dropFirst(head.count) }
            if !line.hasPrefix("- ") { return nil }
        }
        return nil
    }

    /// 送り主の項目（「会話 <ID の先頭 8 字>「題」（#番号）。人の発言ではない」）の呼び名。会話でなければ句点の前をそのまま
    private static func senderName(_ item: Substring) -> String {
        let head = item.prefix { $0 != "。" }
        guard head.hasPrefix("会話 ") else { return String(head) }
        let name = head.dropFirst("会話 ".count)
        let title = name.firstRange(of: #/「(.*)」/#).map { String(name[$0].dropFirst().dropLast()) }
        let task = name.firstMatch(of: #/（#(\d+)）/#).map { String($0.1) }
        switch (title, task) {
        case let (title?, task?): return String(localized: "「\(title)」（タスク#\(task)）")
        case let (title?, nil): return String(localized: "「\(title)」")
        case let (nil, task?): return String(localized: "タスク#\(task)のセッション")
        case (nil, nil): return String(name.prefix(8))
        }
    }

    /// 「<会話 ID の先頭 8 字>「題」（#番号）」から、会話 ID を外した呼び名
    private static func delegateName(_ name: Substring) -> String {
        let title = name.firstRange(of: #/「(.*)」/#).map { String(name[$0].dropFirst().dropLast()) }
        let task = name.firstMatch(of: #/（#(\d+)）/#).map { String($0.1) }
        switch (title, task) {
        case let (title?, task?): return String(localized: "「\(title)」（タスク#\(task)）")
        case let (title?, nil): return String(localized: "「\(title)」")
        case let (nil, task?): return String(localized: "タスク#\(task)の委譲先")
        case (nil, nil): return String(localized: "委譲先")
        }
    }

    private static func number(in line: String, after prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let digits = line.dropFirst(prefix.count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}
