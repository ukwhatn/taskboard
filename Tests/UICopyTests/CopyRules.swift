import Foundation

/// `docs/ui-copy.md` のうち、機械で見られる規則。日本語を含むリテラルにだけ当てる
struct CopyRule: Sendable {
    let id: String
    /// 直し方の 1 行
    let hint: String
    /// どれかに当たれば違反（ICU の正規表現。Swift の Regex は後読みを持たない）
    var patterns: [String] = []
    /// 補間の式も含めた元の文字列で見る規則
    var rawContains: [String] = []

    func violated(text: String, raw: String) -> Bool {
        if rawContains.contains(where: raw.contains) { return true }
        return patterns.contains { Self.found($0, in: text) }
    }

    static func found(_ pattern: String, in text: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static let japanese = #"[\p{Hiragana}\p{Katakana}\p{Han}ー]"#
    private static let ja = #"\p{Hiragana}\p{Katakana}\p{Han}ー々"#

    static let all: [CopyRule] = [
        CopyRule(
            id: "space", hint: "英数字と日本語の間、数字と単位の間に空白を入れない（「PRを開く」「3件」）",
            patterns: ["[\(ja)] [A-Za-z0-9X⌘⇧⌥⌃↩]", "[A-Za-z0-9X%)⌘⇧⌥⌃↩] [\(ja)]"]),
        CopyRule(
            id: "halfwidth", hint: "疑問符・感嘆符・コロン・括弧は全角にする",
            patterns: ["[\(ja)][?!:(]", "[?!:)][\(ja)]", "[(][\(ja)]", "[\(ja)][)]"]),
        CopyRule(id: "dots", hint: "省略は「…」を 1 つ", patterns: [#"\.\.\."#]),
        CopyRule(id: "nai", hint: "「無い」はひらがな。空状態は「{対象}はありません」", patterns: ["無い"]),
        CopyRule(
            id: "dekinai", hint: "失敗は「{操作}できませんでした。{原因}。{対処}。」、仕様で不可なら「{操作}できません」",
            patterns: ["できない", "[せめれけてね]ない[:：。]", "られない"]),
        CopyRule(
            id: "plain", hint: "説明・エラー・通知の文は敬体（です・ます）にする",
            patterns: [
                // 文の終わり（。）の常体
                "(?:[るぶむくぐつぬだ]|(?<!しょ)う|(?<!まし|でし)た|(?<![まで])す|ない)。",
                // 読点を含む文字列（説明）の終わりの常体
                "、[^、。]*(?:[るぶむくぐつぬ]|(?<!まし|でし)た|(?<![まで])す|ない)$",
                // 状態の文（状態のラベルは「◯◯中」「◯◯済み」の型）
                "(?:ている|ていない|(?<!まし|でし)た)$",
            ]),
        CopyRule(
            id: "keigo", hint: "敬語は「〜してください」「〜しました」まで。二人称を書かない",
            patterns: ["あなた|よろしいですか|ご確認|いただけますよう|させていただ|ございます|することができ|を行う|エラーが発生しました|不正"]),
        CopyRule(
            id: "internal", hint: "内部の語を出さない（daemon、herdr、fixtures、pane、idle、agent、transcript、token など）",
            patterns: [#"(?i)\b(?:daemon|herdr|fixtures?|pane|idle|transcript|agent|token|store|publish|rev)\b"#]),
        CopyRule(
            id: "embed", hint: "エラーをそのまま埋め込まない。UserFacingError で原因と対処の文にする",
            rawContains: [#"\(error"#, "localizedDescription", "String(describing:"]),
        CopyRule(
            id: "terms", hint: "docs/ui-copy.md の用語表の語にする",
            patterns: [
                #"新規|作成|作[るりらっれろ]|繋|起こ[すしさせ]|読み直|リロード|移[すせしさ]|要対応|承認か回答|リビジョン|着地|QR(?!コード)|サイド(?!バー|パネル)|止め[るたて]|\d+[hw]\b"#,
                // 9n の用語表で替えた語（ターミナル・デバイス、作業フォルダ、メモ、Mac、応答、折りたたむ、タイトル、サンドボックス、ウインドウ、タスクの開き方）
                #"端末|作業ディレクトリ|備考|畳|(?<![問話課主])題|マシン|返事|返答|sandbox|(?<!お)知らせ|差し込|出来事|ウィンドウ|中央モーダル|全面(?!的)"#,
            ]),
        avoided,
    ]

    /// 画面の文と会話へ送る文の両方で使わない語（docs/agent-copy.md「使わない語」の表と同じ語。`avoidedTableMatchesDocs` が揃っているかを見る）
    static let avoided = CopyRule(
        id: "avoided", hint: "docs/agent-copy.md「使わない語」の表の語を使わない。表の「使う語」にする",
        patterns: [
            #"(?:人|自分|利用者|誰|相手)の番"#,
            #"の形(?![式状])|る形で|という形"#,
            #"[棲住]み分け"#,
            #"担保"#,
            #"見張"#,
            #"起こ[すしさせ]|起き直"#,
            #"結[ぶびばんべ]"#,
            #"写[すしさせ](?!真)"#,
            #"差し込"#,
            #"畳"#,
        ])
}
