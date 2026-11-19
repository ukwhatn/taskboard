import SwiftUI

/// コネクタの認証のページを開いた後の案内（Claude の会話のコネクタと、接続先の Codex のコネクタ）。
/// この Mac は接続を待ち、ほかの端末は開いたページのアドレスを貼り、戻り先の無いコネクタは接続し直す
struct ConnectorAuthorizationPanel: View {
    @Binding var authorization: ConnectorAuthorization
    /// ほかの操作の途中（［接続］を押せない）
    let busy: Bool
    let connect: () -> Void

    var body: some View {
        switch authorization.wait {
        case .callback, .catching:
            Text("ブラウザで認証してください。認証が終わると接続します。").font(.callout).foregroundStyle(.secondary)
        case .paste:
            Text("ブラウザで認証すると、エラーのページが開きます。そのページのアドレスを貼り付けて、［接続］を押してください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: Space.row) {
                TextField("ページのアドレス", text: $authorization.address, prompt: Text(verbatim: "http://localhost:"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(connect)
                Button("接続", action: connect).disabled(busy || authorization.address.isEmpty)
            }
            if authorization.invalid {
                // 文字列のリテラルを Text に渡すと、アドレスの部分がリンクになって色が替わる
                Text(String(localized: "http://localhostで始まるアドレスを貼り付けてください。")).font(.caption).foregroundStyle(.red)
            }
        case .reconnect:
            HStack(spacing: Space.row) {
                Text("ブラウザで認証した後、［接続］を押してください。").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: Space.row)
                Button("接続", action: connect).controlSize(.small).disabled(busy)
            }
        }
        Text(verbatim: authorization.origin).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
    }
}
