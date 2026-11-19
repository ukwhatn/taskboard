import Foundation
import TaskboardKit

/// 案件の Slack アプリの設定と token。support ディレクトリの `slack/<案件の id>.json`（ディレクトリは 700、ファイルは 600）。
/// Keychain に入れないのは、launchd の daemon からロックされた login keychain を読めないことがあるため（APNs の鍵と同じ）。中身はログ・エラー文に出さない
struct SlackSettingsStore: Sendable {
    let directory: URL

    struct Settings: Codable, Hashable, Sendable {
        var botToken: String
        var appToken: String
        var allowedUsers: [SlackMember] = []
        var routes: [SlackRoute] = []
        /// `auth.test` で取ったもの
        var teamID: String?
        var workspace: String?
        var botUserID: String?
        var botName: String?
    }

    func load(board id: String) -> Settings? {
        guard let url = url(board: id), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Settings.self, from: data)
    }

    /// 設定のある案件の id
    func boards() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(".json".count)) }.sorted()
    }

    func save(_ settings: Settings, board id: String) throws {
        guard let url = url(board: id) else { throw StoreError.invalid("案件の id \(id) を読めない") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard SecretFile.write(try encoder.encode(settings), to: url) else { throw StoreError.invalid("Slack の設定を保存できない") }
    }

    func delete(board id: String) {
        guard let url = url(board: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 案件の id はパスに入るので、英数字と `-` だけを受ける（`..` や `/` でディレクトリの外に出ない）
    private func url(board id: String) -> URL? {
        guard !id.isEmpty, id.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return directory.appending(path: id + ".json")
    }
}
