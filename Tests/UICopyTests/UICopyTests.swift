import Foundation
import Testing

/// 画面に出る文の検査（docs/ui-copy.md「検査」）。日本語を含む文字列リテラルを全部読み、機械で見られる規則に当てる。
/// 作り直しの途中の違反は baseline.txt に載せてあり、新しい違反と、直したのに基準に残った違反で落ちる
@Suite struct UICopyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let baselineURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "baseline.txt")

    /// 画面に届く文を持つ場所。daemon の Store と API の文は、エージェントとログのための文（画面はエラーの code から文を組む）なので読まない
    static let scanned = [
        "App/Sources",
        "Sources/TaskboardKit",
        "Sources/TaskboardDaemon/Launch",
        "Sources/TaskboardDaemon/Orchestrator",
        // 通知のテストの文は端末の通知に出る
        "Sources/TaskboardDaemon/Push",
        "Sources/TaskboardDaemon/Schedule",
        "Sources/TaskboardDaemon/Sync",
        "Sources/TaskboardDaemon/Transcripts",
        // 会話の画面の通知の行。ほかの Conversations のファイルの文は agent とログのための文
        "Sources/TaskboardDaemon/Conversations/ConversationScreenText.swift",
    ]
    /// debug のサーバーは画面に出ない
    static let excluded = ["App/Sources/Debug/"]

    struct Violation: Hashable, Comparable {
        let path: String
        let rule: String
        let text: String
        var line = 0

        /// 基準の 1 行。行番号は入れない（前後を直すたびに変わる）
        var key: String { "\(path)\t\(rule)\t\(text.replacingOccurrences(of: "\n", with: "⏎"))" }

        static func == (a: Violation, b: Violation) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
        static func < (a: Violation, b: Violation) -> Bool { a.key < b.key }
    }

    static func sources() throws -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for directory in scanned {
            let url = root.appending(path: directory)
            let files: [URL]
            if url.pathExtension == "swift" {
                files = [url]
            } else {
                guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
                files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            }
            for file in files {
                let path = String(file.path.dropFirst(root.path.count + 1))
                if excluded.contains(where: path.hasPrefix) { continue }
                found.append((path, try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    static func violations() throws -> [Violation] {
        var result: [Violation] = []
        for (path, source) in try sources() {
            for literal in CopyScanner.literals(in: source) where CopyRule.found(CopyRule.japanese, in: literal.text) {
                for rule in CopyRule.all where rule.violated(text: literal.text, raw: literal.raw) {
                    result.append(Violation(path: path, rule: rule.id, text: literal.text, line: literal.line))
                }
            }
        }
        return result
    }

    static func baseline() throws -> Set<String> {
        guard let text = try? String(contentsOf: baselineURL, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    @Test("画面の文が docs/ui-copy.md の規則に合う（基準に載った違反を除く）")
    func copyFollowsRules() throws {
        let found = try Self.violations()
        let keys = Set(found.map(\.key))
        if ProcessInfo.processInfo.environment["UICOPY_RECORD"] == "1" {
            let header = "# UICopyTests の基準（path\\trule\\t文字列）。F7 で空にした。違反を残すときだけ載せる。\n"
            try (header + keys.sorted().joined(separator: "\n") + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            return
        }
        let baseline = try Self.baseline()
        let hints = Dictionary(uniqueKeysWithValues: CopyRule.all.map { ($0.id, $0.hint) })
        let new = found.filter { !baseline.contains($0.key) }.sorted()
        var seen = Set<String>()
        for violation in new where seen.insert(violation.key).inserted {
            Issue.record("\(violation.path):\(violation.line) [\(violation.rule)] 「\(violation.text)」: \(hints[violation.rule] ?? "")")
        }
        let stale = baseline.subtracting(keys).sorted()
        for entry in stale {
            Issue.record("直した違反が基準に残っている。baseline.txt から消す: \(entry)")
        }
    }

    /// `Sources/TaskboardKit/Resources/Agent.xcstrings` のキーと文
    static func agentCatalog() throws -> [(key: String, value: String)] {
        let url = root.appending(path: "Sources/TaskboardKit/Resources/Agent.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = object?["strings"] as? [String: [String: Any]] ?? [:]
        return strings.compactMap { key, entry in
            let ja = (entry["localizations"] as? [String: Any])?["ja"] as? [String: Any]
            let value = (ja?["stringUnit"] as? [String: Any])?["value"] as? String
            return value.map { (key, $0) }
        }.sorted { $0.key < $1.key }
    }

    /// 会話へ送る長い文のテンプレート（`Resources/Prompts/<言語>/*.md`）
    static func promptTemplates() throws -> [(path: String, text: String)] {
        let url = root.appending(path: "Sources/TaskboardKit/Resources/Prompts")
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return [] }
        return try walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }.map {
            (String($0.path.dropFirst(root.path.count + 1)), try String(contentsOf: $0, encoding: .utf8))
        }.sorted { $0.path < $1.path }
    }

    /// 画面の String Catalog（`App/Sources/Localizable.xcstrings`）の文。開発言語の文がキー
    static func appCatalog() throws -> [String] {
        let url = root.appending(path: "App/Sources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return ((object?["strings"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    @Test("画面の catalog・会話へ送る文の catalog とテンプレートに、使わない語が無い")
    func catalogsAvoidWords() throws {
        var texts = try Self.appCatalog().map { ("App/Sources/Localizable.xcstrings", $0) }
        texts += try Self.agentCatalog().map { ("Agent.xcstrings \($0.key)", $0.value) }
        texts += try Self.promptTemplates().map { ($0.path, $0.text) }
        for (place, text) in texts where CopyRule.avoided.violated(text: text, raw: text) {
            Issue.record("\(place) 「\(text.prefix(80))」: \(CopyRule.avoided.hint)")
        }
    }

    @Test("Agent.xcstrings の ui. の文（daemon が組んで画面に届く文）が docs/ui-copy.md の規則に合う")
    func screenTextInAgentCatalog() throws {
        for (key, value) in try Self.agentCatalog() where key.hasPrefix("ui.") {
            for rule in CopyRule.all where rule.violated(text: value, raw: value) {
                Issue.record("Agent.xcstrings \(key) [\(rule.id)] 「\(value)」: \(rule.hint)")
            }
        }
    }

    @Test("docs/agent-copy.md の「使わない語」の表の語を、avoided の規則がすべて見つける")
    func avoidedTableMatchesDocs() throws {
        let doc = try String(contentsOf: Self.root.appending(path: "docs/agent-copy.md"), encoding: .utf8)
        // 表の 1 列目の「」で囲んだ語
        guard let start = doc.range(of: "## 使わない語") else { Issue.record("docs/agent-copy.md に「使わない語」の節が無い"); return }
        let rows = doc[start.upperBound...].split(separator: "\n").drop { !$0.hasPrefix("|") }.prefix { $0.hasPrefix("|") }.dropFirst(2)
        let words = rows.flatMap { row in
            row.split(separator: "|").first.map { String($0).matches(of: /「([^」]+)」/).map { String($0.1) } } ?? []
        }
        #expect(!words.isEmpty)
        for word in words where !CopyRule.avoided.violated(text: word, raw: word) {
            Issue.record("docs/agent-copy.md の使わない語「\(word)」を CopyRule.avoided が見つけない")
        }
    }

    @Test("補間とコメントとログを読み分ける")
    func scanner() {
        let source = #"""
        // 「無い」はコメント
        let a = "\(count) 件"
        logger.info("ログは読まない: \(x)")
        let b = "名前は\(user.name ?? "なし")です。"
        /* 「ブロック」 */ let c = "閉じる"
        let d = "残す" // ui-copy:ignore 理由
        """#
        let literals = CopyScanner.literals(in: source).map(\.text)
        #expect(literals.contains("X 件"))
        #expect(literals.contains("名前はXです。"))
        #expect(literals.contains("閉じる"))
        #expect(!literals.contains { $0.contains("ログ") || $0.contains("ブロック") || $0.contains("残す") })
        #expect(!literals.contains("なし"))
    }

    @Test("規則が当たる例と当たらない例")
    func rules() {
        func ids(_ text: String, raw: String? = nil) -> Set<String> {
            Set(CopyRule.all.filter { $0.violated(text: text, raw: raw ?? text) }.map(\.id))
        }
        #expect(ids("PR が無い") == ["space", "nai"])
        #expect(ids("起動できない: X") == ["dekinai", "halfwidth"])
        #expect(ids("保存できませんでした。時間をおいて、やり直してください。").isEmpty)
        #expect(ids("履歴も削除される。") == ["plain"])
        #expect(ids("削除しました。").isEmpty)
        #expect(ids("前の会話を再開するか、新しく起動する") == ["plain"])
        #expect(ids("daemon に接続できません") == ["space", "internal"])
        #expect(ids("作成できませんでした。X", raw: #"作成できませんでした。\(error)"#) == ["terms", "embed"])
        #expect(ids("タスクを追加") .isEmpty)
        #expect(ids("サイドパネル").isEmpty)
        #expect(ids("サイドビュー").contains("terms"))
        #expect(ids("端末で開く").contains("terms"))
        #expect(ids("ターミナルを閉じる").isEmpty)
        #expect(ids("お知らせ").isEmpty)
        #expect(ids("問題").isEmpty)
        #expect(ids("サイド").contains("terms"))
        #expect(ids("自分の番の PR").contains("avoided"))
        #expect(ids("id の形でない").contains("avoided"))
        #expect(ids("見張りを作る").contains("avoided"))
        #expect(ids("形式が正しくありません").isEmpty)
        #expect(ids("結果").isEmpty)
        #expect(ids("番号").isEmpty)
    }
}
