import ImageIO
import SwiftUI
import TaskboardKit

/// 人の発言に添えた画像 1 枚（`ChatMessage.images`）。行に載るのは位置だけで、中身は口から取る
struct ChatSentImageRef: Hashable, Identifiable {
    /// 発言の行の uuid（`ChatMessage.lineID`）
    let lineID: String
    let image: ChatImage

    /// 取り置きと fixtures の `chatFiles` の鍵
    var id: String { "image|\(lineID)#\(image.index)" }
    var name: String { String(localized: "画像\(image.index + 1)") }

    /// 吹き出しの縮小版。Retina の 3 倍まで入る大きさに縮め、画像の向き（EXIF）を当てる
    nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ChatMetrics.thumbnail * 3),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 元の画像の画素数。読めなければ nil
    static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

/// 吹き出しの画像が読む、取り置きと開く先。ファイルの欄の host（`ChatFilePaneHost`）が置く
struct ChatSentImageAccess {
    let feed: ConversationFeed
    let fixtures: [String: ChatFileContent]
    let open: (ChatSentImageRef) -> Void

    @MainActor
    func load(_ ref: ChatSentImageRef) async {
        await feed.files.load(ref, fetch: feed.imageFetch, fixtures: fixtures)
    }
}

extension EnvironmentValues {
    @Entry var chatSentImages: ChatSentImageAccess?
}

/// 押した画像を大きく出すシート。上に名前と大きさ、閉じるボタン（Esc でも閉じる）
struct ChatSentImageViewer: View {
    @Environment(\.pageInset) private var inset
    let ref: ChatSentImageRef
    let access: ChatSentImageAccess
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Space.row) {
                Image(systemName: "photo").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: ref.name).textRole(.sectionTitle)
                    MetaLine(items: details).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("閉じる", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .hitTarget()
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, inset)
            .padding(.vertical, Space.block)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: ref.id) { await access.load(ref) }
    }

    @ViewBuilder
    private var content: some View {
        switch access.feed.files.state(ref) {
        case .loading, nil:
            ProgressView("読み込み中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            ChatFileFailure(failure: failure) { Task { await access.load(ref) } }
        case .loaded(.image(let data)):
            ChatFileImage(data: data, name: ref.name)
        case .loaded:
            ChatFileFailure(failure: UserFacingError("画像を表示できませんでした", cause: String(localized: "この形式の画像は表示できません")))
        }
    }

    private var details: [String] {
        var items: [String] = []
        if case .loaded(.image(let data)) = access.feed.files.state(ref), let size = ChatSentImageRef.pixelSize(data) {
            items.append("\(size.width)×\(size.height)")
        }
        if let bytes = ref.image.bytes { items.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
        return items
    }
}
