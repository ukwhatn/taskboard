import Foundation
import Testing
@testable import TaskboardKit

/// 会話へ送る文の置き場（docs/agent-copy.md）。コードの `Copy.text` などの呼び出しと、Agent.xcstrings・Prompts が食い違わないかを見る
@Suite struct AgentCopyTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// コードの呼び出し 1 つ。`values` は渡した辞書のキー（辞書を渡していなければ空）
    struct Call {
        let place: String
        let function: String
        let name: String
        let values: Set<String>
    }

    static func swiftFiles() -> [URL] {
        ["Sources", "App/Sources"].flatMap { directory -> [URL] in
            let walker = FileManager.default.enumerator(at: root.appending(path: directory), includingPropertiesForKeys: nil)
            return (walker?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        }
    }

    /// `Copy.text("キー", ["名前": 値, …])` の形の呼び出し。辞書は括弧と文字列を数えて閉じまで読み、一番外の `"名前":` を拾う
    static func calls() throws -> [Call] {
        var found: [Call] = []
        for file in swiftFiles() where file.lastPathComponent != "Copy.swift" {
            let source = Array(try String(contentsOf: file, encoding: .utf8))
            let text = String(source)
            for match in text.matches(of: /Copy\.(text|unfilled|prompt|template)\("([^"\\]+)"/) {
                let function = String(match.1)
                var index = text.distance(from: text.startIndex, to: match.range.upperBound)
                while index < source.count, source[index] == " " { index += 1 }
                var values = Set<String>()
                if index + 1 < source.count, source[index] == "," {
                    index += 1
                    while index < source.count, source[index] == " " || source[index] == "\n" { index += 1 }
                    if index < source.count, source[index] == "[" { values = dictionaryKeys(source, from: index) }
                }
                let line = text[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                found.append(Call(place: "\(file.lastPathComponent):\(line)", function: function, name: String(match.2), values: values))
            }
        }
        return found
    }

    /// `[` の位置から閉じの `]` までの、一番外の `"名前":` の名前
    static func dictionaryKeys(_ source: [Character], from start: Int) -> Set<String> {
        var depth = 0
        var index = start
        var keys = Set<String>()
        while index < source.count {
            let c = source[index]
            if c == "\"" {
                var end = index + 1
                var nested = 0
                while end < source.count {
                    if source[end] == "\\", end + 1 < source.count, source[end + 1] == "(" { nested += 1; end += 2; continue }
                    if nested > 0, source[end] == ")" { nested -= 1 } else if nested == 0, source[end] == "\"" { break }
                    end += 1
                }
                if depth == 1, end + 1 < source.count, source[end + 1] == ":" { keys.insert(String(source[(index + 1)..<end])) }
                index = end + 1
                continue
            }
            if c == "[" || c == "(" { depth += 1 }
            if c == "]" || c == ")" { depth -= 1; if depth == 0 { break } }
            index += 1
        }
        return keys
    }

    static func catalog() throws -> [String: String] {
        let url = root.appending(path: "Sources/TaskboardKit/Resources/Agent.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = object?["strings"] as? [String: [String: Any]] ?? [:]
        return strings.compactMapValues { entry in
            let ja = (entry["localizations"] as? [String: Any])?["ja"] as? [String: Any]
            return (ja?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    @Test("コードが引くキーとテンプレートがあり、placeholder と渡す値の名前が揃っている")
    func callsMatchCatalog() throws {
        let catalog = try Self.catalog()
        let calls = try Self.calls()
        #expect(calls.count > 500)
        for call in calls {
            switch call.function {
            case "text", "unfilled":
                guard let value = catalog[call.name] else { Issue.record("\(call.place): キー \(call.name) が Agent.xcstrings に無い"); continue }
                if call.function == "text" && Copy.placeholders(in: value) != call.values {
                    Issue.record("\(call.place): \(call.name) の placeholder \(Copy.placeholders(in: value).sorted()) と値 \(call.values.sorted()) が食い違う")
                }
            default:
                let template = Copy.template(call.name)
                if template == call.name { Issue.record("\(call.place): テンプレート \(call.name).md が無い"); continue }
                if call.function == "prompt" && Copy.placeholders(in: template) != call.values {
                    Issue.record("\(call.place): \(call.name).md の placeholder \(Copy.placeholders(in: template).sorted()) と値 \(call.values.sorted()) が食い違う")
                }
            }
        }
    }

    @Test("どこからも引かれていないキーと、catalog に無いキーが無い（三項演算子で選ぶキーもリテラルで書く）")
    func noUnusedKeys() throws {
        var used = Set<String>()
        for file in Self.swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            used.formUnion(text.matches(of: /"((?:agent|cli|ui)\.[A-Za-z0-9_.]+)"/).map { String($0.1) })
        }
        let keys = Set(try Self.catalog().keys)
        for key in keys.subtracting(used).sorted() {
            Issue.record("Agent.xcstrings の \(key) はどこからも引かれていない")
        }
        for key in used.subtracting(keys).sorted() {
            Issue.record("コードのキー \(key) が Agent.xcstrings に無い")
        }
    }

    @Test("bundle から文とテンプレートを引き、{{名前}} を 1 回の走査で埋める")
    func lookUp() {
        #expect(Copy.text("agent.mcp.core.missing", ["name": "task_id"]).hasPrefix("引数 task_id が"))
        #expect(Copy.prompt("mcp-instructions").hasPrefix("taskboard は案件"))
        #expect(Copy.template("board-start").contains("{{id}}"))
        #expect(Copy.fill("{{a}} と {{b}}", ["a": "{{b}}", "b": "x"]) == "{{b}} と x")
        #expect(Copy.text("agent.no.such.key") == "agent.no.such.key")
    }

    @Test("文は bundle に写した Agent.xcstrings そのものから引く（xcstringstool の無い Command Line Tools でビルドしても同じ文になる）")
    func readsCatalogFile() throws {
        let url = try #require(Bundle.module.url(forResource: "Agent", withExtension: "xcstrings"))
        let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let entry = try #require(strings["agent.mcp.core.missing"]?["localizations"] as? [String: [String: [String: String]]])
        #expect(Copy.unfilled("agent.mcp.core.missing") == entry["ja"]?["stringUnit"]?["value"])
    }
}
