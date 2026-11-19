import Foundation
import TaskboardKit

extension ConversationFeed {
    /// 入力欄の `@` の候補。作業ディレクトリのファイルを daemon に引く（ssh の Mac も同じ経路）。fixtures は `workFiles` から。取れなければ nil
    func workFiles(matching query: String) async -> [WorkFile]? {
        if let fixtureTools {
            let lowered = query.lowercased()
            return fixtureTools.workFiles
                .filter { lowered.isEmpty || $0.lowercased().contains(lowered) }
                .prefix(ConversationWorkFilesResponse.defaultLimit)
                .map { WorkFile(path: $0, isDirectory: $0.hasSuffix("/")) }
        }
        guard let source else { return nil }
        return try? await source.conversationWorkFiles(key.id, query: query, limit: ConversationWorkFilesResponse.defaultLimit).files
    }
}
