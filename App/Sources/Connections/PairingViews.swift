import CoreImage.CIFilterBuiltins
import SwiftUI
import TaskboardKit

/// 「iPhone・iPadの追加」。daemon にコードを発行させ、QR コードと 8 文字のコードを出す。切れたら発行し直し、新しい端末が届いたら「追加しました」にする
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fleetID: String
    @State private var phase: Phase = .loading
    @State private var publication = PublicationDraft()
    /// 「この Mac」の保存済みの公開 URL。Keychain を描画のたびに読まないよう、開いたときと保存したときに読む
    @State private var savedPublication: PublishedEndpoint?
    @State private var issuing = false
    /// 公開 URL の入力の誤り（［QRコードを表示］［保存］を押したとき）
    @State private var inputError: String?

    enum Phase: Equatable {
        /// 「この Mac」で公開 URL をまだ入れていない
        case needsEndpoint
        /// 保存済みの公開 URL・Access を直す（tunnel の URL や service token を変えたとき）
        case editingEndpoint
        case loading
        case ready(PairingCode, PairingPayload, known: Set<String>)
        case paired(String)
        /// P7 までの daemon（`/v1/pairings` が無い）
        case unsupported
        case failed(UserFacingError)
    }

    /// 公開先を入れる間だけ「キャンセル」を出す（直している途中なら QR コードに戻る）。QR コードを出した後は「閉じる」
    private var cancelAction: (() -> Void)? {
        switch phase {
        case .needsEndpoint: { dismiss() }
        case .editingEndpoint: issue
        default: nil
        }
    }

    var body: some View {
        SheetScaffold(
            title: String(localized: "iPhone・iPadの追加"), subtitle: model.machineName(fleetID: fleetID, state: model.fleet.allMachines[fleetID]),
            error: inputError, onCancel: cancelAction
        ) {
            switch phase {
            case .needsEndpoint, .editingEndpoint:
                PublicationFields(draft: $publication)
            case .loading:
                Section { ProgressView().frame(maxWidth: .infinity) }
            case .ready(let code, let payload, _):
                Section {
                    VStack(spacing: Space.block) {
                        QRCodeImage(text: payload.encoded)
                            .frame(maxWidth: 240, maxHeight: 240)
                            .accessibilityLabel("接続先のQRコード")
                        Text(verbatim: code.display)
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .accessibilityLabel("コード：\(code.display.map(String.init).joined(separator: " "))")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: Self.remaining(until: code.expiresAt, now: context.date))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .onChange(of: context.date >= code.expiresAt) { _, expired in
                                    if expired { issue() }
                                }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.row)
                } footer: {
                    Text("iPhone・iPadのTaskboardで［接続先を追加］>［QRコードを読む］を選び、このQRコードを読み取ってください。カメラを使えないときは、［コードで追加］にこのコードを入力してください。")
                }
                editEndpointButton
            case .paired(let name):
                Section {
                    Label("「\(name)」を追加しました。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .unsupported:
                Section {
                    Text("接続先のMacのTaskboardが古いため、QRコードを表示できません。Taskboardを更新してください。").foregroundStyle(.secondary)
                }
            case .failed(let failure):
                Section {
                    // 原因と対処まで読めるよう、下の帯ではなく中に全文を出す
                    Banner(kind: .error, message: failure.text)
                }
                editEndpointButton
            }
        } actions: {
            switch phase {
            case .needsEndpoint:
                Button("QRコードを表示", action: savePublication)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .editingEndpoint:
                Button("保存", action: savePublication)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .ready, .failed:
                Button("コードを再発行", action: issue).disabled(issuing)
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            default:
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear(perform: start)
        .onChange(of: model.fleet.allMachines[fleetID]?.devices) { _, devices in
            guard case .ready(_, _, let known) = phase, let added = devices?.first(where: { !known.contains($0.id) }) else { return }
            phase = .paired(added.name)
        }
        .onChange(of: publication) { _, _ in inputError = nil }
    }

    @ViewBuilder
    private var editEndpointButton: some View {
        if fleetID == "local", let saved = savedPublication {
            Section {
                Button("公開URLを編集") {
                    publication = PublicationDraft(saved)
                    inputError = nil
                    phase = .editingEndpoint
                }
            }
        }
    }

    private func start() {
        if fleetID == "local" { savedPublication = ConnectionStore.loadPublication() }
        if fleetID == "local", savedPublication == nil {
            phase = .needsEndpoint
        } else if model.pairingEndpoint(fleetID: fleetID) == nil {
            phase = .failed(UserFacingError("コードを発行できませんでした", cause: String(localized: "この接続先のURLが登録されていません")))
        } else {
            issue()
        }
    }

    private func savePublication() {
        switch publication.validated() {
        case .failure(.message(let message)):
            inputError = message
        case .success(let endpoint):
            do {
                try model.savePublication(endpoint)
                savedPublication = endpoint
                inputError = nil
                issue()
            } catch {
                inputError = UserFacingError("保存できませんでした", error: error)?.text
            }
        }
    }

    private func issue() {
        guard !issuing else { return }
        guard let source = model.source(fleetID: fleetID) else {
            phase = .failed(UserFacingError("コードを発行できませんでした", cause: String(localized: "接続先に接続していません"), remedy: UserFacingError.checkNetwork))
            return
        }
        guard let endpoint = fleetID == "local" ? savedPublication : model.pairingEndpoint(fleetID: fleetID) else { return }
        issuing = true
        Task {
            defer { issuing = false }
            try? await model.loadDevices(fleetID: fleetID)
            let known = Set((model.fleet.allMachines[fleetID]?.devices ?? []).map(\.id))
            do {
                let code = try await source.createPairing()
                let payload = PairingPayload(url: endpoint.url, code: code.code, access: endpoint.access, name: model.machineName(fleetID: fleetID, state: model.fleet.allMachines[fleetID]))
                phase = .ready(code, payload, known: known)
            } catch let error as SessionSourceError where error.status == 404 {
                phase = .unsupported
            } catch {
                if let failure = UserFacingError("コードを発行できませんでした", error: error) { phase = .failed(failure) }
            }
        }
    }

    static func remaining(until expiry: Date, now: Date) -> String {
        let seconds = max(0, Int(expiry.timeIntervalSince(now).rounded(.up)))
        return String(localized: "残り\(seconds / 60):\(String(format: "%02d", seconds % 60))")
    }
}

extension SessionSourceError {
    var status: Int? {
        switch self {
        case .httpStatus(let code): code
        case .rejected(let rejection): rejection.status
        case .unauthorized: 401
        case .forbidden: 403
        default: nil
        }
    }
}

/// 「この Mac」の公開 URL と Access。初めて QR コードを出すときに入れ、「公開先を編集」で直す。
/// 秘密の欄は保存済みの値を画面に戻さず、Client ID が同じで空なら「変えない」
struct PublicationDraft: Equatable {
    var url = "https://"
    var accessID = ""
    var accessSecret = ""
    var existing: PublishedEndpoint?

    init(url: String = "https://", accessID: String = "", accessSecret: String = "") {
        self.url = url
        self.accessID = accessID
        self.accessSecret = accessSecret
    }

    init(_ saved: PublishedEndpoint) {
        url = saved.url.absoluteString
        accessID = saved.access?.clientID ?? ""
        existing = saved
    }

    func build() -> PublishedEndpoint? {
        try? validated().get()
    }

    /// 足りない欄があれば、入力の仕方を返す
    func validated() -> Result<PublishedEndpoint, ConnectionDraft.DraftError> {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), let scheme = parsed.scheme, ["http", "https"].contains(scheme), parsed.host() != nil else {
            return .failure(.message(String(localized: "URLは「https://」から入力してください。")))
        }
        let id = accessID.trimmingCharacters(in: .whitespaces)
        let typed = accessSecret.trimmingCharacters(in: .whitespaces)
        let secret = typed.isEmpty && existing?.access?.clientID == id ? existing?.access?.clientSecret ?? "" : typed
        guard id.isEmpty == secret.isEmpty else {
            return .failure(.message(String(localized: "Client IDとClient Secretは、両方入力するか両方空にしてください。")))
        }
        return .success(PublishedEndpoint(url: parsed, access: id.isEmpty ? nil : AccessCredential(clientID: id, clientSecret: secret)))
    }
}

private struct PublicationFields: View {
    @Binding var draft: PublicationDraft

    var body: some View {
        Section {
            LabeledTextField(label: String(localized: "URL（必須）"), text: $draft.url)
        } header: {
            Text("このMacの公開URL")
        } footer: {
            Text("iPhone・iPadから接続できるURLを入力してください。")
        }
        AccessFields(id: $draft.accessID, secret: $draft.accessSecret, keepsSecret: draft.existing?.access != nil)
    }
}

/// Cloudflare Access の service token の 2 欄
struct AccessFields: View {
    @Binding var id: String
    @Binding var secret: String
    var keepsSecret = false

    var body: some View {
        Section {
            LabeledTextField(label: "Client ID", text: $id)
            LabeledContentField("Client Secret") {
                SecureField("Client Secret", text: $secret)
            }
        } header: {
            Text(verbatim: "Cloudflare Access")
        } footer: {
            if keepsSecret {
                Text("Cloudflare Accessを使わない場合は、両方とも空にしてください。Client Secretを変更しない場合は空欄のままにしてください。")
            } else {
                Text("Cloudflare Accessを使わない場合は、両方とも空にしてください。")
            }
        }
    }
}

/// 文字列の QR コード。拡大でにじまないよう、1 モジュールを整数倍に広げてから補間なしで描く
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(Space.row)
                .background(.white, in: RoundedRectangle(cornerRadius: Radius.control))
        } else {
            Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
