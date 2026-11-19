import Foundation

/// トークン・鍵のファイルの読み書き。中身はログ・エラー文に出さない
enum SecretFile {
    /// 先頭の `~/` は HOME に。`variable` があれば `NAME=value` の行（`export ` と引用符を外す）から、無ければファイル全体（前後の空白と改行を落とす）。
    /// 読めない・空・変数の行が無ければ nil
    static func read(_ file: String, variable: String? = nil, home: String) -> String? {
        let path = file.hasPrefix("~/") ? home + "/" + file.dropFirst(2) : file
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let token: String
        if let variable {
            guard let line = text.split(whereSeparator: \.isNewline).lazy.map({ $0.trimmingCharacters(in: .whitespaces) })
                .map({ $0.hasPrefix("export ") ? String($0.dropFirst("export ".count)) : $0 })
                .first(where: { $0.hasPrefix(variable + "=") })
            else { return nil }
            var value = line.dropFirst(variable.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
            token = value
        } else {
            token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token.isEmpty ? nil : token
    }

    /// 0600 の一時ファイルに書いてから置き換える（途中の中身を読ませず、ほかのユーザーに読める時間を作らない）。書けなければ false
    static func write(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }
}
