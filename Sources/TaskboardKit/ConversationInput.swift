// ui-copy:ignore-file
// このファイルの文（答えが選択肢に合わないときの断り）は MCP の応答と API のエラーに出て、画面には出ない。アプリは daemon の文を出さず、コードから固定の文を組む（App/Sources/Design/Failure.swift）
import Foundation

/// 会話（stream-json）の入力の決まり。daemon が受けたときに確かめ、MCP・CLI・アプリの選択肢もここから作る
public enum ConversationInput {
    /// 欄で選べる権限のモード（並べる順）
    public static let permissionModes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]
    /// daemon が受け付ける権限のモード。欄に出さない dontAsk・manual も CLI にはあるので受ける
    public static let acceptedPermissionModes = permissionModes + ["dontAsk", "manual"]
    /// 権限を渡さないときのモード（TUI の起動の `--dangerously-skip-permissions` と同じく確認なし）
    public static let defaultPermissionMode = "bypassPermissions"
    public static let titleLimit = 200
    /// 発言・最初の文・コードブロックの上限（UTF-8 のバイト数）
    public static let textBytes = 1_048_576

    /// codex のモデルと effort として受ける名前（使える名前は codex の `model/list` が持つので、ここでは形だけを見る）
    public static func acceptsCodexName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-._".unicodeScalars.contains($0)) }
    }

    /// 前後の空白と改行を落とした題。空なら nil
    public static func title(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 人や agent が付ける題として受けるか（`title(_:)` を通した後の題）。改行を含まず、上限まで
    public static func acceptsTitle(_ title: String) -> Bool {
        !title.contains(where: \.isNewline) && title.count <= titleLimit
    }

    /// ほかの名前（定期起動の名前・TUI の題）から作る題。改行は空白にして、上限で切る
    public static func clippedTitle(_ value: String) -> String? {
        let flat = String(value.map { $0.isNewline ? " " : $0 }).trimmingCharacters(in: .whitespaces)
        return title(String(flat.prefix(titleLimit)))
    }

    /// 使わせない tool を Claude Code に渡す引数（`--disallowedTools <名前…>`）。各値をカンマで分け、前後の空白を落とし、空は除く。名前が無ければ空
    public static func disallowedToolsArguments(_ values: [String]) -> [String] {
        let tools = values.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
        return tools.isEmpty ? [] : ["--disallowedTools"] + tools
    }
}

/// 答えが問いの選択肢に合わない理由
public enum AskAnswerMismatch: Hashable, Sendable {
    /// 選んだ label が選択肢に無い
    case unknownOption(String)
    /// 単一選択の問いで 2 つ以上選んだ
    case multiple

    /// MCP と API の断りの文
    public static func describe(_ mismatch: AskAnswerMismatch, _ question: AskQuestion) -> String {
        switch mismatch {
        case .unknownOption(let label): "「\(label)」は \(question.id) の選択肢に無い。選択肢: " + question.options.map(\.label).joined(separator: " / ")
        case .multiple: "\(question.id) は 1 つだけ選ぶ"
        }
    }
}

extension AskQuestion {
    /// 答えが選択肢に合うか。合わなければ理由
    public func mismatch(_ answer: AskAnswer) -> AskAnswerMismatch? {
        let labels = Set(options.map(\.label))
        if let unknown = answer.selected.first(where: { !labels.contains($0) }) { return .unknownOption(unknown) }
        if !multiSelect, answer.selected.count > 1 { return .multiple }
        return nil
    }
}
