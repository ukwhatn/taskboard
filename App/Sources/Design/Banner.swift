import SwiftUI
import TaskboardKit

// MARK: - 帯

/// 全幅の帯（待ち理由、エラー、知らせ）。文は折り返して全文を出す
struct Banner<Actions: View>: View {
    enum Kind {
        /// 自分の番（応答、承認、質問）
        case waiting
        /// 相手や外部を待っている
        case pending
        case error, notice, success

        var color: Color {
            switch self {
            case .waiting: .orange
            case .pending: .secondary
            case .error: .red
            case .notice: .accentColor
            case .success: .green
            }
        }

        var symbol: String {
            switch self {
            case .waiting: "hand.raised.fill"
            case .pending: "hourglass"
            case .error: "exclamationmark.triangle.fill"
            case .notice: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            }
        }
    }

    let kind: Kind
    let message: String
    var detail: String?
    var onClose: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        BannerLayout(spacing: Space.row) {
            icon.layoutValue(key: BannerLayout.Part.self, value: .icon)
            texts.layoutValue(key: BannerLayout.Part.self, value: .texts)
            HStack(spacing: Space.row) { actions }.layoutValue(key: BannerLayout.Part.self, value: .actions)
            closeButton.layoutValue(key: BannerLayout.Part.self, value: .close)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

extension Banner {
    private var icon: some View {
        Image(systemName: kind.symbol).foregroundStyle(kind.color).accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message).textRole(.body)
            if let detail { Text(detail).textRole(.secondary) }
        }
    }

    @ViewBuilder
    private var closeButton: some View {
        if let onClose {
            Button(action: onClose) { Image(systemName: "xmark").imageScale(.small) }
                .buttonStyle(.borderless)
                .hitTarget()
                .accessibilityLabel("閉じる")
        }
    }
}

extension Banner where Actions == EmptyView {
    init(kind: Kind, message: String, detail: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(kind: kind, message: message, detail: detail, onClose: onClose) { EmptyView() }
    }
}

/// 帯の並び。文と操作が 1 行に入れば操作と閉じるを右端に、入らなければ文を折り返して操作をその下に置く（狭い欄で文が縦に潰れないように）。
/// ViewThatFits で 2 つの形を並べると、両方の形を作って測るので帯 1 本で 15 ms ほどかかり、ボタンも 2 つずつ作られた
struct BannerLayout: Layout {
    enum Part: LayoutValueKey {
        case icon, texts, actions, close
        static let defaultValue = Part.texts
    }

    var spacing: CGFloat

    /// 文と、右端の操作・閉じるのあいだに最低限あける幅
    private var gap: CGFloat { spacing * 3 }

