import AppKit
import SnapshotTesting
import SwiftUI
import TaskboardKit
import Testing
@testable import Taskboard

/// Claude の権限の確認に、CLI が出した「今後は聞かない」候補がつくカード
@MainActor
@Suite(.serialized, .snapshots(record: .missing))
struct PermissionSuggestionSnapshotTests {
    typealias Matrix = LayoutMatrixSnapshotTests

    private func request(suggestions: [PermissionSuggestion]?) -> ConversationRequest {
        let waiting = RequestWaiting(id: "tu1", since: Date(timeIntervalSince1970: 0), permission: .init(tool: "Bash", summary: "npm test -- search-index", detail: "検索の索引のテストを回す"))
        return ConversationRequest(id: "r1", kind: .permission, toolName: "Bash", toolUseID: "tu1", waiting: waiting, suggestions: suggestions)
    }

    @Test("承認のカード（候補があれば［常に許可］のメニューが［拒否］と［許可］の間に付く）", arguments: ["with", "without"].flatMap { kind in Matrix.cases([560, 360]).map { "\(kind)|\($0)" } })
    func card(argument: String) async throws {
        let parts = argument.split(separator: "|").map(String.init)
        let (width, appearance) = try Matrix.parse(parts[1])
        let suggestions = [PermissionSuggestion(id: "0", kind: .rule, subject: "Bash(npm test:*)", scope: .folder)]
        let view = VStack {
            ConversationRequestPanel(
                request: request(suggestions: parts[0] == "with" ? suggestions : nil), machine: MachineID(rawValue: "fixture-studio"), blocked: nil,
                fetchURL: { _ in URL(fileURLWithPath: "/") }, answer: { _ in })
            Spacer()
        }
        .padding(Space.card)
        assertImageSnapshot(of: BoardSnapshotTests.host(view, size: CGSize(width: width, height: 240), variant: appearance), named: "\(parts[0])-\(parts[1])")
    }

    @Test("メニューの 1 行は、何を許可し、どこに残すかを言う")
    func menuLabels() {
        func label(_ kind: PermissionSuggestion.Kind, _ subject: String, _ scope: PermissionSuggestion.Scope) -> String {
            PermissionSuggestion(id: "0", kind: kind, subject: subject, scope: scope).menuLabel
        }
        #expect(label(.rule, "Bash(npm test:*)", .folder) == "Bash(npm test:*)を許可（このフォルダの設定に保存）")
        #expect(label(.rule, "WebFetch", .session) == "WebFetchを許可（この会話の間）")
        #expect(label(.rule, "Bash(ls)", .project) == "Bash(ls)を許可（プロジェクトの設定に保存）")
        #expect(label(.rule, "Bash(ls)", .user) == "Bash(ls)を許可（すべてのプロジェクトで）")
        #expect(label(.directory, "/w/docs", .session) == "/w/docsへのアクセスを許可（この会話の間）")
        #expect(label(.mode, "acceptEdits", .session) == "権限を「編集は自動で許可」に変更（この会話の間）")
    }
}
