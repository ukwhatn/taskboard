import Foundation
import Testing
import TaskboardKit

@testable import TaskboardDaemon

@Suite("AskUserQuestion の選択肢の見本と推奨")
struct ClaudeAskPreviewTests {
    @Test("選択肢の preview をそのまま問いに載せ、(Recommended) の付いた label は送る形のまま残す")
    func keepsPreview() throws {
        let input = #"{"questions":[{"question":"どちらの並びにしますか","header":"並び","options":[{"label":"3 列にする (Recommended)","description":"幅が広い画面向け","preview":"| a | b | c |\n|---|---|---|"},{"label":"2 列にする"}],"multiSelect":false}]}"#
        let request = ClaudeRequests.make(
            id: "r1", toolName: "AskUserQuestion", toolUseID: "toolu_q", inputJSON: input, description: nil, since: Date(timeIntervalSince1970: 0))
        let options = try #require(request.waiting.questions?.first?.options)
        #expect(options[0].preview == "| a | b | c |\n|---|---|---|")
        #expect(options[0].label == "3 列にする (Recommended)" && options[0].isRecommended && options[0].displayLabel == "3 列にする")
        #expect(options[1].preview == nil && !options[1].isRecommended)
    }
}