    struct Cache {
        var icon: Int?
        var texts: Int?
        var actions: Int?
        var close: Int?
        var natural: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache(natural: subviews.map { $0.sizeThatFits(.unspecified) })
        for index in subviews.indices {
            switch subviews[index][Part.self] {
            case .icon: cache.icon = index
            case .texts: cache.texts = index
            case .actions: cache.actions = cache.natural[index].width > 0 ? index : nil
            case .close: cache.close = index
            }
        }
        return cache
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? oneRowWidth(cache)
        let frames = arrange(width: width, subviews: subviews, cache: cache)
        return CGSize(width: width, height: frames.map(\.frame.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frames = arrange(width: bounds.width, subviews: subviews, cache: cache)
        for index in subviews.indices {
            // 中身の無い操作の並びは大きさ 0 で左上に置く（置かないと、帯の真ん中に置かれる）
            let frame = frames.first { $0.index == index }?.frame ?? .zero
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    /// 1 行に並べたときの幅（文は折り返さない）
    private func oneRowWidth(_ cache: Cache) -> CGFloat {
        let leading = [cache.icon, cache.texts].compactMap { $0 }.map { cache.natural[$0].width }
        let trailing = [cache.actions, cache.close].compactMap { $0 }.map { cache.natural[$0].width }
        let leadingWidth = leading.reduce(0, +) + spacing * CGFloat(max(leading.count - 1, 0))
        guard !trailing.isEmpty else { return leadingWidth }
        return leadingWidth + gap + trailing.reduce(0, +) + spacing * CGFloat(trailing.count - 1)
    }

    /// 各部品の位置。行の中は文の 1 行目の baseline に揃える
    private func arrange(width: CGFloat, subviews: Subviews, cache: Cache) -> [(index: Int, frame: CGRect)] {
        let iconSize = cache.icon.map { cache.natural[$0] } ?? .zero
        let closeSize = cache.close.map { cache.natural[$0] } ?? .zero
        let textsX = cache.icon == nil ? 0 : iconSize.width + spacing
        var placed: [(index: Int, size: CGSize, x: CGFloat, line: Int)] = []
        if oneRowWidth(cache) <= width {
            if let icon = cache.icon { placed.append((icon, iconSize, 0, 0)) }
            if let texts = cache.texts { placed.append((texts, cache.natural[texts], textsX, 0)) }
            var x = width
            if let close = cache.close {
                x -= closeSize.width
                placed.append((close, closeSize, x, 0))
                x -= spacing
            }
            if let actions = cache.actions {
                let size = cache.natural[actions]
                placed.append((actions, size, x - size.width, 0))
            }
        } else {
            if let icon = cache.icon { placed.append((icon, iconSize, 0, 0)) }
            let textsWidth = max(width - textsX - (cache.close == nil ? 0 : closeSize.width + spacing), 0)
            if let texts = cache.texts {
                placed.append((texts, subviews[texts].sizeThatFits(ProposedViewSize(width: textsWidth, height: nil)), textsX, 0))
            }
            if let close = cache.close { placed.append((close, closeSize, width - closeSize.width, 0)) }
            if let actions = cache.actions { placed.append((actions, cache.natural[actions], textsX, 1)) }
        }
        // 1 行目は、各部品の 1 行目の baseline を文の baseline に揃える。2 行目（操作）は文の下に置く
        let baselines = placed.filter { $0.line == 0 }.map { item in
            subviews[item.index].dimensions(in: ProposedViewSize(item.size))[VerticalAlignment.firstTextBaseline]
        }
        let lineBaseline = baselines.max() ?? 0
        var frames: [(index: Int, frame: CGRect)] = []
        var firstLineBottom: CGFloat = 0
        for (item, baseline) in zip(placed.filter { $0.line == 0 }, baselines) {
            let frame = CGRect(origin: CGPoint(x: item.x, y: lineBaseline - baseline), size: item.size)
            firstLineBottom = max(firstLineBottom, frame.maxY)
            frames.append((item.index, frame))
        }
        for item in placed where item.line == 1 {
            let textsBottom = frames.first { $0.index == cache.texts }?.frame.maxY ?? firstLineBottom
            frames.append((item.index, CGRect(origin: CGPoint(x: item.x, y: textsBottom + spacing), size: item.size)))
        }
        return frames
    }
}

// MARK: - 失敗の帯

/// 操作の失敗の帯。どの端末でも画面の下に出し、閉じられる。出すのはこの窓（`\.window`）で始めた操作の失敗だけ。
/// iPhone はタブごとの画面に付け、タブバーの上に出す（タブ全体に付けると、下はタブバーに重なり、上は戻るボタンを隠した）
struct FailureBanner: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.window) private var window

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let failure = model.failure(in: window) {
                Banner(kind: .error, message: failure.text, onClose: { model.clearFailure(in: window) })
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .frame(maxWidth: ReadableWidth.form)
                    .padding(Space.block)
                    .id(failure.id)
            } else if let notice = model.notice(in: window) {
                Banner(kind: .notice, message: notice.text, onClose: { model.clearNotice(notice.id, in: window) })
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .frame(maxWidth: ReadableWidth.form)
                    .padding(Space.block)
                    .id(notice.id)
                    .task(id: notice.id) {
                        AccessibilityNotification.Announcement(notice.text).post()
                        try? await Task.sleep(for: WindowNotice.duration)
                        model.clearNotice(notice.id, in: window)
                    }
            }
        }
    }
}

/// 窓の下に出す短い知らせ（`AppModel.inform`）。失敗の帯と違い、閉じなくても `duration` で消える
struct WindowNotice: Equatable {
    static let duration = Duration.seconds(3)

    let id = UUID()
    let text: String
}
