// ui-copy:ignore-file
// このファイルの文（保存の失敗）は daemon のログと API の message に出て、画面には出ない
import Foundation
import TaskboardKit

public enum AttachmentStoreError: Error, CustomStringConvertible, Equatable {
    case tooLarge
    case unsupported
    case writeFailed(String)

    public var description: String {
        switch self {
        case .tooLarge: "画像は \(ChatAttachment.maxBytes / 1024 / 1024)MB、ファイルは \(ChatAttachment.maxFileBytes / 1024 / 1024)MB まで"
        case .unsupported: "送れるのは png・jpeg・gif・webp だけ"
        case .writeFailed(let path): "\(path) に書けない"
        }
    }
}

/// チャットで貼った画像の置き場。support ディレクトリの下の `attachments/`（700）に、1 枚ずつ `<UUID>.<拡張子>`（600）で置く。
/// 画像でないファイルは `attachments/files/<UUID>/<名前>` に置く（agent が名前で中身の種類を見分けるので、名前を残す）。
/// Claude Code は送信の後にもファイルを読み直すことがあるので、送ってすぐには消さず、`ChatAttachment.retention` を過ぎたものを消す
public struct AttachmentStore: Sendable {
    public let directory: URL
    var now: @Sendable () -> Date = { Date() }

    public init(directory: URL) {
        self.directory = directory
    }

    init(directory: URL, now: @escaping @Sendable () -> Date) {
        self.directory = directory
        self.now = now
    }

    /// 種類は先頭のバイトで決める。保存のついでに古いファイルを消す
    public func save(_ data: Data) throws -> AttachmentUploadResponse {
        guard data.count <= ChatAttachment.maxBytes else { throw AttachmentStoreError.tooLarge }
        guard let type = ChatAttachment.ImageType(sniffing: data) else { throw AttachmentStoreError.unsupported }
        let fm = FileManager.default
        try makeDirectory(directory)
        purge()
        let id = "\(UUID().uuidString.lowercased()).\(type.fileExtension)"
        let url = directory.appending(path: id)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AttachmentStoreError.writeFailed(url.path)
        }
        return AttachmentUploadResponse(id: id, path: url.path)
    }

    /// 画像でないファイルを置き、置いたパスを返す（送信の `files` に載せる）。名前はディレクトリの部分と頭の . を外す
    public func saveFile(_ data: Data, name: String) throws -> AttachmentUploadResponse {
        guard data.count <= ChatAttachment.maxFileBytes else { throw AttachmentStoreError.tooLarge }
        try makeDirectory(directory)
        purge()
        let id = UUID().uuidString.lowercased()
        let folder = filesDirectory.appending(path: id, directoryHint: .isDirectory)
        try makeDirectory(filesDirectory)
        try makeDirectory(folder)
        let url = folder.appending(path: Self.fileName(name))
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AttachmentStoreError.writeFailed(url.path)
        }
        return AttachmentUploadResponse(id: id, path: url.path(percentEncoded: false))
    }

    private var filesDirectory: URL { directory.appending(path: "files", directoryHint: .isDirectory) }

    static func fileName(_ name: String) -> String {
        let base = String((name.split(separator: "/").last ?? "").drop { $0 == "." })
        return base.isEmpty ? "file" : base
    }

    private func makeDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw AttachmentStoreError.writeFailed(url.path)
        }
    }

    /// 送信に載った id のファイル。形の違う id（`../` を含むものなど）と、無いファイルは nil
    public func file(id: String) -> URL? {
        guard Self.isValidID(id) else { return nil }
        let url = directory.appending(path: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, parts[0] == parts[0].lowercased() else { return false }
        return ChatAttachment.ImageType.allCases.contains { $0.fileExtension == parts[1] }
    }

    /// 変更時刻が `ChatAttachment.retention` より前のファイルを消す。消した数を返す
    @discardableResult
    public func purge() -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let limit = now().addingTimeInterval(-ChatAttachment.retention)
        var removed = 0
        let folders = (try? fm.contentsOfDirectory(at: filesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let stale = urls.filter { Self.isValidID($0.lastPathComponent) } + folders.filter { UUID(uuidString: $0.lastPathComponent) != nil && $0.lastPathComponent == $0.lastPathComponent.lowercased() }
        for url in stale {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < limit else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
