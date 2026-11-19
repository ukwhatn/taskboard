import Foundation
import ImageIO
import UniformTypeIdentifiers

/// チャットで送る画像。アプリが貼った画像を `POST /v1/panes/{pane}/attachments` でセッションのマシンに置き、
/// 送信（`PaneSendRequest.attachments`）で Claude Code の入力欄に貼る
public enum ChatAttachment {
    /// 1 枚の大きさの上限。Claude の API は base64 で 10MB まで（base64 は元の 4/3 倍）
    public static let maxBytes = 5 * 1024 * 1024
    /// 1 回の送信に付けられる枚数
    public static let maxCount = 10
    /// 長い辺。これより大きい画像は Claude の側で縮められる（high-resolution の上限）ので、アプリで先に縮める
    public static let maxPixelSize = 2576
    /// 1 回の送信に付けられる画像でないファイルの数と、`POST /v1/conversations/{id}/files` で置ける 1 つの大きさ
    public static let maxFiles = 20
    public static let maxFileBytes = 50 * 1024 * 1024
    /// 貼り付けた文がこの長さ（UTF-16 の数）以上なら、入力欄に入れず `pastedTextName` の添付にする（Codex Desktop の `Pasted text.txt` と同じ 5,000 字）
    public static let pastedTextThreshold = 5_000
    /// 添付にした貼り付けを入力欄に戻せる長さ（Codex Desktop の［Show in text field］と同じ 25,000 字）
    public static let pastedTextRestoreLimit = 25_000
    public static let pastedTextName = "pasted-text.txt"
    /// daemon が置いた画像とファイルを残す日数
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public enum ImageType: String, Codable, Sendable, CaseIterable {
        case png, jpeg, gif, webp

        /// 先頭のバイトで決める。Content-Type や拡張子は信用しない
        public init?(sniffing data: Data) {
            let bytes = [UInt8](data.prefix(12))
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                self = .png
            } else if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
                self = .jpeg
            } else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
                self = .gif
            } else if bytes.count == 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) {
                self = .webp
            } else {
                return nil
            }
        }

        public var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            case .gif: "gif"
            case .webp: "webp"
            }
        }

        public var mimeType: String { "image/\(rawValue)" }
    }

    /// 貼った画像を送れる形にする。そのまま送れる形式・大きさならバイト列を変えない（GIF の動きを残す）。
    /// それ以外（TIFF・HEIC、長い辺が `maxPixelSize` を超える、`maxBytes` を超える）は長い辺を縮めて PNG にし、
    /// それでも超えれば JPEG にする。画像として読めないか、縮めても超えるなら nil
    public static func prepare(_ data: Data) -> (data: Data, type: ImageType)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        // 先頭だけ正しく、途中で切れたファイルは大きさが読めない
        guard width > 0, height > 0 else { return nil }
        if let type = ImageType(sniffing: data), data.count <= maxBytes, max(width, height) <= maxPixelSize {
            return (data, type)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = encode(image, as: .png), png.count <= maxBytes { return (png, .png) }
        if let jpeg = encode(image, as: .jpeg, quality: 0.85), jpeg.count <= maxBytes { return (jpeg, .jpeg) }
        return nil
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

/// `POST /v1/panes/{pane}/attachments` の応答。`id` を送信の `attachments` に載せる
public struct AttachmentUploadResponse: Codable, Hashable, Sendable {
    public var id: String
    /// セッションのマシンの絶対パス
    public var path: String

    public init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}
