import Foundation
import TaskboardKit
import Testing
@testable import Taskboard

/// 会話の［終了］は確認を出さない。会話を止める操作は画面に無い
@MainActor
@Suite struct ConversationEndTests {
    private func model() async throws -> (AppModel, WindowID) {
        let model = try await ConversationSnapshotTests.loadedModel()
        let window = WindowID()
        model.activate(window)
        return (model, window)
    }

    @Test("終了: タスクに結ばれていてもいなくても確かめずに終える")
    func closeWithoutConfirmation() async throws {
        let (model, window) = try await model()
        for id in ["c-gen", "c-orch", "c-stop"] {
            let key = try ConversationSnapshotTests.key(model, id)
            model.close(conversation: key)
            #expect(model.confirmation(in: window) == nil, "\(id)")
        }
    }
}
