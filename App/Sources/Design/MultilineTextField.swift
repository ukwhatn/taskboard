import SwiftUI
import TaskboardKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 複数行の入力欄。Mac は NSTextView、iPhone・iPad は UITextView（どちらも TextKit 2）で、長い文を貼っても打鍵ごとに全文を組み直さない
/// （縦に伸びる TextField は大きさを聞かれるたびに全文を組み直す。docs/ui-system.md「使わない書き方」）。
/// 高さは `lines` の行の数の間で文に合わせ、上を超えたら中でスクロールする。
/// Mac のキー: ↩ は `submit`（nil なら何もしない。変換中は確定だけ）、⌥↩ はカーソルの位置への改行、⇧↩ は `newlineOnShiftReturn` なら改行で、そうでなければ ↩ と同じ。
/// Tab はフォーカスを次へ送り、Esc は外（シートやパネルを閉じる・`onExitCommand`）に渡す。⌃ と 1 字のキー（⌃] など）は、文の欄の命令より先に `commandKey` に渡す。
/// ⌘↩・⌥⌘↩ はメニューの key equivalent より先に `commandKey` に渡し、使わなければメニューに任せる。
/// iPhone・iPad の ↩ は縦に伸びる TextField と同じく改行で、`submit` を呼ばない（ハードウェアキーボードの ↑↓・↩・Tab・Esc は先に `commandKey` に渡す）
struct MultilineTextField: View {
    /// 読み上げの名前
    let label: String
    /// 空のときに出す文。nil なら出さない
    var placeholder: String?
    @Binding var text: String
    /// カーソルと選択（文の途中の `/` の候補に使う）。nil なら持たない
    var selection: Binding<TextSelection?>?
    var lines: ClosedRange<Int>
    var font: MultilineTextFont = .body
    var style: MultilineTextFieldStyle = .plain
    /// 文の寄せ。Mac の grouped Form の中のラベル付きの欄は、TextField と同じく右寄せ（`LabeledTextEditor`）
    var alignment: TextAlignment = .leading
    /// iPhone・iPad で自動の大文字と修正を切る（プロンプトなど、書いたとおりに渡す文）
    var literal = false
    /// Mac の ⇧↩ を改行にする
    var newlineOnShiftReturn = true
    /// Mac の ↩
    var submit: (() -> Void)?
    /// `/` の候補が出ている間のキー（↑↓・↩・Tab・Esc）と、Mac の ⌃ と 1 字のキー。使ったら true
    var commandKey: ((KeyEquivalent, EventModifiers) -> Bool)?
    /// ファイルのドロップを受けず、外の受け口に回す（Mac のチャットと会話の入力欄は画像として受ける）
    var passesFileDrops = false
    /// `ChatAttachment.pastedTextThreshold` 以上の貼り付けを入力欄に入れず、この文で受ける（nil なら入れる）
    var longPaste: ((String) -> Void)?
    /// iPhone・iPad で、長押しの［ペースト］の画像をこの文で受ける（nil なら画像を貼れない。Mac は `ChatImagePasteMonitor` が受ける）
    var imagePaste: (@MainActor @Sendable ([Data]) -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    #if os(macOS)
    @Environment(\.controlSize) private var controlSize
    #else
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        let insets = MultilineTextView.textInsets(bordered: style.bordered)
        #if os(macOS)
        let platformFont = font.appKit(controlSize)
        let field = MultilineTextView(
            text: $text, selection: selection ?? .constant(nil), label: label, font: platformFont, lines: lines, bordered: style.bordered,
            alignment: alignment.textKit, isEnabled: isEnabled, newlineOnShiftReturn: newlineOnShiftReturn, submit: submit, commandKey: commandKey,
            passesFileDrops: passesFileDrops, longPaste: longPaste
        )
        #else
        let platformFont = font.uiKit(dynamicTypeSize)
        let field = MultilineTextView(
            text: $text, selection: selection ?? .constant(nil), label: label, font: platformFont, lines: lines, bordered: style.bordered,
            alignment: alignment.textKit, isEnabled: isEnabled, literal: literal, commandKey: commandKey, longPaste: longPaste, imagePaste: imagePaste
        )
        #endif
        field
            .frame(maxWidth: .infinity)
            // 最初の行のベースライン（横に並べたラベルと揃える。representable はベースラインを持たない）
            .alignmentGuide(.firstTextBaseline) { _ in insets.top + platformFont.ascender }
            #if os(iOS)
            .background {
                if style.bordered { MultilineTextBorder() }
            }
            #endif
            .overlay(alignment: alignment == .trailing ? .topTrailing : .topLeading) {
                if let placeholder, !placeholder.isEmpty, text.isEmpty {
                    Text(verbatim: placeholder)
                        .font(Font(platformFont))
                        .foregroundStyle(.placeholder)
                        .lineLimit(1)
                        .padding(insets)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

/// 枠の形。Mac は `roundedBorder` と `stacked` が角丸の枠、iPhone・iPad は `roundedBorder` だけが角丸の枠（TextField の同じ名前の形と同じ）で、ほかは枠なし
enum MultilineTextFieldStyle {
    case plain, roundedBorder
    /// TextField の既定の形（Form の中の欄）
    case automatic
    /// `StackedField` の中の欄
    case stacked

    var bordered: Bool {
        #if os(macOS)
        self == .roundedBorder || self == .stacked
        #else
        self == .roundedBorder
        #endif
    }
}

/// `MultilineTextField` の文字の大きさ。Mac の NSTextView と iPhone・iPad の UITextView に同じ大きさを渡す
enum MultilineTextFont {
    case body, callout, calloutMonospaced
    /// タスクの題（`TaskHeader`）
    case title

    var swiftUI: Font {
        switch self {
        case .body: .body
        case .callout: .callout
        case .calloutMonospaced: .callout.monospaced()
        case .title: .title3.weight(.semibold)
        }
    }

    #if os(macOS)
    /// 本文は TextField と同じく control size に合わせる（`.controlSize(.small)` の表の中の欄は小さい字）
    func appKit(_ controlSize: ControlSize = .regular) -> NSFont {
        switch self {
        case .body:
            switch controlSize {
            case .mini: .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
            case .small: .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            default: .preferredFont(forTextStyle: .body)
            }
        case .callout: .preferredFont(forTextStyle: .callout)
        case .calloutMonospaced: .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        case .title: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
        }
    }
    #else
    /// SwiftUI の文字の大きさの設定（`dynamicTypeSize`）に合わせる
    func uiKit(_ size: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let style = { (style: UIFont.TextStyle) in UIFont.preferredFont(forTextStyle: style, compatibleWith: traits) }
        return switch self {
        case .body: style(.body)
        case .callout: style(.callout)
        case .calloutMonospaced: .monospacedSystemFont(ofSize: style(.callout).pointSize, weight: .regular)
        case .title: .systemFont(ofSize: style(.title3).pointSize, weight: .semibold)
        }
    }
    #endif
}

extension TextAlignment {
    var textKit: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

extension TextSelection {
    /// 入力欄の範囲（UTF-16）。複数の範囲（`multiSelection`）は入力欄では作らないので扱わない
    func range(in text: String) -> NSRange? {
        guard case .selection(let range) = indices, range.upperBound <= text.endIndex else { return nil }
        return NSRange(range, in: text)
    }

    /// 入力欄の範囲を `text` の選択にする
    init?(_ range: NSRange, in text: String) {
        guard let range = Range(range, in: text) else { return nil }
        self = range.isEmpty ? TextSelection(insertionPoint: range.lowerBound) : TextSelection(range: range)
    }
}

/// 入力欄の部品（NSTextView・UITextView）と Binding の間で、1 つの値（文か選択）をどちらが持つかを決める。持つのは部品で、Binding から届いた値を部品に入れるのは、
/// 外で本当に変わったとき（前に届いた値とも、部品が書いてまだ届いていない値とも違う）だけにする。SwiftUI は描き直しのたびに Binding の今の値を渡すが、
/// 打鍵の直後の描き直しや、書いても値がすぐには変わらない Binding（`.constant`・別の置き場に写す get と set）は、部品より古い値を運んでくる。
/// それを入れると、打った字が消えてカーソルが末尾に飛ぶ
struct MultilineFieldSync<Value: Equatable> {
    private var delivered: Value?
    /// 部品が書いて、まだ Binding から届いていない値（古い順）
    private var pending: [Value] = []
    /// 書いた値が戻ってこない Binding（`.constant`）でも覚える数を増やさない
    private static var pendingLimit: Int { 64 }

    /// Binding から届いた値。部品に入れるなら true
    mutating func receive(_ value: Value) -> Bool {
        defer { delivered = value }
        if let index = pending.lastIndex(of: value) {
            pending.removeFirst(index + 1)
            return false
        }
        guard value != delivered else { return false }
        pending = []
        return true
    }

    /// 部品が Binding に書いた値
    mutating func wrote(_ value: Value) {
        if pending.count == Self.pendingLimit { pending.removeFirst() }
        pending.append(value)
    }
}

extension NSRange {
    /// 文が入れ替わった後も、カーソルと選択を元の位置に残す（新しい文の長さで切る。長さは UTF-16）
    func clamped(toLength length: Int) -> NSRange {
        let location = min(self.location, length)
        return NSRange(location: location, length: min(self.length, length - location))
    }
}

extension MultilineTextView {
    /// 枠の内側から文までの余白（TextField の `.roundedBorder` と同じ）。枠なしは TextField（`.plain`）と同じく 0（NSTextView の既定の左右の 5 も 0 にする）
    static func textInsets(bordered: Bool) -> EdgeInsets {
        bordered ? EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6) : EdgeInsets()
    }
}
