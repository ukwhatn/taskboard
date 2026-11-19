import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// Agent の呼び出しの下に畳んだサブエージェントの発言とツールを PNG で固定する。fixtures `chat-subagents` の w1:p1
/// （終わったサブエージェントは中に失敗したツール、実行中のサブエージェントは最後の呼び出しが実行中）。
/// ライト / ダークの 2 組。記録し直すときは suite の `record` を一時的に `.all` にして流す
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct ChatSubagentSnapshotTests {
    static func messages() async throws -> [ChatMessage] {
        AppDefaults.useScratch("snapshot")
        let model = AppModel(options: LaunchOptions(scenario: "chat-subagents"))
        let deadline = ContinuousClock.now + .seconds(5)
        while model.fixtureExtras.conversations["c-chat-subagents"] == nil {
            try #require(ContinuousClock.now < deadline, "fixtures chat-subagents の読み込みを待ち切れなかった")
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(model.fixtureExtras.conversations["c-chat-subagents"]).messages
    }

    /// 既定は畳む。題に件数と最後の呼び出しの名前、最後の呼び出しが実行中ならその印
    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func collapsed(variantName: String) async throws {
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: try await Self.messages())
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 520), variant: variant), named: variant.name)
    }

    /// 終わったサブエージェントを開いた形。依頼の文・発言・続いたツールの組（失敗の印）・最後の報告を本筋と同じ形で並べる
    @Test(arguments: ChatFilesSnapshotTests.variants.map(\.name))
    func expanded(variantName: String) async throws {
        let variant = try #require(ChatFilesSnapshotTests.variants.first { $0.name == variantName })
        let view = ChatTranscript(messages: try await Self.messages(), expandedTools: ["toolu_agent_load", "toolu_sb1"])
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: 560, height: 900), variant: variant), named: variant.name)
    }
}
