import Foundation
import Testing

@testable import TaskboardKit

@Suite("Claude Code のモデルの一覧")
struct ClaudeModelsTests {
    /// CLI 2.1.304 の initialize の `models` から（`default` は daemon が落とす）
    static let listed = ClaudeMachineInfo(models: [
        .init(value: "opus", resolvedModel: "claude-opus-5-5[1m]", displayName: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "claude-opus-5", resolvedModel: "claude-opus-5", displayName: "Opus 5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "sonnet", resolvedModel: "claude-sonnet-5-5", displayName: "Sonnet 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "claude-sonnet-5", resolvedModel: "claude-sonnet-5", displayName: "Sonnet 5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "fable", resolvedModel: "claude-fable-5-1", displayName: "Fable 5.1", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "haiku", resolvedModel: "claude-haiku-5-5", displayName: "Haiku 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
        .init(value: "claude-haiku-4-5-20251001", resolvedModel: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5", efforts: nil),
        .init(value: "claude-opus-4-6", resolvedModel: "claude-opus-4-6", displayName: "Opus 4.6", efforts: ["low", "medium", "high", "max", "ultra"]),
    ])

    @Test("別名と版つきの名前に分け、CLI の並びのまま出す")
    func groups() {
        let models = ClaudeModels(Self.listed)
        #expect(models.primary.map(\.displayName) == ["Opus 5.5", "Sonnet 5.5", "Fable 5.1", "Haiku 5.5"])
        #expect(models.others.map(\.displayName) == ["Opus 5", "Sonnet 5", "Haiku 4.5", "Opus 4.6"])
    }

    @Test("--model の値は CLI の解決した名前。Opus 5.5 と Fable 5.1 だけ 1M の版（CLI の名前に付いていれば付け足さない）")
    func arguments() {
        let models = ClaudeModels(Self.listed)
        #expect(models.argument(for: "opus") == "claude-opus-5-5[1m]")
        #expect(models.argument(for: "fable") == "claude-fable-5-1[1m]")
        #expect(models.argument(for: "sonnet") == "claude-sonnet-5-5")
        #expect(models.argument(for: "haiku") == "claude-haiku-5-5")
        #expect(models.argument(for: "claude-opus-5") == "claude-opus-5")
        #expect(models.argument(for: "claude-sonnet-5") == "claude-sonnet-5")
    }

    @Test("古い版のアプリ（ClaudeModel の enum の版）が送る名前は、一覧でも同じモデルの --model の値になる")
    func olderAppNames() {
        let models = ClaudeModels(Self.listed)
        let sent = ["claude-opus-5-5[1m]", "claude-fable-5-1[1m]", "claude-sonnet-5", "haiku", "claude-haiku-5-5", "claude-sonnet-5-5"]
        #expect(sent.map { models.argument(for: $0) } == ["claude-opus-5-5[1m]", "claude-fable-5-1[1m]", "claude-sonnet-5", "claude-haiku-5-5", "claude-haiku-5-5", "claude-sonnet-5-5"])
    }

    @Test("今までの記録の名前（解決した名前・[1m] の有無）も同じモデルに引く。一覧に無い名前は引かない")
    func lookup() {
        let models = ClaudeModels(Self.listed)
        #expect(models.model(named: "claude-opus-5-5[1m]")?.value == "opus")
        #expect(models.model(named: "claude-opus-5-5")?.value == "opus")
        #expect(models.model(named: "claude-fable-5-1[1m]")?.value == "fable")
        #expect(models.model(named: "claude-sonnet-5-5")?.value == "sonnet")
        #expect(models.argument(for: "claude-fable-5-1") == "claude-fable-5-1[1m]")
        for unknown in ["", "gpt-6", "Opus", "opus ", "default", "claude-opus-5-5[2m]"] { #expect(models.argument(for: unknown) == nil, "\(unknown)") }
        #expect(models.label("claude-sonnet-5") == "Sonnet 5")
        #expect(models.label("claude-opus-9") == "claude-opus-9")
    }

    @Test("effort はモデルの段階だけ（taskboard の知らない段階は落とす）。effort の無いモデルは空、既定と一覧に無いモデルは全部")
    func efforts() {
        let models = ClaudeModels(Self.listed)
        #expect(models.efforts(for: "claude-opus-4-6") == [.low, .medium, .high, .max])
        #expect(models.efforts(for: "claude-haiku-4-5-20251001").isEmpty)
        #expect(models.efforts(for: nil) == Effort.allCases)
        #expect(models.efforts(for: "claude-opus-9") == Effort.allCases)
    }

    @Test("一覧が無い（古い daemon・まだ CLI から受けていない）ときの控えは、この版より前の daemon が受け付けた名前と同じ")
    func fallback() {
        for info in [nil, ClaudeMachineInfo(models: nil), ClaudeMachineInfo(models: [])] {
            let models = ClaudeModels(info)
            #expect(models.argument(for: "opus") == "claude-opus-5-5[1m]")
            #expect(models.argument(for: "claude-opus-5-5") == "claude-opus-5-5[1m]")
            #expect(models.argument(for: "fable") == "claude-fable-5-1[1m]")
            #expect(models.argument(for: "sonnet") == "claude-sonnet-5")
            #expect(models.argument(for: "haiku") == "claude-haiku-5-5")
            #expect(models.argument(for: "claude-sonnet-5-5") == "claude-sonnet-5-5")
            #expect(models.argument(for: "claude-opus-4-8") == nil)
            #expect(models.primary.map(\.value) == ["opus", "sonnet", "fable", "haiku"])
        }
    }

    @Test("wire の形：新しい欄の無い古い応答も読める")
    func decoding() throws {
        let decoded = try JSONDecoder().decode(ClaudeMachineInfo.self, from: Data(#"{}"#.utf8))
        #expect(decoded.models == nil)
        let model = try JSONDecoder().decode(ClaudeMachineInfo.Model.self, from: Data(#"{"value":"opus","resolvedModel":"claude-opus-5-5[1m]","displayName":"Opus 5.5"}"#.utf8))
        #expect(model.efforts == nil && model.description == nil)
    }
}
