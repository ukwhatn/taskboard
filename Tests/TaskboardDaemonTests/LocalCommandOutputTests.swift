import Foundation
import TaskboardKit
import Testing

@testable import TaskboardDaemon

/// Claude Code 2.1.304 を stream-json で動かし、`/reload-plugins`・`/context`・`/theme`・`/clear` を送って取った行。
/// ライブ（stdout の `assistant`）と履歴（transcript の `system/local_command`）は、同じ発言を別の形で運ぶ。
/// 作業フォルダのパスは置き換え、`/usage`・`/context` の本文は頭だけ残した
private enum Fixture {
    static let liveReload = #"{"type":"assistant","message":{"diagnostics":null,"id":"31f431e8-0c4e-4022-8c34-c1add6e34c76","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"end_turn","stop_sequence":null,"type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"Reloaded: 1 plugin · 0 skills · 5 agents · 0 hooks · 0 plugin LSP servers"}],"context_management":null},"parent_tool_use_id":null,"local_command_source":"<local-command-stdout>Reloaded: 1 plugin · 0 skills · 5 agents · 0 hooks · 0 plugin LSP servers</local-command-stdout>","session_id":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e","uuid":"36a290f3-42e4-4616-81e7-bef8cf1e5496","timestamp":"2026-10-23T03:00:43.117Z","local_command_run":{"command":"reload-plugins","args":""}}"#
    static let historyReload = #"{"parentUuid":"4f04167d-a5fc-4b15-8202-7c84cebc6821","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>Reloaded: 1 plugin · 0 skills · 5 agents · 0 hooks · 0 plugin LSP servers</local-command-stdout>","level":"info","timestamp":"2026-10-23T03:00:43.117Z","uuid":"36a290f3-42e4-4616-81e7-bef8cf1e5496","isMeta":false,"commandRun":{"command":"reload-plugins","args":""},"userType":"external","entrypoint":"sdk-cli","cwd":"/tmp/work","sessionId":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e","version":"2.1.304","gitBranch":"HEAD"}"#

    /// 本文の終わりの空行は、ライブの `content` では落ち、`local_command_source` と transcript には残る（`/context` で実測）
    static let liveContext = ###"{"type":"assistant","message":{"id":"c9faa2d9-d6d9-4f0e-97e4-8b0161d09def","model":"<synthetic>","role":"assistant","type":"message","content":[{"type":"text","text":"## Context Usage\n\n**Model:** claude-opus-5-5[1m]  \n**Tokens:** 27.9k / 350k (8%)\n\n### Skills\n\n| Skill | Source | Tokens |\n|-------|--------|--------|\n| xlsx | claude.ai sync | ~320 |"}]},"parent_tool_use_id":null,"local_command_source":"<local-command-stdout>## Context Usage\n\n**Model:** claude-opus-5-5[1m]  \n**Tokens:** 27.9k / 350k (8%)\n\n### Skills\n\n| Skill | Source | Tokens |\n|-------|--------|--------|\n| xlsx | claude.ai sync | ~320 |\n\n</local-command-stdout>","session_id":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e","uuid":"5c888d6a-dfea-4b73-a9da-c4f03325a882","timestamp":"2026-10-23T03:07:05.035Z","local_command_run":{"command":"context","args":""}}"###
    static let historyContext = ###"{"parentUuid":"e6fcdb81-48a6-4c26-a565-1c6fe29048d6","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>## Context Usage\n\n**Model:** claude-opus-5-5[1m]  \n**Tokens:** 27.9k / 350k (8%)\n\n### Skills\n\n| Skill | Source | Tokens |\n|-------|--------|--------|\n| xlsx | claude.ai sync | ~320 |\n\n</local-command-stdout>","level":"info","timestamp":"2026-10-23T03:07:05.035Z","uuid":"5c888d6a-dfea-4b73-a9da-c4f03325a882","isMeta":false,"commandRun":{"command":"context","args":""},"sessionId":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e"}"###

    /// 会話では開けない組み込み。ライブは `local_command_outcome`、transcript は `commandOutcome`
    static let liveUnavailable = #"{"type":"assistant","message":{"id":"35469bfd-a068-41c6-b3a1-853d03510ec1","model":"<synthetic>","role":"assistant","type":"message","content":[{"type":"text","text":"/theme isn't available in this environment."}]},"parent_tool_use_id":null,"local_command_source":"<local-command-stdout>/theme isn't available in this environment.</local-command-stdout>","session_id":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e","uuid":"ddf2a23e-2d73-4e57-8561-302dbff84ac3","timestamp":"2026-10-23T03:00:44.943Z","local_command_outcome":{"kind":"unavailable_headless"}}"#
    static let historyUnavailable = #"{"parentUuid":"8623a4e7-0c50-42a8-b252-4ead303da4d3","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>/theme isn't available in this environment.</local-command-stdout>","level":"info","timestamp":"2026-10-23T03:00:44.943Z","uuid":"ddf2a23e-2d73-4e57-8561-302dbff84ac3","isMeta":false,"commandOutcome":{"kind":"unavailable_headless"},"sessionId":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e"}"#
    /// 打った文そのもの。transcript だけに残り、ライブには来ない
    static let historyTyped = #"{"parentUuid":"36a290f3-42e4-4616-81e7-bef8cf1e5496","isSidechain":false,"type":"system","subtype":"local_command","content":"/theme","level":"info","timestamp":"2026-10-23T03:00:44.943Z","uuid":"8623a4e7-0c50-42a8-b252-4ead303da4d3","isMeta":false,"submitUuid":"c2703f0b-2025-4f6b-8bb8-13748e958b09","sessionId":"ee1db434-7a4a-4ea6-a8f4-c8923611c73e"}"#

