import SwiftUI
import TaskboardKit

/// PR の中身を取って出す。一覧の右・iPhone の push・タスクの PR の節で共用。
/// 一覧の値が新しくなったら（`updatedAt`）取り直す
struct PRDetailView: View {
    @Environment(AppModel.self) private var model
    let url: String
    var preferring: MachineID?
    /// false ならスクロールしない（タスクの詳細の欄に入れるとき）
    var scrolls = true
    /// 開いているタスク。紐づくタスクの一覧から外す
    var currentTask: TaskKey?

    @State private var detail: PullRequestDetail?
    @State private var failure: UserFacingError?
    @State private var loading = false

    var body: some View {
        let summary = model.fleet.pullRequest(url: url)
        let tasks = model.tasks(linkedTo: url).filter { $0.id != currentTask }
        Group {
            if let shown = detail ?? summary.map(PRDetailContent.placeholder(from:)) {
                PRDetailContent(
                    detail: shown, scrolls: scrolls, linkedTasks: tasks, linkedWork: model.workItems(delivering: url), loading: detail == nil && loading,
                    failure: failure, reload: { Task { await load() } }, inTask: currentTask != nil
                ) { model.navigate(to: .task($0.id), from: .link) }
            } else if let failure, !scrolls {
                // 詳細の欄の中では帯にする（空状態の大きさは欄に合わない）
                Banner(kind: .error, message: failure.text) {
                    Button("再読み込み") { Task { await load() } }.controlSize(.small)
                    if let link = URL(string: url) { Link("GitHubで開く", destination: link).font(.callout) }
                }
            } else if let failure {
                EmptyState(title: "PRを表示できません", symbol: "exclamationmark.triangle", message: failure.detail) {
                    Button("再読み込み") { Task { await load() } }
                    if let link = URL(string: url) { Link("GitHubで開く", destination: link) }
                }
            } else {
                ProgressView("読み込み中…").frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: "\(url)/\(summary?.updatedAt.timeIntervalSince1970 ?? 0)") { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            detail = try await model.pullRequestDetail(url: url, preferring: preferring)
            failure = nil
        } catch {
            failure = UserFacingError("PRの中身を取得できませんでした", error: error)
        }
    }
}

/// PR の中身（取得済みの値を描くだけ。snapshot test もここを描く）。置かれた欄の余白に揃い、自分では左右の余白を持たない
struct PRDetailContent: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.pageInset) private var inset
    let detail: PullRequestDetail
    var scrolls = true
    var linkedTasks: [BoardTask] = []
    /// この PR を成果物にした作業項目（タスクの下に並べる）
    var linkedWork: [WorkItem] = []
    /// 一覧の値だけを出していて、中身を取りに行っている
    var loading = false
    var failure: UserFacingError?
    var reload: () -> Void = {}
    /// タスクの PR の節で出している（紐づくタスクの見出しを「ほかのタスク」にする）
    var inTask = false
    var openTask: (BoardTask) -> Void = { _ in }

    var body: some View {
        if scrolls {
            ScrollView {
                sections.frame(maxWidth: ReadableWidth.text, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, inset)
                    .padding(.vertical, Space.section)
            }
        } else {
            sections
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            header
            if let failure {
                Banner(kind: .error, message: failure.text) {
                    Button("再読み込み", action: reload).controlSize(.small)
                }
            } else if loading {
                ProgressView("読み込み中…").controlSize(.small)
            }
            if !linkedTasks.isEmpty { tasksSection }
            if !detail.body.isEmpty {
                PageSection("説明") {
                    Card { MarkdownView(detail.body, html: .text).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            if !detail.checks.isEmpty { checksSection }
            if !detail.reviews.isEmpty { reviewsSection }
            if !detail.files.isEmpty { filesSection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.row) {
            FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                Text(detail.shortLabel).font(.caption.monospaced()).foregroundStyle(.secondary)
                stateChip
                if let checks = detail.checkState {
                    Chip(text: checks.label, symbol: checks.symbol, tint: checks.color)
                }
                if let (text, color) = ReviewBadge.describe(decision: detail.decision, reviews: detail.reviews.map(\.reviewState)) {
                    Chip(text: text, tint: color)
                }
                if detail.mergeable == "CONFLICTING" {
                    Chip(text: String(localized: "コンフリクトあり"), symbol: "exclamationmark.triangle", tint: .red)
                }
            }
            Text(detail.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            MetaLine(items: [
                detail.author,
                detail.baseRef.isEmpty ? detail.headRef : "\(detail.headRef) → \(detail.baseRef)",
                "+\(detail.additions) −\(detail.deletions)",
                String(localized: "\(detail.changedFiles)ファイル"),
            ] + (detail.commentCount > 0 ? [String(localized: "コメント\(detail.commentCount)件")] : []))
            if let url = URL(string: detail.url) {
                Button("GitHubで開く", systemImage: "arrow.up.right.square") { openURL(url) }
                    .controlSize(.small)
            }
        }
    }

    private var stateChip: some View {
        let (text, color) = PullRequestLinkState.State.badge(.init(github: detail.state), isDraft: detail.isDraft)
        return Chip(text: text, tint: color)
    }

    private var tasksSection: some View {
        PageSection(inTask ? String(localized: "ほかのタスク") : String(localized: "タスク")) {
            VStack(alignment: .leading, spacing: Space.row) {
                ForEach(linkedTasks) { task in
                    Button {
                        openTask(task)
                    } label: {
                        Label("#\(task.number) \(task.title)", systemImage: "rectangle.on.rectangle").font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.borderless)
                    ForEach(linkedWork.filter { $0.machine == task.machine && $0.taskNumber == task.number }) { item in
                        MetaLine(items: [item.codedTitle, WorkItemGlyph.title(item.state.display)])
                    }
                }
            }
        }
    }

    private var checksSection: some View {
        PageSection(String(localized: "チェック\(detail.checks.count)件")) {
            VStack(alignment: .leading, spacing: Space.row) {
                ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
                    let name = [check.workflow, check.name].compactMap { $0 }.joined(separator: " / ")
                    HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                        Image(systemName: check.runState.symbol).foregroundStyle(check.runState.color).accessibilityHidden(true)
                        Text(name).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Text(check.runState.label).textRole(.caption)
                        if let link = check.url.flatMap(URL.init(string:)) {
                            Button("開く", systemImage: "arrow.up.right") { openURL(link) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .hitTarget()
                                .accessibilityLabel("「\(name)」をGitHubで開く")
                                .help("GitHubで開く")
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var reviewsSection: some View {
        PageSection(String(localized: "レビュー\(detail.reviews.count)件")) {
            VStack(alignment: .leading, spacing: Space.block) {
                ForEach(Array(detail.reviews.enumerated()), id: \.offset) { _, review in
                    VStack(alignment: .leading, spacing: Space.inline) {
                        HStack(spacing: Space.row) {
                            Text(review.author).font(.callout.weight(.medium))
                            Text(review.reviewState.label).font(.caption).foregroundStyle(review.reviewState.color)
                        }
                        if !review.body.isEmpty {
                            MarkdownView(review.body, html: .text).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var filesSection: some View {
        PageSection(String(localized: "変更ファイル\(detail.changedFiles)件")) {
            VStack(alignment: .leading, spacing: Space.inline) {
                ForEach(detail.files, id: \.path) { file in
                    HStack(spacing: Space.row) {
                        Text(file.kind.mark).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .accessibilityLabel(file.kind.name)
                            .help(file.kind.name)
                        Text(file.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        Text("+\(file.additions)").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.added)
                        Text("−\(file.deletions)").font(.caption.monospacedDigit()).foregroundStyle(DiffPalette.removed)
                    }
                }
                if detail.files.count < detail.changedFiles, let url = URL(string: detail.url + "/files") {
                    Link(String(localized: "ほか\(detail.changedFiles - detail.files.count)件をGitHubで見る"), destination: url).font(.callout)
                }
            }
        }
    }

    // MARK: 変換

    /// 一覧の値だけで作る中身（本文・チェック明細・ファイルは空）。一覧に載るのは開いている PR だけなので、状態は Open
    static func placeholder(from pr: PullRequestSummary) -> PullRequestDetail {
        PullRequestDetail(
            url: pr.url, repository: pr.repository, number: pr.number, title: pr.title, author: pr.author, state: "OPEN", isDraft: pr.isDraft,
            body: "", baseRef: "", headRef: pr.headRef, createdAt: pr.createdAt, updatedAt: pr.updatedAt, reviewDecision: pr.reviewDecision,
            checkState: pr.checks, additions: pr.additions, deletions: pr.deletions, changedFiles: pr.changedFiles,
            reviews: pr.latestReviews.map { PullRequestDetail.Review(author: $0.login, state: $0.state, body: "") }, fetchedAt: pr.updatedAt)
    }
}

/// タスクの PR の節。紐づく PR が複数なら横並びのチップで切り替える（右クリックで外す）。見出しの PR のチップを押すと、その PR に切り替わる
struct TaskPRPane: View {
    @Environment(AppModel.self) private var model
    let task: BoardTask
    @TaskState private var selected: String?

    var body: some View {
        let links = task.pullRequestLinks
        let url = links.first { $0.url == selected }?.url ?? links.first { $0.url == model.selectedPR }?.url ?? links.first?.url
        VStack(alignment: .leading, spacing: Space.block) {
            if links.count > 1 {
                FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
                    ForEach(links) { link in
                        ChipButton(text: link.shortLabel, symbol: "arrow.triangle.pull", selected: link.url == url) { selected = link.url }
                            .contextMenu { TaskLinkMenuItems(task: task, link: link) }
                    }
                }
            }
            if let url {
                PRDetailView(url: url, preferring: task.machine, scrolls: false, currentTask: task.id).id(url)
            }
        }
        // 見出しの PR のチップを押したら、そちらを出す（6-7）
        .onChange(of: model.prFocusRequest) { _, _ in
            if let pr = model.selectedPR, links.contains(where: { $0.url == pr }) { selected = pr }
        }
    }
}
