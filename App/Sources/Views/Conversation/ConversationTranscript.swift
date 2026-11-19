import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// 会話の発言の列。発言・生成中・先に出した発言を読むのはここだけにする（会話の画面の本体が読むと、生成中の差分のたびに上の帯と入力欄まで描き直した）。
/// 発言は自分の body で feed から読むので、渡す値が同じなら作り直さない（閉じは比べられず、会話の画面が走るたびに 1,500 件の一覧を組み直していた）
struct ConversationTranscript: View, @MainActor Equatable {
    let feed: ConversationFeed
    let fontSize: Double
    let search: ChatSearch?
    let messageActions: ChatMessageActions?
    let codeRun: CodeRunActions
    /// 待機中の発言を入力欄の上のカードに出す engine か（カードに出す分は列に並べない）
    let queuesMessages: Bool
    let openedFile: String?
    let openFile: (ChatFileRef) -> Void
    let activity: ConversationActivity?
    let stopGenerating: (() -> Void)?
    let backgroundTasks: ChatBackgroundTasks
    let jump: ChatJumpRequest
    /// 閉じ（フォーク・巻き戻し・Run）は会話の画面の状態を参照で読むので、比べるのは有無と見た目に効く値だけ
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.feed === rhs.feed && lhs.fontSize == rhs.fontSize && lhs.search == rhs.search && lhs.queuesMessages == rhs.queuesMessages
            && lhs.openedFile == rhs.openedFile && lhs.activity == rhs.activity && (lhs.stopGenerating == nil) == (rhs.stopGenerating == nil)
            && lhs.backgroundTasks == rhs.backgroundTasks && lhs.jump == rhs.jump
            && lhs.messageActions?.rewindBlocked == rhs.messageActions?.rewindBlocked && lhs.messageActions?.revealed == rhs.messageActions?.revealed
            && lhs.messageActions?.forkPoints == rhs.messageActions?.forkPoints
            && (lhs.messageActions == nil) == (rhs.messageActions == nil) && (lhs.messageActions?.rewind == nil) == (rhs.messageActions?.rewind == nil)
    }

    var body: some View {
        ChatTranscript(
            messages: feed.messages, fontSize: fontSize, search: search, backlogs: feed.reloads, openedFile: openedFile, openFile: openFile, streaming: feed.streaming, reveal: feed.reveal, outgoing: queuesMessages ? feed.outgoing.filter { $0.state != .queued } : feed.outgoing,
            activity: activity, stopGenerating: stopGenerating,
            retry: { feed.retry($0) }, reachedTop: feed.historyState == .more ? { feed.loadOlder() } : nil, loadingOlder: feed.loadingOlder,
            messageActions: messageActions, codeRun: codeRun, backgroundTasks: backgroundTasks, jump: jump
        )
    }
}

/// 会話の検索の欄。一致を数えるのに発言を読むので、欄を開いている間だけ出す別の View にする（本体は発言を読まない）
struct ConversationSearchBar: View {
    let feed: ConversationFeed
    @Binding var search: ChatSearch
    let size: Double
    var focused: FocusState<Bool>.Binding

    var body: some View {
        ChatSearchBar(search: $search, messages: feed.messages, size: size, focused: focused)
    }
}
