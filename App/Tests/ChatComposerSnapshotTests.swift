import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// チャットの入力欄の / の候補を PNG で固定する。ライト / ダークの 2 組。
/// 記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatComposerSnapshotTests {
    nonisolated static let variants: [BoardSnapshotTests.Variant] = BoardSnapshotTests.variants.filter { ["light", "dark"].contains($0.name) }

    /// `/pr` と打ったときの候補。頭が合うものを先に、途中に含むものを後に。2 つめを選んでいる。説明が長い行は 1 行で切る
    @Test(arguments: variants.map(\.name))
    func commandSuggestions(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let all = [
            SlashCommand(name: "pr-comment", description: "PR にコメントや返信を書くとき。下書きを見せてから投稿する", kind: .skill, scope: .user),
            SlashCommand(name: "pr-review", description: "PR をレビューするとき。差分を読み、指摘を観点ごとにまとめ、確かめてから行のコメントとして出す", kind: .skill, scope: .user),
            SlashCommand(name: "create-draft-pr", description: "", kind: .command, scope: .project),
        ]
        let view = SlashCommandSuggestions(
            commands: SlashCommand.matching("pr", in: all).map(SlashSuggestion.init), selection: 1, fonts: ChatFonts(size: SessionTextSize.chatDefault), pick: { _ in }, hover: { _ in }
        )
        .padding(Space.block)
        .frame(width: 560, alignment: .top)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 160), variant: variant), named: variant.name)
    }

    /// `/re` と打ったとき。Claude Code の組み込み（説明の前に「組み込み」）と利用者の skill が名前の順に混ざる
    @Test(arguments: variants.map(\.name))
    func builtinSuggestions(variantName: String) throws {
        let variant = try #require(Self.variants.first { $0.name == variantName })
        let all = [
            SlashCommand(name: "release-check", description: "リリース前の確認", kind: .skill, scope: .user),
            SlashCommand(name: "reload-plugins", description: "プラグインの再読み込み", kind: .builtin, scope: .builtin),
            SlashCommand(name: "reload-skills", description: "スキルの再読み込み", kind: .builtin, scope: .builtin),
            SlashCommand(name: "rename", description: "セッションの名前", kind: .builtin, scope: .builtin),
            SlashCommand(name: "resume", description: "会話の再開", kind: .builtin, scope: .builtin),
            SlashCommand(name: "pr-review", description: "PR をレビューするとき", kind: .skill, scope: .user),
        ]
        let view = SlashCommandSuggestions(
            commands: SlashCommand.matching("re", in: all).map(SlashSuggestion.init), selection: 0, fonts: ChatFonts(size: SessionTextSize.chatDefault), pick: { _ in }, hover: { _ in }
        )
        .padding(Space.block)
        .frame(width: 560, alignment: .top)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 260), variant: variant), named: variant.name)
    }
}
