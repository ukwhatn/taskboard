import SwiftUI
import TaskboardKit
import UniformTypeIdentifiers

/// 会話の入力欄で選んだ、送る前の画像でないファイル。会話のマシンがこの Mac ならパスだけを持ち、ほかのマシンへは中身を持って送るときに置く
struct ChatDraftFile: Identifiable, Hashable {
    enum Content: Hashable {
        /// 会話のマシンの絶対パス（同じ Mac で選んだファイル）
        case path(String)
        /// `uploadConversationFile` で会話のマシンに置く中身
        case data(Data)
    }

    let id = UUID()
    let name: String
    let content: Content
    /// フォルダ（会話のマシンがこの Mac のときだけ添付できる）
    var isFolder = false
    /// 長い貼り付けを `pasted-text.txt` にしたものの行の数。nil なら貼り付けではない
    var pastedLines: Int?

    /// 貼った長い文を、`pasted-text.txt` の添付にする
    static func pasted(_ text: String) -> ChatDraftFile {
        let lines = text.utf8.count(where: { $0 == 0x0A }) + (text.hasSuffix("\n") ? 0 : 1)
        return ChatDraftFile(name: ChatAttachment.pastedTextName, content: .data(Data(text.utf8)), pastedLines: lines)
    }

    /// 貼り付けた文（入力欄に戻すとき）
    var pastedText: String? {
        guard pastedLines != nil, case .data(let data) = content else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 入力欄の札に出す名前
    var title: String { pastedLines.map { String(localized: "貼り付けた文（\($0)行）") } ?? name }

    var symbol: String { isFolder ? "folder" : pastedLines != nil ? "doc.plaintext" : "doc" }
}

/// ［ファイルを添付］で選んだファイルの振り分け。画像は今までどおり画像の添付に回し、ほかはファイルにする
enum ChatFileIntake {
    struct Outcome {
        var images: [Data] = []
        var files: [ChatDraftFile] = []
        var problem: Problem?
    }

    enum Problem: Equatable {
        case tooMany
        case tooLarge(String)
        case unreadable(String)
        /// フォルダは、会話のマシンがこの Mac のときだけ添付できる
        case folderNotLocal(String)
    }

    /// `local` は会話のマシンがこの Mac か。`room` は下書きにあと何件のファイルを足せるか。足せない分は捨てて、最初の問題を返す
    static func take(_ urls: [URL], local: Bool, room: Int) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            // iPhone・iPad の選んだファイルは、読む間だけ使える
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isFolder, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true, let data = try? Data(contentsOf: url),
                ChatAttachment.ImageType(sniffing: data) != nil
            {
                outcome.images.append(data)
                continue
            }
            guard outcome.files.count < room else {
                outcome.problem = outcome.problem ?? .tooMany
                continue
            }
            if isFolder {
                guard local else {
                    outcome.problem = outcome.problem ?? .folderNotLocal(name)
                    continue
                }
                outcome.files.append(ChatDraftFile(name: name, content: .path(url.path), isFolder: true))
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            if local {
                guard size != nil else {
                    outcome.problem = outcome.problem ?? .unreadable(name)
                    continue
                }
                outcome.files.append(ChatDraftFile(name: name, content: .path(url.path)))
                continue
            }
            if let size, size > ChatAttachment.maxFileBytes {
                outcome.problem = outcome.problem ?? .tooLarge(name)
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                outcome.problem = outcome.problem ?? .unreadable(name)
                continue
            }
            guard data.count <= ChatAttachment.maxFileBytes else {
                outcome.problem = outcome.problem ?? .tooLarge(name)
                continue
            }
            outcome.files.append(ChatDraftFile(name: name, content: .data(data)))
        }
        return outcome
    }

    static func failure(_ problem: Problem) -> UserFacingError {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(ChatAttachment.maxFileBytes), countStyle: .file)
        return switch problem {
        case .tooMany:
            UserFacingError("ファイルを添付できませんでした", cause: String(localized: "1回に送信できるファイルは\(ChatAttachment.maxFiles)件までです"))
        case .tooLarge(let name):
            UserFacingError(
                "ファイルを添付できませんでした", cause: String(localized: "「\(name)」が\(limit)を超えています"),
                remedy: String(localized: "\(limit)以下のファイルにしてください"))
        case .unreadable(let name):
            UserFacingError("ファイルを添付できませんでした", cause: String(localized: "「\(name)」を読み取れません"))
        case .folderNotLocal(let name):
            UserFacingError(
                "フォルダを添付できませんでした", cause: String(localized: "「\(name)」はこのMacの会話にだけ添付できます"),
                remedy: String(localized: "フォルダの中のファイルを選んで添付してください"))
        }
    }
}

/// 入力欄の上に並べる、送る前のファイルの札。札ごとに外すボタン
struct ChatDraftFileStrip: View {
    let files: [ChatDraftFile]
    let fonts: ChatFonts
    let remove: (ChatDraftFile) -> Void
    /// 貼り付けた文を入力欄に戻す。nil なら戻すボタンを出さない
    var restore: ((ChatDraftFile) -> Void)?

    var body: some View {
        FlowRow(spacing: Space.inline, lineSpacing: Space.inline) {
            ForEach(files) { file in
                let removeTitle: LocalizedStringKey = file.pastedLines == nil ? "ファイルを外す" : "貼り付けた文を外す"
                HStack(spacing: Space.inline) {
                    ChatAttachedFileLabel(name: file.title, symbol: file.symbol, fonts: fonts)
                    if let restore, file.pastedLines != nil {
                        Button("入力欄に戻す", systemImage: "text.insert") { restore(file) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .font(fonts.caption2)
                            .help("入力欄に戻す")
                            .accessibilityLabel("\(file.title)を入力欄に戻す")
                    }
                    Button(removeTitle, systemImage: "xmark") { remove(file) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(fonts.caption2)
                        .help(removeTitle)
                        .accessibilityLabel("\(file.title)を外す")
                }
                .chipStyle(tint: .secondary)
            }
        }
        .padding(.vertical, Space.inline)
    }
}

/// 添付したファイルの名前（入力欄の札と、発言の吹き出しの札）
struct ChatAttachedFileLabel: View {
    let name: String
    var symbol = "doc"
    let fonts: ChatFonts

    var body: some View {
        HStack(spacing: Space.inline) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(verbatim: name).foregroundStyle(ChatPalette.text).lineLimit(1).truncationMode(.middle)
        }
        .font(fonts.caption)
    }
}
