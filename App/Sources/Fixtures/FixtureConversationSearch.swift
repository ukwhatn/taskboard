import Foundation
import TaskboardKit

/// fixtures の会話（`conversationChats`）の発言を、daemon の索引と同じ規則で引く
extension FixtureSource: ConversationSearchSource {
    func searchConversations(query: String, limit: Int) async throws -> ConversationSearchResponse {
        let terms = ConversationSearchQuery.terms(query)
        let hits = extras.conversations.compactMap { id, conversation -> ConversationSearchHit? in
            let found = conversation.messages.filter { ConversationSearchQuery.indexes($0) && ConversationSearchQuery.matches($0.text, terms: terms) }
            guard let last = found.last else { return nil }
            return ConversationSearchHit(
                conversationID: id, messageID: last.id, role: last.role, at: last.at, snippet: ConversationSearchQuery.snippet(last.text, terms: terms),
                matches: found.count)
        }
        let ordered = hits.sorted { ($0.at ?? .distantPast, $0.conversationID) > ($1.at ?? .distantPast, $1.conversationID) }
        return ConversationSearchResponse(hits: Array(ordered.prefix(limit)), indexing: false)
    }
}
