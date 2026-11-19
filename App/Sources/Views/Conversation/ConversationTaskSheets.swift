import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// バックグラウンドのタスク（`/tasks`）。選んだタスクの出力の末尾と［停止］
struct ConversationTasksSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let feed: ConversationFeed
    @State private var selected: String?
    @State private var failure: String?

    /// `selected` は snapshot 用（出力を出しておくタスク）
    init(conversation: Conversation, feed: ConversationFeed, selected: String? = nil) {
        self.conversation = conversation
        self.feed = feed
        _selected = State(initialValue: selected)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "バックグラウンドのタスク"), subtitle: conversation.displayTitle, error: failure) {
            ConversationWakeGate(conversation: conversation, feed: feed) {
                switch feed.backgroundTasks {
                case .loaded(let list):
                    tasks(list)
                case .failed(let failure):
                    Section { Text(failure.text).foregroundStyle(.secondary) }
                default:
                    Section { ProgressView("読み込み中…").controlSize(.small) }
                }
            }
        } actions: {
            Button("再読み込み") {
                feed.load(waking: conversation) {
                    feed.loadBackgroundTasks()
                    if let selected { feed.loadTaskOutput(selected) }
                }
            }
            .disabled(feed.backgroundTasks.isLoading || feed.wake.isWaking)
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        #if os(macOS)
        .frame(minHeight: ConversationMetrics.contextSheetHeight)
        #endif
        .onAppear { feed.load(waking: conversation) { feed.loadBackgroundTasks() } }
        .onChange(of: feed.backgroundTasks.value?.tasks.first?.id, initial: true) { _, first in
            if selected == nil, let first { select(first) }
        }
    }

    @ViewBuilder
    private func tasks(_ list: ConversationBackgroundTasks) -> some View {
        if list.tasks.isEmpty {
            Section {
                Text(list.known ? "動いているタスクはありません" : "動いているタスクを確認できません").foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(list.tasks) { task in
                    Button {
                        select(task.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                            Image(systemName: selected == task.id ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Space.inline) {
                                Text(verbatim: task.description ?? task.id).lineLimit(2)
                                MetaLine(items: [ConversationReadoutText.taskType(task.type), task.backgrounded == false ? String(localized: "結果待ち") : nil, task.id].compactMap { $0 })
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == task.id ? .isSelected : [])
                }
            }
            if let selected {
                output(selected)
            }
        }
    }

    @ViewBuilder
    private func output(_ id: String) -> some View {
        Section {
            switch feed.taskOutputs[id] {
            case .loaded(let output):
                Text(verbatim: output.output.isEmpty ? String(localized: "まだ出力はありません") : output.output)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if output.truncated { Text("末尾の8KBだけを表示しています。").textRole(.caption) }
            case .failed(let failure):
                Text(failure.text).foregroundStyle(.secondary)
            default:
                ProgressView("読み込み中…").controlSize(.small)
            }
            if conversation.phase != .stopped, feed.backgroundTasks.value?.tasks.contains(where: { $0.id == id }) == true {
                Button("停止", role: .destructive) { stop(id) }
            }
        } header: {
            Text("出力")
        }
    }

    private func select(_ id: String) {
        selected = id
        feed.loadTaskOutput(id)
    }

    private func stop(_ id: String) {
        failure = nil
        Task {
            do {
                try await feed.stopTask(id)
            } catch {
                failure = UserFacingError("タスクを停止できませんでした", error: error)?.text
            }
        }
    }
}

/// 会話に残さない質問（`/btw`）。答えは会話の記録に入らない
struct ConversationSideQuestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let feed: ConversationFeed
    @State private var question: String
    @State private var answer: String?
    @State private var asking = false
    @State private var failure: String?

    init(conversation: Conversation, feed: ConversationFeed, question: String, answer: String? = nil) {
        self.conversation = conversation
        self.feed = feed
        _question = State(initialValue: question)
        _answer = State(initialValue: answer)
    }

    var body: some View {
        SheetScaffold(title: String(localized: "会話に残さない質問"), subtitle: conversation.displayTitle, error: failure) {
            Section {
                LabeledTextField(label: String(localized: "質問"), text: $question)
                    .onSubmit { ask() }
            } footer: {
                Text("会話の内容をもとに答えます。質問と答えは会話に残りません。")
            }
            if asking {
                Section { ProgressView("回答を待っています…").controlSize(.small) }
            } else if let answer {
                Section("回答") {
                    Text(verbatim: answer).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } actions: {
            Button("閉じる") { dismiss() }
            Button("送信") { ask() }
                .keyboardShortcut(.defaultAction)
                .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || conversation.phase == .stopped)
        }
        .onAppear {
            if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer == nil { ask() }
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        failure = nil
        asking = true
        Task {
            do {
                answer = try await feed.askSide(text)
            } catch {
                failure = UserFacingError("質問できませんでした", error: error)?.text
            }
            asking = false
        }
    }
}
