import Foundation

/// 人の回答・レビューが届いていて、まだ受領されていないセッションの印。`<support>/feedback-pending/<セッション ID>` の空のファイル。
/// PostToolUse・UserPromptSubmit の hook はシェルの `[ -e ]` で印の有無だけを見て、あるときだけ taskboard を起こす
/// （ツールを使うたびに taskboard を起こして daemon に聞くと、1 回ごとに process の起動と HTTP の往復が乗る）
public struct FeedbackMarkers: Sendable {
    public static let directoryName = "feedback-pending"

    let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    func mark(sessions: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for session in sessions where Self.isSafeName(session) {
            fm.createFile(atPath: directory.appending(path: session).path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
    }

    func clear(sessions: [String]) {
        for session in sessions where Self.isSafeName(session) {
            try? FileManager.default.removeItem(at: directory.appending(path: session))
        }
    }

    func isMarked(_ session: String) -> Bool {
        Self.isSafeName(session) && FileManager.default.fileExists(atPath: directory.appending(path: session).path)
    }

    /// hook の command がシェルでパスに埋めるので、英数と `-` `_` `.` だけ（Claude Code のセッション ID は UUID）
    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }
}
