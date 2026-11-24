import Foundation
import TaskboardKit

/// 終わった Run を会話へ送る発言。Claude Code の `!` と同じ `<bash-input>`・`<bash-stdout>`・`<bash-stderr>` で書く
/// （擬似端末は標準エラーを分けられないので、出力は全部 `<bash-stdout>` に入れる）。会話の画面は `TranscriptParser.userText` が印にする
enum RunResultText {
    /// 送る出力の上限。判定の行は末尾に出るので末尾を残す
    static let outputBytes = 100 * 1024

    static func compose(_ run: ConversationRun, timeout: Duration) -> String {
        let status: String
        switch run.status {
        case .cancelled: status = Copy.text("agent.run.status.cancelled")
        case .timedOut: status = Copy.text("agent.run.status.timedOut", ["minutes": "\(timeout.components.seconds / 60)"])
        case .running, .succeeded, .failed:
            status = run.exitCode.map { Copy.text("agent.run.status.exit", ["code": "\($0)"]) } ?? Copy.text("agent.run.status.shellGone")
        }
        var head = Copy.text("agent.run.result", ["status": status])
        var output = run.output
        if output.utf8.count > outputBytes || run.truncated {
            output = utf8Suffix(output, bytes: outputBytes)
            head += Copy.text("agent.run.truncated", ["kb": "\(outputBytes / 1024)"])
        }
        return "\(head)\n<bash-input>\(run.code)</bash-input>\n<bash-stdout>\(output)</bash-stdout>\n<bash-stderr></bash-stderr>"
    }

    /// taskboard が送った Run の結果の発言か（説明の行の後に `<bash-input>` が続く。端末の `!` の発言は `<bash-input>` で始まる）
    static func isResult(_ text: String) -> Bool {
        !text.hasPrefix("<bash-input>") && text.contains("\n<bash-input>") && text.contains("</bash-stdout>")
    }

    /// 末尾から `bytes` バイトまで（文字の途中で切らない）
    private static func utf8Suffix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var start = text.utf8.index(text.utf8.endIndex, offsetBy: -bytes)
        while start < text.utf8.endIndex, String.Index(start, within: text) == nil { start = text.utf8.index(after: start) }
        return String(text[start...])
    }
}
