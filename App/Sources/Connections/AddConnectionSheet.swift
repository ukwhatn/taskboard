import CoreImage.CIFilterBuiltins
import SwiftUI
import TaskboardKit

/// 接続先を追加する。QR コードを読む（iOS でカメラを使えるとき）・コードで追加・トークンで追加
struct AddConnectionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    @State private var code = CodeDraft()
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    /// 「トークンで追加」を選んだら、閉じた後に今のフォームを開く
    var onToken: () -> Void = {}

    enum Mode: Equatable {
        case menu
        case scan
        case code
        case confirm(PairingPayload)
    }

    var body: some View {
        switch mode {
        case .scan:
            #if os(iOS)
            QRScannerScreen(
                onFound: { payload in
                    name = payload.name
                    mode = .confirm(payload)
                },
                onCode: { mode = .code },
                onCancel: { dismiss() })
            #else
            EmptyView()
            #endif
        default:
            SheetScaffold(title: title, subtitle: subtitle, error: error, onCancel: { dismiss() }) {
                content
            } actions: {
                if case .code = mode {
                    Button("追加") { submitCode() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                } else if case .confirm(let payload) = mode {
                    Button("追加") { submitConfirm(payload) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }
            .onAppear {
                // 読んだ QR コードから直接開いたとき（スキャナを通らない）も、名前は QR コードの接続先の名前から始める
                if case .confirm(let payload) = mode, name.isEmpty { name = payload.name }
            }
            .onChange(of: code) { _, _ in error = nil }
        }
    }

    private var title: String {
        switch mode {
        case .code: String(localized: "コードでの追加")
        case .confirm(let payload): String(localized: "「\(payload.name)」の追加")
        default: String(localized: "接続先の追加")
        }
    }

    private var subtitle: String? {
        if case .confirm(let payload) = mode { return payload.url.host() }
        return nil
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .menu:
            Section {
                #if os(iOS)
                if QRScannerScreen.isAvailable {
                    menuRow(String(localized: "QRコードを読む"), detail: String(localized: "追加するMacの［iPhone・iPadを追加］に表示されたQRコードを読み取ります。"), symbol: "qrcode.viewfinder") {
                        mode = .scan
                    }
                }
                #endif
                menuRow(String(localized: "コードで追加"), detail: String(localized: "QRコードの下にある8文字のコードとURLを入力します。"), symbol: "keyboard") { mode = .code }
                menuRow(String(localized: "トークンで追加"), detail: String(localized: "QRコードに対応していない接続先を追加します。"), symbol: "key") {
                    dismiss()
                    onToken()
                }
            }
        case .code:
            Section {
                LabeledTextField(label: String(localized: "名前（必須）"), text: $code.name)
                LabeledTextField(label: String(localized: "URL（必須）"), text: $code.url)
                LabeledTextField(label: String(localized: "コード（必須）"), text: $code.code, prompt: "ABCD-EFGH", monospaced: true)
            } footer: {
                Text("追加するMacの［iPhone・iPadを追加］に表示される8文字のコードを入力してください。コードは5分で無効になります。")
            }
            AccessFields(id: $code.accessID, secret: $code.accessSecret)
        case .confirm:
            Section {
                LabeledTextField(label: String(localized: "名前（必須）"), text: $name)
            } footer: {
                Text("このデバイスで表示する名前です。")
            }
        case .scan:
            EmptyView()
        }
    }

    private func menuRow(_ title: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.block) {
                Image(systemName: symbol).foregroundStyle(.tint).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).textRole(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func submitCode() {
        switch code.validated() {
        case .failure(.message(let message)): error = message
        case .success(let input): submit(input)
        }
    }

    private func submitConfirm(_ payload: PairingPayload) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            error = String(localized: "名前を入力してください。")
            return
        }
        submit((payload, trimmed))
    }

    private func submit(_ input: (PairingPayload, String)) {
        guard !busy else { return }
        let (payload, name) = input
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.pair(payload, name: name)
                dismiss()
            } catch {
                self.error = UserFacingError("追加できませんでした", error: error)?.text
            }
        }
    }
}

/// 「コードで追加」の欄
struct CodeDraft: Equatable {
    var name = ""
    var url = "https://"
    var code = ""
    var accessID = ""
    var accessSecret = ""

    func build() -> (PairingPayload, String)? {
        try? validated().get()
    }

    /// 足りない欄があれば、入力の仕方を返す
    func validated() -> Result<(PairingPayload, String), ConnectionDraft.DraftError> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .failure(.message(String(localized: "名前を入力してください。"))) }
        guard let normalized = PairingCode.normalize(code) else {
            return .failure(.message(String(localized: "コードは8文字で入力してください。")))
        }
        switch PublicationDraft(url: url, accessID: accessID, accessSecret: accessSecret).validated() {
        case .failure(let failure): return .failure(failure)
        case .success(let endpoint):
            return .success((PairingPayload(url: endpoint.url, code: normalized, access: endpoint.access, name: trimmed), trimmed))
        }
    }
}
