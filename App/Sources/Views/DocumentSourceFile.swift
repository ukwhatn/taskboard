import Foundation

/// 文書の元のファイルを開くアプリ
enum DocumentSourceApp {
    case finder, editor
}

/// ［エディタで開く］の URL。設定の値の `{path}` を元のファイルのパスに置き換える（空なら VS Code）
enum DocumentEditorURL {
    static let defaultTemplate = "vscode://file{path}"

    static func url(template: String, path: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespaces)
        let format = trimmed.isEmpty ? defaultTemplate : trimmed
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: format.replacingOccurrences(of: "{path}", with: encoded))
    }
}
