import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// チャットの入力欄に貼った、送る前の画像。`ChatAttachment.prepare` を通した後のバイト列
struct ChatDraftImage: Identifiable, Hashable {
    let id = UUID()
    let data: Data
    let type: ChatAttachment.ImageType
    /// 会話のマシンに置いた画像の id。取り消して入力欄に戻した画像は、送り直すときに置き直さない（daemon は 7 日残す）
    var uploadedID: String?

    var image: Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

/// 貼り付け・ドロップで受けた画像を、送れる形にして下書きに足す
enum ChatImageIntake {
    enum Outcome: Equatable {
        case added([ChatDraftImage])
        /// 枚数の上限に届いた。上限までは足す
        case tooMany([ChatDraftImage])
        /// 読めない画像があった。読めた分は足す
        case unreadable([ChatDraftImage])
    }

    /// 縮めて符号化し直すので、主スレッドの外で回す
    static func append(_ incoming: [Data], to current: [ChatDraftImage]) async -> Outcome {
        var images = current
        var unreadable = false
        for data in incoming {
            guard images.count < ChatAttachment.maxCount else { return .tooMany(images) }
            guard let prepared = await Task.detached(operation: { ChatAttachment.prepare(data) }).value else {
                unreadable = true
                continue
            }
            images.append(ChatDraftImage(data: prepared.data, type: prepared.type))
        }
        return unreadable ? .unreadable(images) : .added(images)
    }

    static func failure(_ outcome: Outcome) -> UserFacingError? {
        switch outcome {
        case .added: nil
        case .tooMany:
            UserFacingError("画像を貼り付けられませんでした", cause: String(localized: "1回に送信できる画像は\(ChatAttachment.maxCount)枚までです"))
        case .unreadable: UserFacingError("画像を貼り付けられませんでした", cause: String(localized: "画像を読み取れません"))
        }
    }

    static func images(of outcome: Outcome) -> [ChatDraftImage] {
        switch outcome {
        case .added(let images), .tooMany(let images), .unreadable(let images): images
        }
    }

    /// 画像のファイルの中身。画像でないファイルは nil
    static func imageFile(_ url: URL) -> Data? {
        guard url.isFileURL, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        return try? Data(contentsOf: url)
    }

    #if os(macOS)
    /// ⌘V で画像として受けるもの。文字の貼り付け（文字が載っているクリップボード）は nil にして、入力欄に任せる。
    /// Finder でコピーしたファイルは名前の文字も載るので、ファイルを先に見る
    static func images(on pasteboard: NSPasteboard) -> [Data]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.compactMap(imageFile)
            return files.count == urls.count ? files : nil
        }
        if pasteboard.string(forType: .string) != nil { return nil }
        let types = pasteboard.types ?? []
        guard let type = types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }), let data = pasteboard.data(forType: type) else {
            return nil
        }
        return [data]
    }

    /// Finder でコピーしたファイルとフォルダのうち、画像でないものがあるときの中身（画像は画像として、ほかは URL）。ファイルが載っていなければ nil
    static func files(on pasteboard: NSPasteboard) -> (images: [Data], others: [URL])? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        var images: [Data] = []
        var others: [URL] = []
        for url in urls {
            if let data = imageFile(url) { images.append(data) } else { others.append(url) }
        }
        return others.isEmpty ? nil : (images, others)
    }
    #endif
}

#if os(macOS)
/// 入力欄にフォーカスがある間の ⌘V を、画像のときだけ先に受ける。TextField は画像の貼り付けを受けない。
/// メニューの［ペースト］より前にキーを見るので、メニューから選んだ貼り付けは受けない
@MainActor
final class ChatImagePasteMonitor {
    var isActive = false
    var onPaste: ([Data]) -> Void = { _ in }
    /// 画像でないファイルとフォルダの受け口。nil なら受けず、入力欄の貼り付けに任せる
    var onFiles: (([URL]) -> Void)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "v"
            else { return event }
            if let onFiles = self.onFiles, let pasted = ChatImageIntake.files(on: .general) {
                if !pasted.images.isEmpty { self.onPaste(pasted.images) }
                onFiles(pasted.others)
                return nil
            }
            guard let images = ChatImageIntake.images(on: .general) else { return event }
            self.onPaste(images)
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}
#endif

/// 入力欄の上の、貼った画像の並び。1 枚ずつ外せる
struct ChatImageStrip: View {
    let images: [ChatDraftImage]
    let remove: (ChatDraftImage) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.row) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    thumbnail(image)
                        .contextMenu { ImageCopyButton(data: image.data) }
                        .overlay(alignment: .topTrailing) {
                            Button("画像を削除", systemImage: "xmark.circle.fill") { remove(image) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .hitTarget()
                                .help("画像を削除")
                                .accessibilityLabel("画像\(index + 1)を削除")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("画像\(index + 1)")
                }
            }
            .padding(.vertical, Space.inline)
        }
    }

    private func thumbnail(_ image: ChatDraftImage) -> some View {
        Group {
            if let picture = image.image {
                picture.resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: ChatMetrics.thumbnail, height: ChatMetrics.thumbnail)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
    }
}