    /// 端末（TUI）で打った local コマンド。出力に色・太字（SGR）・リンク（OSC）・単独の ESC が入る（`commandRun` 付き）
    static let historyTerminal = #"{"parentUuid":"e6fcdb81-48a6-4c26-a565-1c6fe29048d6","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout>Moved to \u001b[1m/tmp/work\u001b[22m\n\u001b[38;2;153;153;153m⛁ ⛁ \u001b[39m\u001b]8;;https://example.com\u0007link\u001b]8;;\u001b\\ x\u001by</local-command-stdout>","level":"info","timestamp":"2026-10-23T03:07:05.035Z","uuid":"0a0a0a0a-0000-4000-8000-000000000003","isMeta":false,"commandRun":{"command":"cd","args":""}}"#
    /// `/clear` は出力が空
    static let historyClear = #"{"parentUuid":"df3203e9-4c98-476d-a61e-bc2206d894a8","isSidechain":false,"type":"system","subtype":"local_command","content":"<local-command-stdout></local-command-stdout>","level":"info","timestamp":"2026-10-23T03:07:05.212Z","uuid":"61626831-e9a0-446f-a4a6-5bc4dd425fa7","isMeta":false,"commandRun":{"command":"clear","args":""},"sessionId":"51afdd33-f407-47dc-a5a3-a37b3109c71e"}"#
    /// ほかの outcome の kind（CLI の型にある `failed`）は、出た文をそのまま出す。型に無い kind の行は読み飛ばす
    static func history(kind: String) -> String {
        #"{"type":"system","subtype":"local_command","content":"<local-command-stdout>Plugin reload failed</local-command-stdout>","level":"info","timestamp":"2026-10-23T03:00:44.943Z","uuid":"0a0a0a0a-0000-4000-8000-000000000001","isMeta":false,"commandOutcome":{"kind":"\#(kind)"}}"#
    }
    /// 知らない subtype
    static let historyOther = #"{"type":"system","subtype":"informational","content":"something","level":"info","uuid":"0a0a0a0a-0000-4000-8000-000000000002","timestamp":"2026-10-23T03:00:44.943Z"}"#
}

private func live(_ line: String) -> [ChatMessage] {
    if case .messages(let messages, _, _) = ClaudeStreamParser.parse(Data(line.utf8)) { return messages }
    return []
}

private func history(_ line: String) -> [ChatMessage] {
    if case .messages(let messages) = TranscriptParser.parse(Data(line.utf8), index: 0) { return messages }
    return []
}

@Suite("local コマンドの出力を、ライブと履歴で同じ発言にする")
struct LocalCommandOutputTests {
    @Test("/reload-plugins：ライブの assistant と履歴の system/local_command が、同じ id・同じ中身の発言になる")
    func reload() {
        let fromLive = live(Fixture.liveReload)
        #expect(fromLive.count == 1)
        #expect(fromLive.first?.id == "36a290f3-42e4-4616-81e7-bef8cf1e5496#0")
        #expect(fromLive.first?.kind == .text)
        #expect(fromLive.first?.text == "Reloaded: 1 plugin · 0 skills · 5 agents · 0 hooks · 0 plugin LSP servers")
        #expect(history(Fixture.historyReload) == fromLive)
    }

    @Test("/context：本文の終わりの空行の有無が、ライブと履歴で食い違わない")
    func contextTrailingNewlines() {
        let fromLive = live(Fixture.liveContext)
        #expect(fromLive.count == 1)
        #expect(history(Fixture.historyContext) == fromLive)
        #expect(history(Fixture.historyContext).first?.text.hasSuffix("| xlsx | claude.ai sync | ~320 |") == true)
    }

    @Test("出力が空の local コマンド（/clear）は発言にしない")
    func emptyOutput() {
        #expect(history(Fixture.historyClear).isEmpty)
    }

    @Test("会話で使えない組み込み：英語の文を出さず、ライブも履歴も同じ知らせの行にする")
    func unavailableHeadless() {
        let fromLive = live(Fixture.liveUnavailable)
        #expect(fromLive.count == 1)
        #expect(fromLive.first?.id == "ddf2a23e-2d73-4e57-8561-302dbff84ac3#0")
        #expect(fromLive.first?.kind == .notice)
        #expect(fromLive.first?.text == "「/theme」は会話では使えません。")
        #expect(history(Fixture.historyUnavailable) == fromLive)
    }

    @Test("打った文だけの system/local_command（transcript にしか無い）は発言にしない")
    func typedLine() {
        #expect(history(Fixture.historyTyped).isEmpty)
    }

    @Test("outcome の kind：CLI の型にある failed は出た文を出し、知らない kind と知らない subtype は読み飛ばす")
    func otherOutcomes() {
        #expect(history(Fixture.history(kind: "failed")).map(\.text) == ["Plugin reload failed"])
        #expect(history(Fixture.history(kind: "something_new")).isEmpty)
        #expect(history(Fixture.historyOther).isEmpty)
    }

    @Test("端末の制御の並び（CSI・OSC・単独の ESC）は外す。TUI の transcript の出力に入る")
    func terminalControls() {
        #expect(history(Fixture.historyTerminal).map(\.text) == ["Moved to /tmp/work\n⛁ ⛁ link xy"])
    }
}
