import Foundation
import Security
import TaskboardKit

/// daemon が使うファイルの置き場。既定は `~/Library/Application Support/taskboard/`。
public struct Paths: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            self.directory = base.appending(path: "taskboard", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var tokenFile: URL { directory.appending(path: "token") }
    public var machineIDFile: URL { directory.appending(path: "machine-id") }
    public var logDirectory: URL { directory.appending(path: "logs", directoryHint: .isDirectory) }
    public var databaseFile: URL { directory.appending(path: "taskboard.db") }
    public var backupDirectory: URL { directory.appending(path: "backups", directoryHint: .isDirectory) }
    /// `gh` のアカウント対応表（`GitHubAccounts`）
    public var githubAccountsFile: URL { directory.appending(path: GitHubAccounts.fileName) }
    /// Jira Cloud の接続先（`JiraConfig`）。無ければ Jira の状態は取らない
    public var jiraConfigFile: URL { directory.appending(path: "jira.json") }
    /// Devin の API の接続先（`DevinConfig`）。無ければ Devin のセッションを取らず、`devin_*` の tool は断る
    public var devinConfigFile: URL { directory.appending(path: "devin.json") }
    /// APNs の鍵と設定（`APNsKeyStore`）。無ければ通知を送らない
    /// 案件ごとの Slack アプリの設定と token（`SlackSettingsStore`。700 のディレクトリに 600 のファイル）
    public var slackDirectory: URL { directory.appending(path: "slack", directoryHint: .isDirectory) }
    public var apnsDirectory: URL { directory.appending(path: "apns", directoryHint: .isDirectory) }
    /// 回答・レビューが届いたセッションの印（`FeedbackMarkers`）
    public var feedbackPendingDirectory: URL { directory.appending(path: FeedbackMarkers.directoryName, directoryHint: .isDirectory) }
    /// チャットで貼った画像（`AttachmentStore`）
    public var attachmentsDirectory: URL { directory.appending(path: "attachments", directoryHint: .isDirectory) }

    /// bearer token。無ければ 32 バイトの乱数を hex にして 0600 で作る。
    public func loadOrCreateToken() throws -> String {
        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw PathsError.randomFailed(status) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try writePrivate(token, to: tokenFile)
        return token
    }

    /// このマシンの ID。無ければ UUID を作る。
    public func loadOrCreateMachineID() throws -> MachineID {
        if let existing = try? String(contentsOf: machineIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            return MachineID(rawValue: existing)
        }
        let id = UUID().uuidString.lowercased()
        try writePrivate(id, to: machineIDFile)
        return MachineID(rawValue: id)
    }

    private func writePrivate(_ text: String, to url: URL) throws {
        let ok = FileManager.default.createFile(
            atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
        guard ok else { throw PathsError.writeFailed(url) }
    }
}

public enum PathsError: Error {
    case randomFailed(OSStatus)
    case writeFailed(URL)
}
