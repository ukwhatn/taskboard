import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// コメントの入力欄。引用があれば上に出す。失敗したら書いた文を残して下に知らせる
struct CommentComposer: View {
    @Binding var composer: DocumentScreen.Composer
    let submit: (DocumentScreen.Composer) async -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            if let anchor = composer.anchor {
                Quote(text: anchor.exact)
            } else {
                Text("文書全体へのコメント").textRole(.caption)
            }
            MultilineTextField(label: String(localized: "コメント"), placeholder: String(localized: "コメント"), text: $composer.text, lines: 2...8, style: .roundedBorder)
                .focused($focused)
            if let failure = composer.failure {
                FailureText(failure)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: cancel).buttonStyle(.borderless).hitTarget()
                Button("下書きに追加") {
                    sending = true
                    Task {
                        await submit(composer)
                        sending = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(sending || composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.card)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onAppear { focused = true }
    }
}

/// 文書の本文で選んだ所の下に浮かせる［コメント］。下に入らなければ上に出す。選んだ所の枠が変わる（スクロール）たびに描き直すので、枠はここでだけ読む
struct FloatingCommentButton: View {
    let web: DocumentWebController
    let start: (CGRect) -> Void
    @State private var size: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            if let rect = web.selectionRect, rect.maxY > 0, rect.minY < proxy.size.height {
                let below = rect.maxY + Space.inline
                let y = below + size.height <= proxy.size.height ? below : max(rect.minY - Space.inline - size.height, 0)
                Button { start(rect) } label: {
                    Label("コメント", systemImage: "plus.bubble")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.row)
                        .frame(minHeight: HitTarget.size)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("選んだ所にコメント")
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                .offset(x: min(max(rect.minX, 0), max(proxy.size.width - size.width, 0)), y: y)
            }
        }
    }
}

/// 本文から引いた文
struct Quote: View {
    let text: String
    var lineLimit = 3

    var body: some View {
        Text(text).font(.callout).italic().foregroundStyle(.secondary).lineLimit(lineLimit)
            .padding(.leading, Space.row)
            .overlay(alignment: .leading) { Rectangle().fill(Color.orange.opacity(0.6)).frame(width: 2) }
    }
}

