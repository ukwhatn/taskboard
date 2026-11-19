import SwiftUI

/// 入力のシートの枠（docs/ui-system.md「端末ごとの作法」）。
/// Mac は上に見出し、中に grouped の Form、下の帯にエラーと「キャンセル」と確定のボタン。幅を固定するのは、中の欄（作業ディレクトリなど）が
/// 伸びてシートより広くなり、端が切れるのを防ぐため。iPhone と iPad は上のバーの左に「キャンセル」、右に確定のボタンを置き、
/// エラーは Form の先頭に出す（下の帯はキーボードの真上に来て、押し間違える）
struct SheetScaffold<Content: View, Actions: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let title: String
    var subtitle: String?
    var error: String?
    /// 操作の後の案内（失敗でないもの）。`error` があればそちらを出す
    var notice: String?
    var width: CGFloat = 520
    /// 「キャンセル」の動作。nil なら出さない（閉じるだけのシートは actions に「閉じる」を置く）
    var onCancel: (() -> Void)?
    @ViewBuilder var content: Content
    /// 確定のボタン（Mac は右下、iPhone と iPad は上のバーの右）
    @ViewBuilder var actions: Actions
    #if os(macOS)
    /// 見出しと下の帯の左右。grouped Form の行の左右の余白と揃える
    private static var formInset: CGFloat { 20 }
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.formInset)
            .padding(.top, Self.formInset)
            Form { content }
                .formStyle(.grouped)
                .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: Space.row) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.block)
                if let onCancel {
                    Button("キャンセル", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                actions
            }
            .padding(.horizontal, Self.formInset)
            .padding(.vertical, Space.block)
        }
        .frame(width: width)
        #else
        NavigationStack {
            Form {
                if let subtitle {
                    Section { Text(subtitle).foregroundStyle(.secondary) }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let notice {
                    Section {
                        Label(notice, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            // 下へ送るとキーボードを閉じる（キーボードの下に隠れた欄に届かなかった）
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            // iPhone は題を上のバーの下に大きく出す。バーの中では「キャンセル」と長い確定（「追加して起動」）に挟まれて切れた
            .navigationBarTitleDisplayMode(sizeClass == .compact ? .large : .inline)
            .toolbar {
                if let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル", role: .cancel, action: onCancel)
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) { actions }
            }
        }
        #endif
    }
}

/// ラベル付きの 1 行の入力欄。iOS の Form は TextField のラベルを出さないので、LabeledContent で左に置く
struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var prompt: String?
    var monospaced = false

    var body: some View {
        LabeledContentField(label) {
            // iOS の TextField はラベルをプレースホルダーに出す。ラベルは左に出しているので、書式の見本が無ければ空にする
            TextField(label, text: $text, prompt: Text(verbatim: prompt ?? ""))
                .font(monospaced ? .body.monospaced() : .body)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }
}

/// 任意の入力欄にラベルを付ける。macOS の Form は欄のラベルをそのまま出すので何もしない
struct LabeledContentField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        #if os(macOS)
        field
        #else
        LabeledContent(label) { field.multilineTextAlignment(.trailing) }
        #endif
    }
}

extension View {
    /// 読むだけのシートを、シートの外（親の窓）を押したら閉じる。macOS のシートは外を押しても閉じない（iPhone・iPad は OS が閉じるので何もしない）。
    /// 入力を持つシートには付けない（押し間違いで下書きが消える）
    func dismissOnOutsideClick(_ dismiss: @escaping () -> Void) -> some View {
        #if os(macOS)
        background(SheetOutsideClickMonitor(dismiss: dismiss))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// シートの窓に置き、親の窓への左クリックを受けて閉じる。クリックは親に渡さない（シートの間は親を押せないのと同じ）
private struct SheetOutsideClickMonitor: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) { view.dismiss = dismiss }

    final class MonitorView: NSView {
        var dismiss: (() -> Void)?
        private var token: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NSEvent.removeMonitor(token) }
            token = nil
            guard window != nil else { return }
            token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                // シートの上に別のシートが重なっている間（このシートが親になっている）は閉じない
                guard let self, let sheet = self.window, sheet.attachedSheet == nil, let parent = sheet.sheetParent, event.window === parent
                else { return event }
                self.dismiss?()
                return nil
            }
        }
    }
}
#endif
