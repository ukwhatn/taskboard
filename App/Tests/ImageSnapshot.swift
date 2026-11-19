import AppKit
import SnapshotTesting
import Testing

/// view を撮って参照の PNG と比べる。違えば `view` を作り直して撮り直し、`attempts` 回とも違ったときだけ落とす。
/// 全体で回すと、回ごとに違う画面の 1 組で入力欄の高さか中の文字の位置が 1 px ずれた（単独で回すと起きず、ハッシュの種・suite の順番・
/// 撮るまでの時間・負荷とは関係しなかった）。作り直すと合う回があり、合わない回はそのプロセスの間ずっと同じずれ方をした。
/// 見た目が本当に変わったときは毎回同じ差になるので、撮り直しても落ちる
@MainActor
func assertImageSnapshot(
    of view: @autoclosure () -> NSView,
    named name: String,
    attempts: Int = 3,
    allowingFieldGrowth: Bool = false,
    fileID: StaticString = #fileID,
    file filePath: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    var failure: String?
    for attempt in 0..<attempts {
        // 撮り直したことはログに残す（揺れが増えたら、ここで気づく）
        if attempt > 0 { print("snapshot を撮り直した: \(testName) \(name) \(attempt + 1) 回目") }
        failure = verifySnapshot(
            of: view(), as: .image, named: name, fileID: fileID, file: filePath, testName: testName, line: line, column: column)
        // 撮り直すのは参照と違ったときだけ。参照を書いた回（参照が無い・記録する設定）は 1 回目の絵を残す。
        // 作った view がモデルを変える画面（タスクのパネルが開く会話）は、2 回目からは 1 回目と違う状態で描かれる
        guard let message = failure, message.contains("does not match reference") else { break }
    }
    if let message = failure, allowingFieldGrowth, FieldGrowth.explains(failure: message) {
        print("snapshot の入力欄が 1 pt 高く配置されただけなので通した: \(testName) \(name)")
        return
    }
    if let failure {
        Issue.record(Comment(rawValue: failure), sourceLocation: SourceLocation(fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column)))
    }
}

/// 参照と撮った画像の違いが、AppKit の入力欄が 1 pt 高く配置された形だけかを見る。全体で回すとまれに入力欄が 16 pt でなく 17 pt になり、
/// その行から下がそっくり 1 pt 下がる（字の帯だけ描き方が少し違う）。窓の無い view の AppKit の部品が倍率 1 で高さを切り上げるためと見ている。
/// 倍率を揃えるには窓に載せるしかなく、載せると部品が非アクティブの見た目になって参照の 500 枚ほどが変わるので、揺れる画面に限ってこの形を受ける。
/// 1 pt の余白の変化と、16 pt 以内の 1 帯だけの変化は見逃す。行が増える・帯の外の字が変わるといった違いは落とせる
enum FieldGrowth {
    /// 違ってよい行の帯の上限。入力欄 1 つの高さ
    static let bandLimit = 16 * Int(BoardSnapshotTests.renderScale)

    /// SnapshotTesting の失敗の文（`DiffTool.default` の形）から参照と撮った画像を読んで判定する。読めなければ false
    static func explains(failure message: String) -> Bool {
        let paths = message.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return text.hasPrefix("file://") ? String(text.dropFirst("file://".count)) : nil
        }
        guard paths.count == 2, let reference = SnapshotBitmap(contentsOf: paths[0]), let actual = SnapshotBitmap(contentsOf: paths[1]) else { return false }
        return explains(reference: reference, actual: actual)
    }

    /// 上から順に、参照と同じ行が続き、違う行の帯（`bandLimit` 行まで）が 1 つあり、その後は参照と同じ行か 1 pt 上の参照の行と同じ行だけなら true
    static func explains(reference: SnapshotBitmap, actual: SnapshotBitmap) -> Bool {
        guard reference.width == actual.width, reference.height == actual.height else { return false }
        let shift = Int(BoardSnapshotTests.renderScale)
        let unmatched = (0..<actual.height).filter { y in
            let row = actual.row(y)
            return row != reference.row(y) && (y < shift || row != reference.row(y - shift))
        }
        guard let first = unmatched.first, let last = unmatched.last else { return true }
        let changedBeforeBand = (0..<first).contains { actual.row($0) != reference.row($0) }
        return unmatched.count == last - first + 1 && unmatched.count <= bandLimit && !changedBeforeBand
    }
}

/// PNG を RGBA 8 bit の画素に描き直したもの
struct SnapshotBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(contentsOf path: String) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: image.width, height: image.height, bytes: bytes)
    }

    func row(_ y: Int) -> ArraySlice<UInt8> {
        bytes[(y * width * 4)..<((y + 1) * width * 4)]
    }
}
