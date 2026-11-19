import Foundation

/// テストの偽物の実行ファイル（シェルスクリプト）。macOS は作ったばかりの実行ファイルを初めて exec するときに確かめ、負荷が高いと秒単位かかるので、
/// 本体は一時フォルダに 1 度だけ書き、テストごとの置き場には symlink を置く。スクリプトは自分の置き場を symlink のあるフォルダ（`$0`）で知る
public struct SharedExecutable: Sendable {
    /// 一時フォルダの中の本体の名前。中身の違うスクリプトどうしで分ける
    public let name: String
    public let script: String

    public init(name: String, script: String) {
        self.name = name
        self.script = script
    }

    /// `directory` に `filename` の symlink を置いて返す
    public func link(in directory: URL, as filename: String) throws -> URL {
        let link = directory.appending(path: filename)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try file())
        return link
    }

    /// 同じ中身がもうあれば書き直さない（書き直すと別のファイルになり、確かめをやり直す）。ほかのテストの process と並んでも壊れないよう、別名で書いてから rename する
    private func file() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        let data = Data(script.utf8)
        if (try? Data(contentsOf: file)) == data, FileManager.default.isExecutableFile(atPath: file.path) { return file }
        let temporary = file.deletingLastPathComponent().appending(path: "\(name)-\(UUID().uuidString)")
        try data.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: temporary.path)
        guard rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return file
    }
}
