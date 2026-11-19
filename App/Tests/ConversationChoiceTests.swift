import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// ［状態］の値の文字
@Suite struct ConversationStatsTextTests {
    @Test("費用は2桁、1セント未満は4桁。0は$0.00")
    func cost() {
        #expect(ConversationStatsText.cost(0.2481) == "$0.25")
        #expect(ConversationStatsText.cost(0.0094) == "$0.0094")
        #expect(ConversationStatsText.cost(0.01) == "$0.01")
        #expect(ConversationStatsText.cost(0) == "$0.00")
        #expect(ConversationStatsText.cost(12.5) == "$12.50")
    }

    private let fallback = ClaudeModels(nil)
    static let listed = ClaudeMachineInfo(models: [
        .init(value: "opus", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "claude-opus-4-6", resolvedModel: "claude-opus-4-6", displayName: "Opus 4.6", efforts: ["low", "medium", "high", "max"]),
        .init(value: "claude-haiku-4-5-20251001", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", efforts: nil),
    ])

    @Test("モデル: デフォルトは解決した名前を添え、選んだものと同じモデルなら名前だけ。違うモデルで動いていれば添える")
    func model() {
        #expect(ConversationStatsText.model(chosen: "sonnet", resolved: "claude-sonnet-5-5", models: ClaudeModels(Self.listed)) == "Sonnet 5.5")
        #expect(ConversationStatsText.model(chosen: "claude-opus-4-6", resolved: nil, models: ClaudeModels(Self.listed)) == "Opus 4.6")
        #expect(ConversationStatsText.model(chosen: nil, resolved: "claude-opus-5-5[1m]", models: fallback) == "デフォルト（claude-opus-5-5[1m]）")
        #expect(ConversationStatsText.model(chosen: nil, resolved: nil, models: fallback) == "デフォルトのモデル")
        #expect(ConversationStatsText.model(chosen: "opus", resolved: "claude-opus-5-5[1m]", models: fallback) == "Opus 5.5")
        #expect(ConversationStatsText.model(chosen: "claude-opus-5-5[1m]", resolved: nil, models: fallback) == "Opus 5.5")
        #expect(ConversationStatsText.model(chosen: "opus", resolved: "claude-haiku-5-5", models: fallback) == "Opus 5.5（claude-haiku-5-5）")
        #expect(ConversationStatsText.model(chosen: "gpt-5", resolved: "gpt-5", models: fallback) == "gpt-5")
    }

    @Test("区分の名前は知っているものを訳し、（deferred）は外す。知らない名前はそのまま")
    func categories() {
        #expect(ConversationStatsText.categoryName("System tools (deferred)") == "システムのツール")
        #expect(ConversationStatsText.categoryName("Free space") == "空き")
        #expect(ConversationStatsText.categoryName("Plugins") == "Plugins")
        #expect(ConversationStatsText.share(282_000, of: 600_000) == 47)
        #expect(ConversationStatsText.share(1, of: 0) == 0)
    }
}

/// 会話の下の帯のモデルと effort の候補
@Suite struct ConversationModelOptionsTests {
    @Test("Claude Code はマシンの一覧の別名を並べ、版つきの名前は畳む側に。値は --model に渡す名前で、印は書き方の違いをそろえて付ける")
    func claude() throws {
        let options = try #require(ConversationModelOptions.of(.claude, codex: nil, claude: ConversationStatsTextTests.listed))
        #expect(options.models.map(\.label) == ["Opus 5.5", "Sonnet 5.5"])
        #expect(options.otherModels.map(\.label) == ["Opus 4.6", "Haiku 4.5"])
        #expect(options.models.map(\.value) == ["claude-opus-5-5[1m]", "claude-sonnet-5-5"])
        #expect(options.selected("opus") == "claude-opus-5-5[1m]")
        #expect(options.selected("claude-opus-9") == nil)
        #expect(options.label("sonnet") == "Sonnet 5.5")
        #expect(options.label(nil) == "デフォルトのモデル")
    }

    @Test("effort はモデルの段階だけ。effort の無いモデルは空（欄を出さない）、既定のモデルは全部")
    func efforts() throws {
        let options = try #require(ConversationModelOptions.of(.claude, codex: nil, claude: ConversationStatsTextTests.listed))
        #expect(options.efforts(for: "claude-opus-4-6").map(\.value) == ["low", "medium", "high", "max"])
        #expect(options.efforts(for: "claude-haiku-4-5-20251001").isEmpty)
        #expect(options.efforts(for: nil).count == Effort.allCases.count)
    }

    @Test("一覧をまだ読めていないマシンは、控えの一覧（前の版と同じ 3 つに Haiku 5.5 を足したもの）")
    func fallback() throws {
        let options = try #require(ConversationModelOptions.of(.claude, codex: nil, claude: nil))
        #expect(options.models.map(\.label) == ["Opus 5.5", "Sonnet 5", "Fable 5.1", "Haiku 5.5"])
        #expect(options.otherModels.map(\.label) == ["Sonnet 5.5"])
    }
}