/// コメントのスレッド。下書き → 未解決 → 解決済み の順。引用を押すと本文のその場所へ送る
struct CommentsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window
    @Binding var comments: [DocComment]
    let machine: MachineID
    @Binding var active: Int64?
    let showInBody: (Int64) -> Void

    /// 返信の書きかけ（コメントごと）
    @State private var replies: [Int64: String] = [:]
    @State private var replyFailures: [Int64: UserFacingError] = [:]
    @State private var deleteTarget: DocComment?

    var body: some View {
        let ordered = comments.sorted { a, b in
            if a.state != b.state { return Self.rank(a.state) < Self.rank(b.state) }
            return a.createdAt < b.createdAt
        }
        VStack(alignment: .leading, spacing: Space.block) {
            Text(comments.isEmpty ? String(localized: "コメント") : String(localized: "コメント\(comments.count)件")).textRole(.sectionTitle)
            if comments.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("コメントはありません").textRole(.secondary)
                    Text("本文を選んで［コメントを追加］を押すと付けられます。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(ordered) { comment in
                card(comment)
            }
        }
        .preference(key: DocumentPendingInputKey.self, value: replies.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        .confirmationDialog(
            "コメントの削除", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible, presenting: deleteTarget
        ) { comment in
            Button("削除", role: .destructive) { delete(comment) }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("下書きのコメントを削除しますか？　この操作は元に戻せません。")
        }
    }

    private func card(_ comment: DocComment) -> some View {
        VStack(alignment: .leading, spacing: Space.row) {
            HStack(alignment: .firstTextBaseline, spacing: Space.inline) {
                Image(systemName: Self.symbol(comment.state)).foregroundStyle(Self.color(comment.state)).font(.caption).accessibilityHidden(true)
                MetaLine(items: [Self.stateLabel(comment.state), String(localized: "第\(comment.rev)版")])
                Spacer(minLength: 0)
                switch comment.state {
                case .draft:
                    Button("削除", role: .destructive) { deleteTarget = comment }.buttonStyle(.borderless).controlSize(.small).hitTarget()
                case .open:
                    Button("解決") { setResolved(comment, true) }.buttonStyle(.borderless).controlSize(.small).hitTarget()
                case .resolved:
                    Button("未解決に戻す") { setResolved(comment, false) }.buttonStyle(.borderless).controlSize(.small).hitTarget()
                }
            }
            if let anchor = comment.anchor {
                Button { showInBody(comment.id) } label: { Quote(text: anchor.exact, lineLimit: 2) }
                    .buttonStyle(.plain)
                    .help("本文のこの場所を見る")
                    .accessibilityHint("押すと本文のこの場所を見ます")
            }
            Text(comment.body).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            ForEach(comment.replies) { reply in
                HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                    Image(systemName: reply.author == .agent ? "cpu" : "person").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(reply.author == .agent ? "セッション" : "自分")
                    Text(reply.body).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if reply.state == .draft { Text("下書き").textRole(.caption) }
                }
                .padding(.leading, Space.block)
            }
            if comment.state != .draft {
                replyArea(comment)
            }
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active == comment.id ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    @ViewBuilder
    private func replyArea(_ comment: DocComment) -> some View {
        if let text = replies[comment.id] {
            VStack(alignment: .leading, spacing: Space.inline) {
                MultilineTextField(
                    label: String(localized: "返信"), placeholder: String(localized: "返信"), text: Binding(get: { text }, set: { replies[comment.id] = $0 }), lines: 1...4,
                    font: .callout, style: .roundedBorder)
                if let failure = replyFailures[comment.id] {
                    FailureText(failure)
                }
                HStack {
                    Spacer()
                    Button("キャンセル") {
                        replies[comment.id] = nil
                        replyFailures[comment.id] = nil
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .hitTarget()
                    Button("返信") { reply(comment, text) }
                        .controlSize(.small)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.leading, Space.block)
        } else {
            Button("返信") { replies[comment.id] = "" }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .hitTarget()
                .padding(.leading, Space.block)
        }
    }

    // MARK: 操作（返ってきた値で一覧を直す。読み直しは文書の件数の変化で起きる）

    private func reply(_ comment: DocComment, _ text: String) {
        Task {
            do {
                let added = try await model.replyComment(comment, on: machine, body: text)
                if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index].replies.append(added) }
                replies[comment.id] = nil
                replyFailures[comment.id] = nil
            } catch {
                replyFailures[comment.id] = UserFacingError("返信を追加できませんでした", error: error)
            }
        }
    }

    private func setResolved(_ comment: DocComment, _ resolved: Bool) {
        Task {
            do {
                let updated = try await model.resolveComment(comment, on: machine, resolved)
                if let index = comments.firstIndex(where: { $0.id == comment.id }) { comments[index] = updated }
            } catch {
                model.fail(resolved ? "コメントを解決にできませんでした" : "コメントを未解決に戻せませんでした", error, in: window)
            }
        }
    }

    private func delete(_ comment: DocComment) {
        Task {
            do {
                try await model.deleteComment(comment, on: machine)
                comments.removeAll { $0.id == comment.id }
            } catch {
                model.fail("コメントを削除できませんでした", error, in: window)
            }
        }
    }

    static func rank(_ state: DocComment.State) -> Int {
        switch state {
        case .draft: 0
        case .open: 1
        case .resolved: 2
        }
    }

    static func symbol(_ state: DocComment.State) -> String {
        switch state {
        case .draft: "pencil"
        case .open: "bubble.left.fill"
        case .resolved: "checkmark.circle.fill"
        }
    }

    static func color(_ state: DocComment.State) -> Color {
        switch state {
        case .draft: .secondary
        case .open: .orange
        case .resolved: .green
        }
    }

    static func stateLabel(_ state: DocComment.State) -> String {
        switch state {
        case .draft: String(localized: "下書き")
        case .open: String(localized: "未解決")
        case .resolved: String(localized: "解決済み")
        }
    }
}
