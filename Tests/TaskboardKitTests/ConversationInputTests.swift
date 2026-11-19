import Foundation
import Testing

@testable import TaskboardKit

@Suite("会話の入力の決まり")
struct ConversationInputTests {
    @Test("権限：欄で選べるのは 5 つ（auto を含む）で、受け付けるのは dontAsk・manual を足した 7 つ。既定は確認なし")
    func permissions() {
        #expect(ConversationInput.permissionModes == ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])
        #expect(Set(ConversationInput.acceptedPermissionModes) == ["default", "acceptEdits", "plan", "auto", "bypassPermissions", "dontAsk", "manual"])
        #expect(ConversationInput.defaultPermissionMode == "bypassPermissions")
    }

    @Test("題：前後の空白と改行を落とし、空なら無し。人が付ける題は改行なしの 200 字まで（日本語も 1 字で数える）")
    func title() {
        #expect(ConversationInput.title("  会話の題\n") == "会話の題")
        #expect(ConversationInput.title(" \n ") == nil)
        #expect(ConversationInput.acceptsTitle(String(repeating: "題", count: 200)))
        #expect(!ConversationInput.acceptsTitle(String(repeating: "題", count: 201)))
        #expect(!ConversationInput.acceptsTitle(String(repeating: "a", count: 201)))
        #expect(!ConversationInput.acceptsTitle("1 行目\n2 行目"))
    }

    @Test("ほかの名前から作る題は、改行を空白にして 200 字で切る。空なら無し")
    func clippedTitle() {
        #expect(ConversationInput.clippedTitle("朝の\n見回り") == "朝の 見回り")
        #expect(ConversationInput.clippedTitle(String(repeating: "あ", count: 250)) == String(repeating: "あ", count: 200))
        #expect(ConversationInput.clippedTitle("\n\n") == nil)
        let clipped = ConversationInput.clippedTitle(" " + String(repeating: "x", count: 300))
        #expect(clipped.map(ConversationInput.acceptsTitle) == true)
    }

    @Test("使わせない tool：各値をカンマで分けて前後の空白を落とし、空を除いて --disallowedTools に続ける。名前が無ければ引数も無し")
    func disallowedTools() {
        #expect(ConversationInput.disallowedToolsArguments(["Agent", " Workflow , WebFetch", "Bash(rm:*)"]) == ["--disallowedTools", "Agent", "Workflow", "WebFetch", "Bash(rm:*)"])
        #expect(ConversationInput.disallowedToolsArguments(["", " , ", ","]) == [])
        #expect(ConversationInput.disallowedToolsArguments([]) == [])
    }

    @Test("答えの選択肢：選択肢に無い label と、単一選択の 2 つ以上は合わない。自由記述だけの答えは合う")
    func mismatch() {
        let single = AskQuestion(id: "q0", question: "色は？", options: [AskOption(label: "赤"), AskOption(label: "青")])
        let multi = AskQuestion(id: "q1", question: "どれ？", options: [AskOption(label: "A"), AskOption(label: "B")], multiSelect: true)
        #expect(single.mismatch(AskAnswer(questionID: "q0", selected: ["赤"])) == nil)
        #expect(single.mismatch(AskAnswer(questionID: "q0", selected: ["緑"])) == .unknownOption("緑"))
        #expect(single.mismatch(AskAnswer(questionID: "q0", selected: ["赤", "青"])) == .multiple)
        #expect(single.mismatch(AskAnswer(questionID: "q0", selected: [], freeText: "黄")) == nil)
        #expect(multi.mismatch(AskAnswer(questionID: "q1", selected: ["A", "B"])) == nil)
    }
}
