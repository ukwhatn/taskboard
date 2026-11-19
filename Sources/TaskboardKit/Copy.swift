import Foundation

/// 会話（Claude Code・Codex）と CLI に出す文の置き場（docs/agent-copy.md）。画面の文は App の `Localizable.xcstrings` にあり、ここには置かない。
/// - 短い文は `Resources/Agent.xcstrings` のキーで引く。キーの頭は、会話が読む文が `agent.`、端末で人が読む CLI の出力が `cli.`
/// - 長い文は `Resources/Prompts/<言語>/<名前>.md` のテンプレートで引く。言語は `Agent` の表と同じもの
/// - どちらも `{{名前}}` を `values` の値で埋める
public enum Copy {
    /// `Agent.xcstrings` の `key` の文。キーが無ければキーそのものを返す（`AgentCopyTests` が使っているキーの有無を見る）
    public static func text(_ key: String, _ values: [String: String] = [:]) -> String {
        fill(unfilled(key), values, name: key)
    }

    /// `key` の文を埋めずに返す。`{{id}}` のような placeholder を説明として文字どおり含む文に使う
    public static func unfilled(_ key: String) -> String {
        catalog[key] ?? key
    }

    /// テンプレート `name` を `values` で埋めた文
    public static func prompt(_ name: String, _ values: [String: String] = [:]) -> String {
        fill(template(name), values, name: name)
    }

    /// テンプレート `name` を埋めずに返す。daemon があとで埋める既定の起動プロンプト（`PromptTemplate.render`）に使う
    public static func template(_ name: String) -> String {
        let language = Bundle.module.preferredLocalizations.first ?? "ja"
        let url = Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts/\(language)")
            ?? Bundle.module.url(forResource: name, withExtension: "md", subdirectory: "Prompts/ja")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return name }
        // ファイルの末尾の改行は文に含めない（エディタが付ける）
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// `{{名前}}` を埋める。文の placeholder と渡した値の名前が食い違えば debug のビルドで止める
    public static func fill(_ text: String, _ values: [String: String], name: String = "") -> String {
        let wanted = placeholders(in: text)
        assert(wanted == Set(values.keys), "\(name): placeholder \(wanted.sorted()) と値 \(values.keys.sorted()) が食い違う")
        // 1 回の走査で埋める（値の中の `{{…}}` を埋め直さない）
        return text.replacing(placeholder) { values[String($0.1)] ?? String($0.0) }
    }

    /// 文の中の `{{名前}}` の名前
    public static func placeholders(in text: String) -> Set<String> {
        Set(text.matches(of: placeholder).map { String($0.1) })
    }

    /// `Agent.xcstrings` のキーと文。compile した `.strings` でなく JSON を自分で読む（xcstringstool の無い Command Line Tools のビルドでは
    /// xcstrings が compile されずに写り、`localizedString` がキーを返していた）。言語は端末の優先順で catalog にあるもの、無ければ元の言語
    private static let catalog: [String: String] = {
        guard let url = Bundle.module.url(forResource: "Agent", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CatalogFile.self, from: data) else { return [:] }
        let languages = Set(file.strings.values.flatMap { $0.localizations.keys })
        let language = Bundle.preferredLocalizations(from: Array(languages)).first ?? file.sourceLanguage
        return file.strings.compactMapValues { entry in
            (entry.localizations[language] ?? entry.localizations[file.sourceLanguage])?.stringUnit.value
        }
    }()

    private struct CatalogFile: Decodable {
        struct Entry: Decodable { var localizations: [String: Localization] = [:] }
        struct Localization: Decodable { var stringUnit: StringUnit }
        struct StringUnit: Decodable { var value: String }
        var sourceLanguage: String
        var strings: [String: Entry]
    }

    nonisolated(unsafe) private static let placeholder = /\{\{([A-Za-z0-9_]+)\}\}/
}
