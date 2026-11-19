import Foundation
import TaskboardKit

extension WorktreeCleaner {
    /// daemon の実データから組む。repo は、会話の cwd・会話の記録の cwd・作業ディレクトリのブックマークと最近のもの・worktree の置き場の下から探す
    static func live(store: Store, conversations: ConversationService, home: String = NSHomeDirectory()) -> WorktreeCleaner {
        WorktreeCleaner(
            sources: Sources(
                directories: {
                    var directories = ((try? store.conversations()) ?? []).map(\.cwd)
                    if let known = try? store.workingDirectories() { directories += known.candidates }
                    return directories + placedCheckouts(home: home)
                },
                occupants: {
                    await conversations.list().filter { !$0.isClosed }.map { conversation in
                        Occupant(cwds: [conversation.cwd], user: WorktreeUser(kind: .conversation, id: conversation.id, title: conversation.title))
                    }
                }))
    }

    /// 置き場の `<repo>/<branch>`。会話の記録が消えた worktree も一覧に出す（`~/.herdr/worktrees` は前の版の会話が作った分）
    static func placedCheckouts(home: String) -> [String] {
        func children(_ path: String) -> [String] {
            let names: [String] = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return names.map { "\(path)/\($0)" }
        }
        let roots: [String] = [GitWorktrees.root(home: home), home + "/.herdr/worktrees"]
        return roots.flatMap(children).flatMap(children)
    }
}
